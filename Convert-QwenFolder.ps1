#Requires -Version 7.0
# Konvertiert alle Textkapitel eines Ordners einzeln und sammelt deren Ergebnisse.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VoiceFile,
    [Parameter(Mandatory)]
    [string]$SourceDirectory,
    [ValidateSet('German', 'English', 'Chinese', 'Japanese', 'Korean', 'French', 'Russian', 'Portuguese', 'Spanish', 'Italian', 'Auto')]
    [string]$Language = 'German',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

# Validiert die gemeinsamen Eingaben vor dem Start der Stapelverarbeitung.
$voice = Get-Item -LiteralPath $VoiceFile
$source = Get-Item -LiteralPath $SourceDirectory
if ($voice.PSIsContainer -or $voice.Length -eq 0) { throw 'VoiceFile muss eine nicht leere Datei sein.' }
if (-not $source.PSIsContainer) { throw 'SourceDirectory muss ein Ordner sein.' }

# Verarbeitet nur Textdateien direkt im Quellordner, in stabiler alphabetischer Reihenfolge.
$chapters = @(Get-ChildItem -LiteralPath $source.FullName -File -Filter '*.txt' | Sort-Object Name)
if ($chapters.Count -eq 0) { throw "Keine .txt-Dateien im Quellordner gefunden: $($source.FullName)" }

$destination = $null
if ($OutputDirectory) {
    $destination = [System.IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
}

# Jedes Kapitel wird separat aufgerufen, damit ein Fehler die restlichen Kapitel nicht stoppt.
$converter = Join-Path $PSScriptRoot 'Convert-QwenChapter.ps1'
$results = [System.Collections.Generic.List[object]]::new()
foreach ($chapter in $chapters) {
    $outputPath = if ($destination) {
        Join-Path $destination "$($chapter.BaseName).wav"
    }
    else {
        Join-Path $PSScriptRoot "data/audiobooks/$($chapter.BaseName).wav"
    }
    Write-Host "Verarbeite $($chapter.Name) ..."
    try {
        # Uebergibt die normalisierten Pfade und die gewaehlte Sprache an den Einzelkonverter.
        $arguments = @{
            TextPath = $chapter.FullName
            VoiceFile = $voice.FullName
            Language = $Language
        }
        if ($outputPath) { $arguments.OutputPath = $outputPath }
        $null = & $converter @arguments
        $results.Add([pscustomobject]@{ TextPath = $chapter.FullName; OutputPath = $outputPath; Success = $true; Error = $null })
    }
    catch {
        # Erfasst Fehler pro Kapitel im Ergebnis und faehrt mit dem naechsten fort.
        $message = $_.Exception.Message
        Write-Warning "Fehler bei $($chapter.Name): $message"
        $results.Add([pscustomobject]@{ TextPath = $chapter.FullName; OutputPath = $outputPath; Success = $false; Error = $message })
    }
}

# Gibt eine Zusammenfassung sowie Details zu jedem einzelnen Kapitel zurueck.
[pscustomobject]@{
    Total = $results.Count
    Succeeded = @($results | Where-Object Success).Count
    Failed = @($results | Where-Object { -not $_.Success }).Count
    Results = $results.ToArray()
}