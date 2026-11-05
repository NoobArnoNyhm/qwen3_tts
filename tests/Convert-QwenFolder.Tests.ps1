#Requires -Version 7.0
# Tests der Stapelverarbeitung mit simulierten Qwen-Aufrufen und WAV-Antworten.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../Convert-QwenFolder.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qwen-folder-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'chapters'
$output = Join-Path $testRoot 'audio'
New-Item -ItemType Directory -Path $source | Out-Null
$testState = [System.Collections.Generic.List[object]]::new()

function Invoke-RestMethod {
    # Zeichnet Sprache und Text auf und simuliert einen Fehler in einem einzelnen Kapitel.
    param($Uri, $Method, $Form, $ContentType, $Body, $TimeoutSec)
    switch -Regex ([string]$Uri) {
        '/gradio_api/info$' { return @{ named_endpoints = @{ '/load_prompt_and_gen' = @{} } } }
        '/gradio_api/upload$' { return ,@('/data/voice.pt') }
        '/call/load_prompt_and_gen$' {
            $payload = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            $testState.Add([pscustomobject]@{ Text = $payload.data[1]; Language = $payload.data[2] })
            if ($payload.data[1] -eq 'Fehlerkapitel') { throw 'Simulierter Verbindungsfehler.' }
            return @{ event_id = 'job' }
        }
        '/call/load_prompt_and_gen/job$' { return "event: complete`ndata: " + '[{"path":"/data/audio.wav"},"Finished"]' + "`n`n" }
        default { throw "Unerwartete API-Adresse: $Uri" }
    }
}

function Invoke-WebRequest {
    # Erstellt eine minimale gueltige PCM-WAV-Datei fuer die Ausgabepruefungen.
    param($Uri, $OutFile, $TimeoutSec)
    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($OutFile))
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32]38)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32]16)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([uint32]1000)
        $writer.Write([uint32]2000)
        $writer.Write([uint16]2)
        $writer.Write([uint16]16)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]2)
        $writer.Write([byte[]]::new(2))
    }
    finally { $writer.Dispose() }
}

try {
    # Erzeugt sortierbare Testkapitel und Dateien, die absichtlich ignoriert werden muessen.
    [System.IO.File]::WriteAllBytes((Join-Path $testRoot 'voice.pt'), [byte[]]@(1, 2, 3))
    [System.IO.File]::WriteAllText((Join-Path $source '02-second.txt'), 'Zweites Kapitel')
    [System.IO.File]::WriteAllText((Join-Path $source '01-first.txt'), 'Erstes Kapitel')
    [System.IO.File]::WriteAllText((Join-Path $source '03-fails.txt'), 'Fehlerkapitel')
    [System.IO.File]::WriteAllText((Join-Path $source 'ignore.md'), 'Kein Kapitel')
    New-Item -ItemType Directory -Path (Join-Path $source 'nested') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $source 'nested/ignored.txt'), 'Kein Kapitel')

    # Prueft Filter, Reihenfolge, Ausgabe und Fortsetzung nach einem Einzelkapitelfehler.
    $result = & $scriptPath -VoiceFile (Join-Path $testRoot 'voice.pt') -SourceDirectory $source -OutputDirectory $output
    if ($result.Total -ne 3 -or $result.Succeeded -ne 2 -or $result.Failed -ne 1) { throw 'Stapelzusammenfassung ist falsch.' }
    if ($result.Results[0].TextPath -notlike '*01-first.txt' -or $result.Results[1].TextPath -notlike '*02-second.txt') {
        throw 'Textdateien wurden nicht alphabetisch verarbeitet.'
    }
    if ($result.Results[0].OutputPath -ne (Join-Path $output '01-first.wav') -or
        -not (Test-Path -LiteralPath (Join-Path $output '01-first.wav')) -or
        -not (Test-Path -LiteralPath (Join-Path $output '02-second.wav'))) {
        throw 'WAV-Dateien fehlen im Zielordner oder haben falsche Namen.'
    }
    if (@($testState | Where-Object Language -ne 'German').Count -ne 0) { throw 'Standard-Sprache ist nicht German.' }
    if ($result.Results[2].Success -or $result.Results[2].Error -notlike '*Simulierter Verbindungsfehler*') {
        throw 'Fehler des Einzelkapitels wurde nicht im Ergebnis erfasst.'
    }
    # Die explizite Sprachauswahl muss bis zum Qwen-Aufruf durchgereicht werden.
    $overrideSource = Join-Path $testRoot 'english'
    New-Item -ItemType Directory -Path $overrideSource | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $overrideSource 'chapter.txt'), 'English chapter')
    $testState.Clear()
    $override = & $scriptPath -VoiceFile (Join-Path $testRoot 'voice.pt') -SourceDirectory $overrideSource `
        -OutputDirectory (Join-Path $testRoot 'english-audio') -Language English
    if (-not $override.Results[0].Success -or $testState[0].Language -ne 'English') { throw 'Language-Override wurde nicht weitergereicht.' }
    Write-Output 'PASS: Dateifilter, Sortierung, Standard-Sprache, Language-Override, Zielpfade und Fortsetzen nach Einzelfehler.'
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }