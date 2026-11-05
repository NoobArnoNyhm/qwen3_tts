[CmdletBinding()]
# Startet oder verwaltet den Qwen3-TTS-Dienst ueber das Projekt-Compose-Setup.
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Logs', 'Status', 'Config')]
    [string]$Action = 'Start',

    [ValidateRange(1, 65535)]
    [int]$Port = 8000,

    [ValidateSet(
        'Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice',
        'Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice',
        'Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign',
        'Qwen/Qwen3-TTS-12Hz-0.6B-Base',
        'Qwen/Qwen3-TTS-12Hz-1.7B-Base'
    )]
    [string]$Model = 'Qwen/Qwen3-TTS-12Hz-0.6B-Base'
)

$ErrorActionPreference = 'Stop'

# Fuehrt Docker aus und macht Fehler des externen Prozesses zu PowerShell-Fehlern.
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

$previousPort = $env:QWEN_TTS_PORT
$previousModel = $env:QWEN_TTS_MODEL
# Compose liest diese Werte aus der Umgebung; die Originalwerte werden unten wiederhergestellt.
$env:QWEN_TTS_PORT = [string]$Port
$env:QWEN_TTS_MODEL = $Model
$composeArguments = @(
    'compose', '--project-name', 'qwen3-tts',
    '--project-directory', $PSScriptRoot,
    '--file', (Join-Path $PSScriptRoot 'compose.yaml')
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

            # Legt persistente Modell-, Gradio- und temporaere Datenverzeichnisse an.
            foreach ($directory in @('data/huggingface', 'data/gradio', 'data/tmp')) {
                New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot $directory) -Force | Out-Null
            }

            Write-Host 'Baue und starte Qwen3-TTS. Der erste Start laedt mehrere GB herunter.'
            Write-Host 'Voraussetzung: NVIDIA-GPU mit aktuellem Windows-Treiber und Docker-WSL2-GPU-Unterstuetzung.'
            Invoke-Docker -DockerArguments ($composeArguments + @('up', '--detach', '--build', '--wait', '--wait-timeout', '3600'))
            Write-Host "Weboberflaeche bereit: http://localhost:$Port"
        }
        # Die uebrigen Aktionen reichen Verwaltungsbefehle an dasselbe Compose-Projekt weiter.
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
    # Verhindert, dass die Compose-Umgebungswerte in der aufrufenden Sitzung verbleiben.
    $env:QWEN_TTS_PORT = $previousPort
    $env:QWEN_TTS_MODEL = $previousModel
}