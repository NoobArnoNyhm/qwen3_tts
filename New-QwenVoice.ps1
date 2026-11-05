#Requires -Version 7.0
# Erstellt aus einer Audioaufnahme ein Qwen-Stimmprofil samt Transkript und Metadaten.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$AudioPath,

    [Parameter(Mandatory, Position = 1)]
    [ValidatePattern('^[\p{L}\p{N}][\p{L}\p{N} _-]{0,79}$')]
    [string]$Name,

    [uri]$WhisperUrl = 'http://localhost:5001/v1/audio/transcriptions',
    [uri]$QwenUrl = 'http://localhost:8000',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'data/voices'),

    [ValidateRange(3, 60)]
    [int]$ReferenceSeconds = 30,
    [ValidateRange(0, 86400)]
    [int]$ReferenceStartSeconds = 0,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')]
    [string]$ContainerName = 'qwen3-tts-qwen3-tts-1',

    [ValidateRange(1, 86400)]
    [int]$TimeoutSec = 1800
)

$ErrorActionPreference = 'Stop'

# Prueft Fehler externer Docker-Aufrufe, die sonst nicht automatisch geworfen werden.
function Invoke-ReferenceDocker {
    param([string[]]$DockerArguments)
    & docker @DockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Referenzaufbereitung im Qwen-Container fehlgeschlagen (Docker-Exitcode $LASTEXITCODE)."
    }
}

# Schneidet die konfigurierte Referenzpassage im Qwen-Container aus und konvertiert sie.
function New-ReferenceExcerpt {
    param([System.IO.FileInfo]$Source)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker wird fuer die Aufbereitung der Referenzaufnahme im Qwen-Container benoetigt.'
    }
    $identifier = [guid]::NewGuid().ToString('N')
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) "qwen-reference-$identifier"
    $remote = "/tmp/qwen-reference-$identifier"
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        # Audio bleibt zur Verarbeitung im Container, bis der normalisierte Ausschnitt bereitsteht.
        Invoke-ReferenceDocker @('exec', $ContainerName, 'mkdir', '-p', $remote) | Out-Null
        Invoke-ReferenceDocker @('cp', $Source.FullName, "${ContainerName}:$remote/input") | Out-Null
        Invoke-ReferenceDocker @('exec', $ContainerName, 'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-ss', [string]$ReferenceStartSeconds, '-i', "$remote/input", '-t', [string]$ReferenceSeconds,
            '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', "$remote/reference.wav") | Out-Null
        $duration = Invoke-ReferenceDocker @('exec', $ContainerName, 'ffprobe', '-v', 'error', '-show_entries',
            'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', "$remote/reference.wav")
        # Verifiziert die tatsaechliche Ausschnittlaenge, bevor das Ergebnis weiterverwendet wird.
        $seconds = [double]::Parse(($duration -join '').Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        if ($seconds -le 0 -or $seconds -gt $ReferenceSeconds + 0.1) {
            throw 'Der Referenzausschnitt ist leer oder laenger als angefordert. Startposition und Audiodatei pruefen.'
        }
        $path = Join-Path $directory 'reference.wav'
        Invoke-ReferenceDocker @('cp', "${ContainerName}:$remote/reference.wav", $path) | Out-Null
        return [pscustomobject]@{ File = Get-Item -LiteralPath $path; Directory = $directory; Seconds = $seconds }
    }
    catch {
        Remove-Item -LiteralPath $directory -Recurse -Force
        throw
    }
    finally {
        # Entfernt auch bei Fehlern den temporaeren Containerpfad.
        & docker exec $ContainerName rm -rf $remote | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Temporaere Referenzdateien im Container konnten nicht entfernt werden: $remote" }
    }
}

# Liest das von Gradio verwendete Server-Sent-Events-Format bis zum Abschlussereignis.
function Read-QwenResult {
    param([string]$Events)

    $eventType = ''
    $dataLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (($Events + "`n`n") -split '\r?\n')) {
        if ($line.StartsWith('event:')) {
            $eventType = $line.Substring(6).Trim()
        }
        elseif ($line.StartsWith('data:')) {
            $dataLines.Add($line.Substring(5).TrimStart())
        }
        elseif ([string]::IsNullOrWhiteSpace($line)) {
            if ($eventType -eq 'error') {
                throw "Qwen-API-Fehler: $($dataLines -join "`n")"
            }
            if ($eventType -eq 'complete') {
                $result = ($dataLines -join "`n") | ConvertFrom-Json
                return ,$result
            }
            $eventType = ''
            $dataLines.Clear()
        }
    }
    throw 'Qwen hat kein abgeschlossenes Ergebnis geliefert.'
}

# Validiert Eingaben und verhindert Namenskollisionen, bevor API-Aufrufe erfolgen.
if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
    throw 'Dieser Stimmname ist unter Windows reserviert.'
}
foreach ($endpoint in @($WhisperUrl, $QwenUrl)) {
    if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -notin @('http', 'https')) {
        throw 'API-Adressen muessen absolute HTTP- oder HTTPS-URLs sein.'
    }
}
$audioFile = Get-Item -LiteralPath $AudioPath
if ($audioFile.PSIsContainer -or $audioFile.Length -eq 0) {
    throw 'AudioPath muss auf eine nicht leere Audiodatei zeigen.'
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$destination = Join-Path $outputRoot $Name
if (Test-Path -LiteralPath $destination) {
    throw "Die Stimme '$Name' existiert bereits: $destination"
}
$qwenBase = $QwenUrl.AbsoluteUri.TrimEnd('/')
$api = Invoke-RestMethod -Uri "$qwenBase/gradio_api/info" -TimeoutSec $TimeoutSec
if (-not $api.named_endpoints.'/save_prompt') {
    throw 'Qwen bietet save_prompt nicht an. Bitte mit einem Base-Modell starten.'
}

Write-Host "Bereite maximal $ReferenceSeconds Sekunden Referenzaudio ab Sekunde $ReferenceStartSeconds auf ..."
$reference = New-ReferenceExcerpt -Source $audioFile
try {
    # Transkribiert denselben Ausschnitt, der anschliessend als Stimmreferenz hochgeladen wird.
    $audioFile = $reference.File
    Write-Host "Transkribiere den Referenzausschnitt ($($reference.Seconds) Sekunden) mit Whisper ..."
    $transcription = Invoke-RestMethod -Method Post -Uri $WhisperUrl -Form @{
        file = $audioFile
        response_format = 'json'
        task = 'transcribe'
    } -TimeoutSec $TimeoutSec
    $text = $transcription.Text
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) {
        throw 'Whisper hat keinen nicht leeren Text im JSON-Feld Text/text geliefert.'
    }
    $text = $text.Trim()

    Write-Host 'Uebertrage Aufnahme und Transkript an Qwen ...'
    $uploaded = Invoke-RestMethod -Method Post -Uri "$qwenBase/gradio_api/upload" -Form @{
        files = $audioFile
    } -TimeoutSec $TimeoutSec
    if ($uploaded.Count -ne 1 -or $uploaded[0] -isnot [string]) {
        throw 'Qwen hat keinen eindeutigen Upload-Pfad geliefert.'
    }
    # Gradio erwartet Datei-Metadaten, Transkript und den Schalter fuer automatische Transkription.
    $payload = @{
        data = @(
            @{ path = $uploaded[0]; orig_name = $audioFile.Name; meta = @{ _type = 'gradio.FileData' } },
            $text,
            $false
        )
    } | ConvertTo-Json -Depth 6 -Compress
    $job = Invoke-RestMethod -Method Post -Uri "$qwenBase/gradio_api/call/save_prompt" `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec $TimeoutSec
    if (-not $job.event_id -or $job.event_id -notmatch '^[a-zA-Z0-9_-]+$') {
        throw 'Qwen hat keine gueltige Auftrags-ID geliefert.'
    }
    Write-Host 'Erstelle das Stimmprofil ...'
    $events = Invoke-RestMethod -Uri "$qwenBase/gradio_api/call/save_prompt/$($job.event_id)" -TimeoutSec $TimeoutSec
    $result = Read-QwenResult -Events $events
    if ($result.Count -ne 2 -or -not $result[0].path) {
        throw "Qwen konnte kein Stimmprofil erstellen: $($result | ConvertTo-Json -Depth 5 -Compress)"
    }

    # Baut das Profil in einem Staging-Ordner auf und veroeffentlicht es erst vollstaendig.
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $staging = Join-Path $outputRoot ('.creating-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        $voicePath = Join-Path $staging "$Name.pt"
        $downloadPath = [uri]::EscapeDataString($result[0].path)
        Invoke-WebRequest -Uri "$qwenBase/gradio_api/file=$downloadPath" -OutFile $voicePath -TimeoutSec $TimeoutSec | Out-Null
        if ((Get-Item -LiteralPath $voicePath).Length -eq 0) {
            throw 'Das heruntergeladene Stimmprofil ist leer.'
        }
        [System.IO.File]::WriteAllText((Join-Path $staging 'transcript.txt'), $text, [System.Text.UTF8Encoding]::new($false))
        $metadata = @{
            ReferenceStartSeconds = $ReferenceStartSeconds
            ReferenceSeconds = $reference.Seconds
            CreatedAt = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $staging 'reference.json'), $metadata, [System.Text.UTF8Encoding]::new($false))
        [System.IO.Directory]::Move($staging, $destination)
    }
    finally {
        # Unvollstaendige Staging-Daten duerfen nicht als fertiges Profil zurueckbleiben.
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }

    [pscustomobject]@{
        Name = $Name
        VoiceFile = Join-Path $destination "$Name.pt"
        TranscriptFile = Join-Path $destination 'transcript.txt'
    }
}
finally {
    # Der lokale Referenzausschnitt wird nach Erfolg und Fehlern entfernt.
    Remove-Item -LiteralPath $reference.Directory -Recurse -Force
}