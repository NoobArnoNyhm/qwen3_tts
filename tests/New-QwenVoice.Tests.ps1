#Requires -Version 7.0
# Integrationstests mit gemockten Docker- und HTTP-Aufrufen fuer die Stimmerstellung.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../New-QwenVoice.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qwen-voice-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$audioPath = Join-Path $testRoot 'sample.mp3'
[System.IO.File]::WriteAllBytes($audioPath, [byte[]]@(1, 2, 3))
$testState = @{
    Mode = 'success'
    Calls = [System.Collections.Generic.List[string]]::new()
    ReferenceText = 'Dies ist meine Stimme.'
    ReferenceFile = ''
    ExpectedSeconds = 20
    ExpectedStart = 0
}

function docker {
    # Simuliert Referenz-Audiozuschnitt, Laengenpruefung und Kopieren aus dem Container.
    param([Parameter(ValueFromRemainingArguments)][string[]]$DockerArguments)
    $global:LASTEXITCODE = 0
    if ($DockerArguments[0] -eq 'exec' -and $DockerArguments[2] -eq 'ffmpeg') {
        if ($testState.Mode -eq 'reference-error') { $global:LASTEXITCODE = 1; return }
        $durationIndex = [array]::IndexOf($DockerArguments, '-t')
        $startIndex = [array]::IndexOf($DockerArguments, '-ss')
        if ($DockerArguments[$durationIndex + 1] -ne [string]$testState.ExpectedSeconds -or
            $DockerArguments[$startIndex + 1] -ne [string]$testState.ExpectedStart) { throw 'Referenzdauer oder Startposition wurde nicht uebernommen.' }
    }
    if ($DockerArguments[0] -eq 'exec' -and $DockerArguments[2] -eq 'ffprobe') {
        if ($testState.Mode -eq 'empty-reference') { return '0.000000' }
        return [string]$testState.ExpectedSeconds
    }
    if ($DockerArguments[0] -eq 'cp' -and $DockerArguments[1] -like '*:/tmp/*/reference.wav') {
        $testState.ReferenceFile = $DockerArguments[2]
        [System.IO.File]::WriteAllBytes($testState.ReferenceFile, [byte[]]@(1, 2, 3))
    }
}

function Invoke-RestMethod {
    # Simuliert Whisper- und Gradio-Endpunkte sowie kontrollierte Fehlerfaelle.
    param($Uri, $Method, $Form, $ContentType, $Body, $TimeoutSec)
    $address = [string]$Uri
    $testState.Calls.Add($address)
    switch -Regex ($address) {
        '/gradio_api/info$' {
            if ($testState.Mode -eq 'wrong-model') { return @{ named_endpoints = @{} } }
            return @{ named_endpoints = @{ '/save_prompt' = @{ parameters = @() } } }
        }
        '/v1/audio/transcriptions$' {
            if ($Form.file.FullName -ne $testState.ReferenceFile -or $Form.task -ne 'transcribe') { throw 'Falscher Whisper-Upload.' }
            if ($testState.Mode -eq 'empty-text') { return @{ Text = ' ' } }
            return @{ Text = $testState.ReferenceText }
        }
        '/gradio_api/upload$' {
            if ($Form.files.FullName -ne $testState.ReferenceFile) { throw 'Falscher Qwen-Upload.' }
            return ,@('/data/gradio/sample.mp3')
        }
        '/gradio_api/call/save_prompt$' {
            $payload = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            if ($payload.data[0].path -ne '/data/gradio/sample.mp3' -or
                $payload.data[1] -ne $testState.ReferenceText -or $payload.data[2] -ne $false) {
                throw 'Falsche save_prompt-Parameter.'
            }
            return @{ event_id = 'test-job' }
        }
        '/gradio_api/call/save_prompt/test-job$' {
            if ($testState.Mode -eq 'api-error') { return "event: error`ndata: " + '"failed"' + "`n`n" }
            if ($testState.Mode -eq 'model-error') { return "event: complete`ndata: " + '[null, "RuntimeError"]' + "`n`n" }
            return "event: heartbeat`ndata: null`n`nevent: complete`ndata: " + '[{"path":"/data/tmp/voice.pt"},"Finished"]' + "`n`n"
        }
        default { throw "Unerwarteter API-Aufruf: $address" }
    }
}

function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec)
    if ([string]$Uri -notlike '*/gradio_api/file=*') { throw 'Falscher Download-Endpunkt.' }
    if ($testState.Mode -eq 'download-error') { throw 'Download unterbrochen.' }
    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]@(10, 20, 30))
}

try {
    # Prueft einen erfolgreichen Ablauf, Persistenz und Ablehnung doppelter Namen.
    $output = Join-Path $testRoot 'voices'
    $created = & $scriptPath -AudioPath $audioPath -Name 'Meine Stimme' -OutputDirectory $output
    if (-not $testState.Calls.Contains('http://localhost:5001/v1/audio/transcriptions')) {
        throw 'Stimmerstellung verwendet nicht den projekteigenen Whisper auf Port 5001.'
    }
    if (-not (Test-Path -LiteralPath $created.VoiceFile) -or
        [System.IO.File]::ReadAllText($created.TranscriptFile) -ne $testState.ReferenceText) {
        throw 'Stimmprofil oder Transkript fehlt.'
    }
    if (Test-Path -LiteralPath $testState.ReferenceFile) { throw 'Temporaerer Ausschnitt wurde nicht entfernt.' }
    $metadata = Get-Content -LiteralPath (Join-Path (Split-Path $created.VoiceFile) 'reference.json') -Raw | ConvertFrom-Json
    if ($metadata.ReferenceSeconds -ne 20) { throw 'Referenzdauer wurde nicht gespeichert.' }
    $callCount = $testState.Calls.Count
    try {
        & $scriptPath -AudioPath $audioPath -Name 'Meine Stimme' -OutputDirectory $output
        throw 'Doppelter Name wurde akzeptiert.'
    }
    catch {
        if ($_.Exception.Message -notlike '*existiert bereits*') { throw }
    }
    if ($testState.Calls.Count -ne $callCount) { throw 'Doppelter Name hat API-Aufrufe ausgeloest.' }
    # Jeder simulierte Fehler muss sichtbar sein und darf kein unvollstaendiges Profil hinterlassen.
    foreach ($failureMode in @('wrong-model', 'reference-error', 'empty-reference', 'empty-text', 'api-error', 'model-error', 'download-error')) {
        $testState.Mode = $failureMode
        $failed = $false
        try { & $scriptPath -AudioPath $audioPath -Name $failureMode -OutputDirectory $output }
        catch { $failed = $true }
        if (-not $failed) { throw "Fehlerfall wurde nicht erkannt: $failureMode" }
        if (Test-Path -LiteralPath (Join-Path $output $failureMode)) { throw 'Unfertiges Profil wurde persistiert.' }
    }
    # Prueft ausserdem benutzerdefinierte Dauer und Startposition des Referenzausschnitts.
    $testState.Mode = 'success'
    $testState.ExpectedSeconds = 12
    $testState.ExpectedStart = 60
    $custom = & $scriptPath -AudioPath $audioPath -Name 'Ausschnitt' -OutputDirectory $output -ReferenceSeconds 12 -ReferenceStartSeconds 60
    $metadata = Get-Content -LiteralPath (Join-Path (Split-Path $custom.VoiceFile) 'reference.json') -Raw | ConvertFrom-Json
    if ($metadata.ReferenceSeconds -ne 12 -or $metadata.ReferenceStartSeconds -ne 60) { throw 'Ausschnittparameter wurden nicht gespeichert.' }
    if (Get-ChildItem -LiteralPath $output -Force -Filter '.creating-*') { throw 'Temporaere Dateien wurden nicht entfernt.' }
    Write-Output 'PASS: Begrenzter Referenzausschnitt, Startposition, API-Ablauf, Persistenz, doppelte Namen und sieben Fehlerfaelle.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}