#Requires -Version 7.0
# Tests Chunking, Wiederaufnahme, WAV-Zusammenfuehrung und Fehlerbehandlung des Kapitelkonverters.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../Convert-QwenChapter.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qwen-chapter-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$testState = @{ Requests = [System.Collections.Generic.List[string]]::new(); FailAt = 2; Fail = $true; InvalidWave = $false }

function Invoke-RestMethod {
    # Simuliert Gradio-Auftraege und zeichnet die an Qwen uebergebenen Textabschnitte auf.
    param($Uri, $Method, $Form, $ContentType, $Body, $TimeoutSec)
    switch -Regex ([string]$Uri) {
        '/gradio_api/info$' { return @{ named_endpoints = @{ '/load_prompt_and_gen' = @{} } } }
        '/gradio_api/upload$' { return ,@('/data/voice.pt') }
        '/call/load_prompt_and_gen$' {
            $payload = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            if ($payload.data[0].path -ne '/data/voice.pt' -or $payload.data[2] -ne 'German') { throw 'Falsche API-Parameter.' }
            $testState.Requests.Add($payload.data[1])
            if ($testState.Fail -and $testState.Requests.Count -eq $testState.FailAt) { throw 'Simulierter Verbindungsabbruch.' }
            return @{ event_id = 'job' }
        }
        '/call/load_prompt_and_gen/job$' { return "event: complete`ndata: " + '[{"path":"/data/audio.wav"},"Finished"]' + "`n`n" }
        default { throw "Unerwartete API-Adresse: $Uri" }
    }
}

function Invoke-WebRequest {
    # Liefert je nach Testfall eine gueltige oder absichtlich ungueltige WAV-Datei.
    param($Uri, $OutFile, $TimeoutSec)
    if ($testState.InvalidWave) { [System.IO.File]::WriteAllText($OutFile, 'invalid'); return }
    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($OutFile))
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32]436)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32]16)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([uint32]1000)
        $writer.Write([uint32]2000)
        $writer.Write([uint16]2)
        $writer.Write([uint16]16)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]400)
        $writer.Write([byte[]]::new(400))
    }
    finally { $writer.Dispose() }
}

try {
    # Prueft, dass ein Teilfehler Fortschritt und Manifest fuer eine spaetere Fortsetzung erhaelt.
    $textPath = Join-Path $testRoot 'chapter.txt'
    $voicePath = Join-Path $testRoot 'voice.pt'
    $output = Join-Path $testRoot 'chapter.wav'
    $text = 'Der erste Absatz besteht aus mehreren Saetzen. Er soll nicht verloren gehen.' + "`n`n" +
        ('Ein weiterer Satz mit einigen Worten zum Testen. ' * 7) + ('Langwort' * 24)
    [System.IO.File]::WriteAllText($textPath, $text)
    [System.IO.File]::WriteAllBytes($voicePath, [byte[]]@(1, 2, 3))
    $failed = $false
    try { & $scriptPath -TextPath $textPath -VoiceFile $voicePath -OutputPath $output -MaxChars 100 -Retries 0 }
    catch { if ($_.Exception.Message -notlike '*Simulierter Verbindungsabbruch*') { throw }; $failed = $true }
    if (-not $failed -or (Test-Path -LiteralPath $output)) { throw 'Abbruch wurde nicht korrekt behandelt.' }
    $manifest = Get-Content -LiteralPath "$output.work/job.json" -Raw | ConvertFrom-Json
    if (-not $manifest.Chunks[0].Hash) { throw 'Erster Abschnitt wurde nicht gesichert.' }
    if (@($manifest.Chunks | Where-Object { $_.Text.Length -gt 100 }).Count) { throw 'Abschnitt ist zu lang.' }
    $restored = ($manifest.Chunks.Text -join '') -replace '\s', ''
    if ($restored -cne ($text -replace '\s', '')) { throw 'Text ging beim Chunking verloren.' }
    if (-not $manifest.Chunks[0].ParagraphEnd) { throw 'Absatzgrenze ging verloren.' }
    # Verifiziert anschliessend Resume, Cache-Validierung, Wiederholung und Bereinigung.
    $testState.Fail = $false
    $testState.Requests.Clear()
    $result = & $scriptPath -TextPath $textPath -VoiceFile $voicePath -OutputPath $output -MaxChars 100 -Retries 0 -CleanUp:$false
    if (-not (Test-Path -LiteralPath "$output.work/job.json") -or $result.WorkDirectory -ne "$output.work") {
        throw 'CleanUp false hat den Arbeitsordner nicht erhalten.'
    }
    if ($testState.Requests.Count -ne $manifest.Chunks.Count - 1) { throw 'Bereits fertiger Abschnitt wurde erneut generiert.' }
    $expectedPause = 0.0
    for ($index = 0; $index -lt $manifest.Chunks.Count - 1; $index++) {
        $expectedPause += $(if ($manifest.Chunks[$index].ParagraphEnd) { 0.6 } else { 0.2 })
    }
    $expectedLength = 44 + $manifest.Chunks.Count * 400 + [int][math]::Round($expectedPause * 2000)
    if ((Get-Item -LiteralPath $output).Length -ne $expectedLength) { throw 'WAV-Laenge oder Pausen sind falsch.' }
    if ([math]::Abs($result.DurationSeconds - ($expectedLength - 44) / 2000) -gt 0.01) { throw 'Falsche Audiodauer.' }
    Remove-Item -LiteralPath $output
    [System.IO.File]::WriteAllText((Join-Path "$output.work" $manifest.Chunks[1].File), 'corrupt')
    $testState.Requests.Clear()
    & $scriptPath -TextPath $textPath -VoiceFile $voicePath -OutputPath $output -MaxChars 100 -Retries 0 -CleanUp:$false | Out-Null
    if ($testState.Requests.Count -ne 1) { throw 'Beschaedigter Abschnitt wurde nicht gezielt neu erzeugt.' }
    Remove-Item -LiteralPath $output
    $testState.Requests.Clear()
    $testState.FailAt = 1
    $testState.Fail = $true
    $retryOutput = Join-Path $testRoot 'retry.wav'
    $cleaned = & $scriptPath -TextPath $textPath -VoiceFile $voicePath -OutputPath $retryOutput -MaxChars 100 -Retries 1
    if (-not (Test-Path -LiteralPath $retryOutput) -or (Test-Path -LiteralPath "$retryOutput.work") -or $null -ne $cleaned.WorkDirectory) {
        throw 'Standard-CleanUp hat Arbeitsdateien behalten oder die Ausgabe entfernt.'
    }
    if ($testState.Requests.Count -ne $manifest.Chunks.Count + 1) { throw 'Automatische Wiederholung ist fehlgeschlagen.' }
    $testState.Fail = $false
    [System.IO.File]::AppendAllText($textPath, ' Veraendert.')
    $failed = $false
    try { & $scriptPath -TextPath $textPath -VoiceFile $voicePath -OutputPath $output -MaxChars 100 }
    catch { if ($_.Exception.Message -notlike '*geaendert*') { throw }; $failed = $true }
    if (-not $failed) { throw 'Geaenderter Text wurde beim Fortsetzen akzeptiert.' }
    $testState.InvalidWave = $true
    $invalidOutput = Join-Path $testRoot 'invalid.wav'
    $failed = $false
    try { & $scriptPath -TextPath $textPath -VoiceFile $voicePath -OutputPath $invalidOutput -Retries 0 }
    catch { $failed = $true }
    if (-not $failed -or (Test-Path -LiteralPath $invalidOutput)) { throw 'Ungueltiges Audio wurde akzeptiert.' }
    if (-not (Test-Path -LiteralPath "$invalidOutput.work/job.json")) { throw 'Arbeitsordner wurde trotz Fehler entfernt.' }
    Write-Output 'PASS: CleanUp-Standard, CleanUp false, Erhalt bei Fehlern, Textvollstaendigkeit, Laengenlimit, Absatzgrenzen, Abbruch/Fortsetzen, Wiederholungen, defekter Cache, WAV-Pausen, geaenderte Eingaben und ungueltiges Audio.'
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }