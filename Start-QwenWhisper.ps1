[CmdletBinding()]
# Startet oder verwaltet den separaten Whisper-Transkriptionsdienst.
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Logs', 'Status', 'Config')]
    [string]$Action = 'Start',

    [ValidateRange(1, 65535)]
    [int]$Port = 5001,

    [ValidateSet('tiny', 'base', 'small', 'medium', 'large-v3')]
    [string]$Model = 'small',

    [ValidateRange(1, 128)]
    [int]$Threads = 4
)

$ErrorActionPreference = 'Stop'

# Fuehrt Docker aus und meldet non-zero Exitcodes als Fehler.
function Invoke-Docker {
    param([string[]]$DockerArguments)

    & docker @DockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker ist mit Exitcode $LASTEXITCODE fehlgeschlagen."
    }
}

# Ohne Docker koennen weder Compose noch die zugehoerigen Container verwaltet werden.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker fehlt. Docker Desktop mit WSL2-Backend und Linux-Containern installieren.'
}

$previousPort = $env:QWEN_WHISPER_PORT
$previousModel = $env:QWEN_WHISPER_MODEL
$previousThreads = $env:QWEN_WHISPER_THREADS
# Uebergibt Einstellungen an Compose, ohne die Umgebung des Aufrufers dauerhaft zu aendern.
$env:QWEN_WHISPER_PORT = [string]$Port
$env:QWEN_WHISPER_MODEL = $Model
$env:QWEN_WHISPER_THREADS = [string]$Threads
$composeArguments = @(
    'compose', '--project-name', 'qwen3-whisper',
    '--project-directory', $PSScriptRoot,
    '--file', (Join-Path $PSScriptRoot 'compose.whisper.yaml')
)

try {
    # Prueft zuerst, ob die benoetigte Compose-Unterstuetzung installiert ist.
    Invoke-Docker -DockerArguments @('compose', 'version')

    switch ($Action) {
        'Start' {
            # Der Dienst benoetigt eine erreichbare Docker-Engine mit Linux-Containern.
            $engineType = & docker info --format '{{.OSType}}'
            if ($LASTEXITCODE -ne 0) {
                throw 'Docker Engine nicht erreichbar. Docker Desktop mit WSL2-Backend starten.'
            }
            if (($engineType | Out-String).Trim() -ne 'linux') {
                throw 'Docker Desktop muss Linux-Container verwenden.'
            }
            # Speichert Modell, Cache und temporaere Dateien getrennt von anderen Diensten.
            foreach ($directory in @('data/whisper/huggingface', 'data/whisper/cache', 'data/whisper/tmp')) {
                New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot $directory) -Force | Out-Null
            }
            Write-Host "Starte eigenen Whisper-Dienst mit Modell '$Model' auf CPU (int8)."
            Write-Host 'Der erste Start laedt das Modell herunter. Fremde Whisper-Container bleiben unveraendert.'
            Invoke-Docker -DockerArguments ($composeArguments + @('up', '--detach', '--wait', '--wait-timeout', '3600'))
            Write-Host "Whisper-API bereit: http://localhost:$Port/v1/audio/transcriptions"
        }
        # Verwaltungsaktionen nutzen dasselbe dedizierte Compose-Projekt.
        'Stop' {
            Invoke-Docker -DockerArguments ($composeArguments + @('down'))
        }
        'Logs' {
            Invoke-Docker -DockerArguments ($composeArguments + @('logs', '--follow', '--tail', '100'))
        }
        'Status' {
            Invoke-Docker -DockerArguments ($composeArguments + @('ps'))
        }
        'Config' {
            Invoke-Docker -DockerArguments ($composeArguments + @('config'))
        }
    }
}
finally {
    # Stellt die urspruenglichen Umgebungswerte der PowerShell-Sitzung wieder her.
    $env:QWEN_WHISPER_PORT = $previousPort
    $env:QWEN_WHISPER_MODEL = $previousModel
    $env:QWEN_WHISPER_THREADS = $previousThreads
}