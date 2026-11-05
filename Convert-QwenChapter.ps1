#Requires -Version 7.0
# Wandelt ein Textkapitel in eine WAV-Datei um und kann fehlgeschlagene Abschnitte fortsetzen.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$TextPath,
    [Parameter(Mandatory, Position = 1)]
    [string]$VoiceFile,
    [string]$OutputPath,
    [ValidateSet('German', 'English', 'Chinese', 'Japanese', 'Korean', 'French', 'Russian', 'Portuguese', 'Spanish', 'Italian', 'Auto')]
    [string]$Language = 'German',
    [ValidateRange(100, 2000)]
    [int]$MaxChars = 600,
    [ValidateRange(0, 5)]
    [double]$SentencePause = 0.2,
    [ValidateRange(0, 10)]
    [double]$ParagraphPause = 0.6,
    [uri]$QwenUrl = 'http://localhost:8000',
    [ValidateRange(1, 86400)]
    [int]$TimeoutSec = 1800,
    [ValidateRange(0, 5)]
    [int]$Retries = 1,
    [bool]$CleanUp = $true
)

$ErrorActionPreference = 'Stop'

# Teilt Text an Absatz- und Satzgrenzen; ueberlange Saetze werden zusaetzlich begrenzt.
function Split-Chapter {
    param([string]$Text, [int]$Limit)
    $chunks = [System.Collections.Generic.List[object]]::new()
    foreach ($paragraph in ($Text -split '(?:\r?\n)[\t ]*(?:\r?\n)+')) {
        $normalized = ($paragraph -replace '\s+', ' ').Trim()
        if (-not $normalized) { continue }
        $current = ''
        foreach ($sentence in [regex]::Split($normalized, '(?<=[.!?])\s+')) {
            if ($current -and ($current.Length + 1 + $sentence.Length -gt $Limit)) {
                $chunks.Add([pscustomobject]@{ Text = $current; ParagraphEnd = $false })
                $current = ''
            }
            $remaining = $sentence
            while ($remaining.Length -gt $Limit) {
                $boundary = $remaining.LastIndexOf(' ', $Limit)
                if ($boundary -lt 1) { $boundary = $Limit }
                $chunks.Add([pscustomobject]@{ Text = $remaining.Substring(0, $boundary); ParagraphEnd = $false })
                $remaining = $remaining.Substring($boundary).TrimStart()
            }
            if ($current) { $current += ' ' }
            $current += $remaining
        }
        if ($current) { $chunks.Add([pscustomobject]@{ Text = $current; ParagraphEnd = $true }) }
        elseif ($chunks.Count) { $chunks[$chunks.Count - 1].ParagraphEnd = $true }
    }
    return $chunks.ToArray()
}

# Liest das Gradio-Server-Sent-Events-Ergebnis und wirft API-Fehler direkt weiter.
function Read-ChapterEvent {
    param([string]$Events)
    $eventType = ''
    $dataLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (($Events + "`n`n") -split '\r?\n')) {
        if ($line.StartsWith('event:')) { $eventType = $line.Substring(6).Trim() }
        elseif ($line.StartsWith('data:')) { $dataLines.Add($line.Substring(5).TrimStart()) }
        elseif ([string]::IsNullOrWhiteSpace($line)) {
            if ($eventType -eq 'error') { throw "Qwen-API-Fehler: $($dataLines -join "`n")" }
            if ($eventType -eq 'complete') { return ,(($dataLines -join "`n") | ConvertFrom-Json) }
            $eventType = ''
            $dataLines.Clear()
        }
    }
    throw 'Qwen hat kein abgeschlossenes Ergebnis geliefert.'
}

# Liest und validiert PCM-16-WAV-Header, bevor Audioabschnitte verarbeitet werden.
function Get-ChapterWave {
    param([string]$Path)
    $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($Path))
    try {
        if ([System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'RIFF') { throw "Keine RIFF-WAV-Datei: $Path" }
        $riffLength = $reader.ReadUInt32()
        if ($riffLength + 8 -ne $reader.BaseStream.Length -or
            [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'WAVE') {
            throw "Beschaedigte WAV-Datei: $Path"
        }
        $format = $null
        $dataOffset = 0L
        $dataLength = 0L
        # WAV-Dateien koennen zusaetzliche Chunks enthalten; daher wird der Chunk-Header durchsucht.
        while ($reader.BaseStream.Position + 8 -le $reader.BaseStream.Length) {
            $kind = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            $length = [long]$reader.ReadUInt32()
            $next = $reader.BaseStream.Position + $length + ($length % 2)
            if ($next -gt $reader.BaseStream.Length) { throw "Unvollstaendige WAV-Datei: $Path" }
            if ($kind -eq 'fmt ') {
                if ($length -lt 16) { throw 'Ungueltiger WAV-Formatblock.' }
                $format = @{
                    Encoding = $reader.ReadUInt16(); Channels = $reader.ReadUInt16()
                    SampleRate = $reader.ReadUInt32(); ByteRate = $reader.ReadUInt32()
                    BlockAlign = $reader.ReadUInt16(); Bits = $reader.ReadUInt16()
                }
            }
            elseif ($kind -eq 'data') {
                $dataOffset = $reader.BaseStream.Position
                $dataLength = $length
            }
            $reader.BaseStream.Position = $next
        }
        if (-not $format -or $format.Encoding -ne 1 -or $format.Bits -ne 16 -or
            $format.Channels -notin @(1, 2) -or $format.SampleRate -eq 0 -or
            $format.BlockAlign -ne $format.Channels * 2 -or
            $format.ByteRate -ne $format.SampleRate * $format.BlockAlign -or
            $dataLength -eq 0 -or $dataLength % $format.BlockAlign -ne 0) {
            throw 'Erwartet wird eine nicht leere PCM-16-WAV-Datei (mono oder stereo).'
        }
        return [pscustomobject]@{ Path = $Path; Format = $format; Offset = $dataOffset; Length = $dataLength }
    }
    finally { $reader.Dispose() }
}

# Fuegt WAV-Audiodaten samt Satz-/Absatzpausen in eine neue Datei zusammen.
function Join-ChapterWaves {
    param([object[]]$Chunks, [string]$Directory, [string]$Destination, [double]$ShortPause, [double]$LongPause)
    $waves = @($Chunks | ForEach-Object { Get-ChapterWave (Join-Path $Directory $_.File) })
    $format = $waves[0].Format
    $total = 0L
    $gaps = [System.Collections.Generic.List[long]]::new()
    # Alle Abschnitte muessen dasselbe Format besitzen, damit die Daten binaer zusammenpassen.
    for ($index = 0; $index -lt $waves.Count; $index++) {
        foreach ($key in $format.Keys) {
            if ($waves[$index].Format[$key] -ne $format[$key]) { throw 'Audioabschnitte haben unterschiedliche WAV-Formate.' }
        }
        $pause = if ($Chunks[$index].ParagraphEnd) { $LongPause } else { $ShortPause }
        $gapBytes = if ($index -lt $waves.Count - 1) { [long][math]::Round($pause * $format.SampleRate) * $format.BlockAlign } else { 0L }
        $gaps.Add($gapBytes)
        $total += $waves[$index].Length + $gapBytes
    }
    if ($total -gt [uint32]::MaxValue - 36) { throw 'Kapitel ist fuer RIFF-WAV zu gross (4 GB). Bitte das Kapitel aufteilen.' }
    # Schreibt zuerst eine temporaere Datei und verschiebt sie erst nach erfolgreicher Validierung.
    $temporary = "$Destination.partial"
    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($temporary))
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32]($total + 36))
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32]16)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$format.Channels)
        $writer.Write([uint32]$format.SampleRate)
        $writer.Write([uint32]$format.ByteRate)
        $writer.Write([uint16]$format.BlockAlign)
        $writer.Write([uint16]16)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]$total)
        $buffer = [byte[]]::new(65536)
        $silence = [byte[]]::new(65536)
        for ($index = 0; $index -lt $waves.Count; $index++) {
            $source = [System.IO.File]::OpenRead($waves[$index].Path)
            try {
                $source.Position = $waves[$index].Offset
                $remaining = $waves[$index].Length
                while ($remaining -gt 0) {
                    $read = $source.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
                    if ($read -eq 0) { throw 'Audioabschnitt wurde beim Lesen abgeschnitten.' }
                    $writer.Write($buffer, 0, $read)
                    $remaining -= $read
                }
            }
            finally { $source.Dispose() }
            $remaining = $gaps[$index]
            while ($remaining -gt 0) {
                $count = [int][math]::Min($silence.Length, $remaining)
                $writer.Write($silence, 0, $count)
                $remaining -= $count
            }
        }
    }
    finally { $writer.Dispose() }
    Get-ChapterWave $temporary | Out-Null
    [System.IO.File]::Move($temporary, $Destination)
    return $total / $format.ByteRate
}

# Speichert den Fortschritt atomar, damit ein Abbruch das vorherige Manifest nicht beschaedigt.
function Save-ChapterManifest {
    param($Manifest, [string]$Path)
    [System.IO.File]::WriteAllText("$Path.tmp", ($Manifest | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move("$Path.tmp", $Path, $true)
}

# Prueft Eingaben, erstellt Textabschnitte und richtet den resumierbaren Arbeitsordner ein.
$textFile = Get-Item -LiteralPath $TextPath
$voice = Get-Item -LiteralPath $VoiceFile
if ($textFile.PSIsContainer -or $voice.PSIsContainer -or $voice.Length -eq 0) { throw 'TextPath und VoiceFile muessen Dateien sein.' }
$text = [System.IO.File]::ReadAllText($textFile.FullName, [System.Text.UTF8Encoding]::new($false, $true))
$pieces = @(Split-Chapter -Text $text -Limit $MaxChars)
if ($pieces.Count -eq 0) { throw 'Das Kapitel enthaelt keinen Text.' }
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "data/audiobooks/$($textFile.BaseName).wav" }
$output = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($output) -ine '.wav') { throw 'OutputPath muss die Endung .wav haben.' }
if (Test-Path -LiteralPath $output) { throw "Ausgabedatei existiert bereits: $output" }
if (-not $QwenUrl.IsAbsoluteUri -or $QwenUrl.Scheme -notin @('http', 'https')) { throw 'QwenUrl muss eine absolute HTTP(S)-URL sein.' }
$qwenBase = $QwenUrl.AbsoluteUri.TrimEnd('/')
$work = "$output.work"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lock = [System.IO.FileStream]::new((Join-Path $work 'job.lock'), [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
try {
    $manifestPath = Join-Path $work 'job.json'
    # Die Signatur verhindert, dass zwischengespeicherte Audiodaten fuer andere Eingaben genutzt werden.
    $identity = [ordered]@{
        Version = 1; TextHash = (Get-FileHash -LiteralPath $textFile.FullName -Algorithm SHA256).Hash
        VoiceHash = (Get-FileHash -LiteralPath $voice.FullName -Algorithm SHA256).Hash
        Language = $Language; MaxChars = $MaxChars; SentencePause = $SentencePause; ParagraphPause = $ParagraphPause
        QwenUrl = $qwenBase
    }
    $signature = $identity | ConvertTo-Json -Compress
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.Signature -cne $signature) { throw "Text, Stimme oder Einstellungen wurden geaendert. Anderen OutputPath verwenden oder den Arbeitsordner bewusst entfernen: $work" }
        if ($manifest.Chunks.Count -ne $pieces.Count) { throw 'Arbeitsmanifest passt nicht zum Kapitel.' }
    }
    else {
        $entries = for ($index = 0; $index -lt $pieces.Count; $index++) {
            [pscustomobject]@{ File = ('{0:D5}.wav' -f ($index + 1)); Text = $pieces[$index].Text; ParagraphEnd = $pieces[$index].ParagraphEnd; Hash = '' }
        }
        $manifest = [pscustomobject]@{ Signature = $signature; Chunks = @($entries) }
        Save-ChapterManifest $manifest $manifestPath
    }
    # Ein Abschnitt gilt nur dann als fertig, wenn Datei und gespeicherter SHA-256-Hash uebereinstimmen.
    $pending = @($manifest.Chunks | Where-Object {
        $path = Join-Path $work $_.File
        -not $_.Hash -or -not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $_.Hash
    })
    if ($pending.Count) {
        $api = Invoke-RestMethod -Uri "$qwenBase/gradio_api/info" -TimeoutSec $TimeoutSec
        if (-not $api.named_endpoints.'/load_prompt_and_gen') { throw 'Qwen muss mit einem Base-Modell laufen (load_prompt_and_gen fehlt).' }
        $uploaded = Invoke-RestMethod -Method Post -Uri "$qwenBase/gradio_api/upload" -Form @{ files = $voice } -TimeoutSec $TimeoutSec
        if ($uploaded.Count -ne 1 -or $uploaded[0] -isnot [string]) { throw 'Ungueltige Qwen-Upload-Antwort.' }
    }
    Write-Host "Kapitel: $($pieces.Count) Abschnitte, $($pending.Count) noch zu erzeugen."
    for ($index = 0; $index -lt $manifest.Chunks.Count; $index++) {
        $chunk = $manifest.Chunks[$index]
        $path = Join-Path $work $chunk.File
        if ($chunk.Hash -and (Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $chunk.Hash) {
            Write-Host "Abschnitt $($index + 1)/$($pieces.Count): vorhanden."
            continue
        }
        [System.IO.File]::WriteAllText((Join-Path $work ([System.IO.Path]::ChangeExtension($chunk.File, '.txt'))), $chunk.Text)
        # Wiederholt nur den aktuellen Abschnitt; bereits validierte Abschnitte bleiben erhalten.
        for ($attempt = 0; $attempt -le $Retries; $attempt++) {
            try {
                Write-Host "Abschnitt $($index + 1)/$($pieces.Count): $($chunk.Text.Length) Zeichen, Versuch $($attempt + 1)."
                $payload = @{ data = @(@{ path = $uploaded[0]; orig_name = $voice.Name; meta = @{ _type = 'gradio.FileData' } }, $chunk.Text, $Language) } | ConvertTo-Json -Depth 6 -Compress
                $job = Invoke-RestMethod -Method Post -Uri "$qwenBase/gradio_api/call/load_prompt_and_gen" -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec $TimeoutSec
                if (-not $job.event_id -or $job.event_id -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Ungueltige Qwen-Auftrags-ID.' }
                $events = Invoke-RestMethod -Uri "$qwenBase/gradio_api/call/load_prompt_and_gen/$($job.event_id)" -TimeoutSec $TimeoutSec
                $result = Read-ChapterEvent $events
                if ($result.Count -ne 2 -or -not $result[0].path) { throw "Keine Audiodatei: $($result | ConvertTo-Json -Depth 5 -Compress)" }
                $download = [uri]::EscapeDataString($result[0].path)
                Invoke-WebRequest -Uri "$qwenBase/gradio_api/file=$download" -OutFile "$path.partial" -TimeoutSec $TimeoutSec | Out-Null
                Get-ChapterWave "$path.partial" | Out-Null
                [System.IO.File]::Move("$path.partial", $path, $true)
                $chunk.Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                Save-ChapterManifest $manifest $manifestPath
                break
            }
            catch {
                if ($attempt -eq $Retries) { throw }
                Write-Warning "Abschnitt fehlgeschlagen, erneuter Versuch: $($_.Exception.Message)"
            }
        }
    }
    Write-Host 'Fuege Audioabschnitte und Pausen zusammen ...'
    $seconds = Join-ChapterWaves $manifest.Chunks $work $output $SentencePause $ParagraphPause
    $summary = [pscustomobject]@{ AudioFile = $output; Chunks = $pieces.Count; DurationSeconds = [math]::Round($seconds, 2); WorkDirectory = $work }
}
finally { $lock.Dispose() }

if ($CleanUp) {
    # Entfernt Arbeitsdaten ausschliesslich nach erfolgreicher Erstellung der finalen WAV-Datei.
    Write-Host 'Entferne den abgeschlossenen Arbeitsordner ...'
    Remove-Item -LiteralPath $work -Recurse -Force
    $summary.WorkDirectory = $null
}
$summary