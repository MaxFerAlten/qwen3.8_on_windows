#Requires -Version 5.1
<#
.SYNOPSIS
    Avvia Qwen3.8-Flash-Next (llama-server Vulkan + esperti MoE su CPU).
    Esegue automaticamente setup.ps1 se i binari o il modello mancano.

.DESCRIPTION
    Punto di ingresso unico:
      1. Se llama-server.exe o il GGUF non sono presenti -> esegue setup.ps1
         (download/estrazione solo di cio' che manca, con resume).
      2. Avvia llama-server in background con la config ibrida per GPU AMD:
         -ngl 999, --cpu-moe (esperti MoE in RAM/CPU) e la tabella PLE
         tenuta su disco via -ot + mmap (mai --mlock/--no-mmap).
      3. Aspetta che /health risponda, apre il browser sulla WebUI e resta
         in primo piano (Ctrl+C ferma tutto).

    Nota: "compilazione" = download della build precompilata win-vulkan-x64
    (nessun toolchain necessario su Windows).

.PARAMETER Root
    Cartella creata da setup.ps1. Default D:\FlashNext.

.PARAMETER Port
    Porta HTTP del server. Default 8080.

.PARAMETER Ctx
    Dimensione contesto (RAM/VRAM). Default 8192; abbassa (es. 4096) se OOM.

.PARAMETER Threads
    Thread CPU. Default 16 (i7-13700KF).

.PARAMETER HealthTimeout
    Secondi massimi di attesa del pronto avvio (caricamento modello incluso).

.PARAMETER NoFlashAttn
    Disabilita Flash Attention (utile se Vulkan da' problemi).

.EXAMPLE
    .\runllama.ps1               # setup automatico se serve, poi avvia
    .\runllama.ps1 -Ctx 4096     # meno RAM/VRAM
    .\runllama.ps1 -Port 9000
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\FlashNext',
    [int]$Port      = 8080,
    [int]$Ctx       = 8192,
    [int]$Threads   = 16,
    [int]$HealthTimeout = 180,
    [switch]$NoFlashAttn
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Step { Write-Host "`n==> $args" -ForegroundColor Cyan }
function Write-Ok   { Write-Host "[OK]  $args" -ForegroundColor Green }
function Write-Fail { Write-Host "[FAIL] $args" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 0. Setup automatico se mancano binari o modello
# ---------------------------------------------------------------------------
$setupScript = Join-Path $PSScriptRoot 'setup.ps1'

$exe = Get-ChildItem -Path (Join-Path $Root 'llama.cpp') -Filter 'llama-server.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
$model = Get-ChildItem -Path (Join-Path $Root 'models') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*-00001-of-*.gguf' } | Select-Object -First 1

if (-not $exe -and -not $model) {
    Write-Step 'Binari e modello mancanti: eseguo setup.ps1 completo...'
    & $setupScript -Root $Root
    if ($LASTEXITCODE) { Write-Fail 'setup.ps1 fallito.'; exit 1 }
} elseif (-not $exe) {
    Write-Step 'llama-server.exe mancante: eseguo setup.ps1 (-SkipModel)...'
    & $setupScript -Root $Root -SkipModel
    if ($LASTEXITCODE) { Write-Fail 'setup.ps1 fallito.'; exit 1 }
} elseif (-not $model) {
    Write-Step 'Modello mancante: eseguo setup.ps1 (-SkipLlama)...'
    & $setupScript -Root $Root -SkipLlama
    if ($LASTEXITCODE) { Write-Fail 'setup.ps1 fallito.'; exit 1 }
}

$exe = Get-ChildItem -Path (Join-Path $Root 'llama.cpp') -Filter 'llama-server.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
$model = Get-ChildItem -Path (Join-Path $Root 'models') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*-00001-of-*.gguf' } | Select-Object -First 1
if (-not $exe)   { Write-Fail "llama-server.exe non trovato in $(Join-Path $Root 'llama.cpp')."; exit 1 }
if (-not $model) { Write-Fail "Nessun GGUF in $(Join-Path $Root 'models')."; exit 1 }

Write-Ok "Modello: $($model.FullName)"

# ---------------------------------------------------------------------------
# 1. Se un server e' gia' attivo sulla porta, apro solo il browser
# ---------------------------------------------------------------------------
$alreadyUp = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2
    $alreadyUp = ($r.StatusCode -eq 200)
} catch { }
if ($alreadyUp) {
    Write-Ok "Server gia' attivo su porta $Port : apro il browser."
    try { Start-Process "http://127.0.0.1:$Port/" } catch {}
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Avvio llama-server in background con log su file
# ---------------------------------------------------------------------------
$logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$outLog = Join-Path $logDir 'server.log'
$errLog = Join-Path $logDir 'server.err.log'
Remove-Item -Force $outLog, $errLog -ErrorAction SilentlyContinue

$argList = @(
    '-m', ('"{0}"' -f $model.FullName),
    '-ngl', '999',
    '--cpu-moe',
    '-ot', 'per_layer_token_embd.*=CPU',
    '--jinja',
    '-c', [string]$Ctx,
    '-t', [string]$Threads,
    '--host', '127.0.0.1',
    '--port', [string]$Port,
    '-b', '4096', '-ub', '1024'
)
if (-not $NoFlashAttn) { $argList += '-fa', 'on' }

Write-Step 'Avvio llama-server in background...'
$proc = Start-Process -FilePath $exe.FullName -ArgumentList $argList -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
Write-Ok "llama-server avviato (PID $($proc.Id)). Log: $outLog"

# ---------------------------------------------------------------------------
# 3. Attesa readiness
# ---------------------------------------------------------------------------
$ready = $false
for ($i = 0; $i -lt $HealthTimeout; $i++) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { break }
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
}

if (-not $ready) {
    Write-Fail "llama-server non pronto entro $HealthTimeout s."
    Write-Host '--- Ultime righe di server.err.log ---' -ForegroundColor Yellow
    Get-Content $errLog -Tail 40 -ErrorAction SilentlyContinue
    Write-Host '--- Ultime righe di server.log ---' -ForegroundColor Yellow
    Get-Content $outLog -Tail 40 -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    exit 1
}

Write-Ok "HTTP API:  http://127.0.0.1:$Port/v1/chat/completions"
Write-Ok "WebUI:     http://127.0.0.1:$Port/"
try { Start-Process "http://127.0.0.1:$Port/" } catch {}
Write-Host "`nChat CLI separata:  pwsh $Root\run-chat.ps1"
Write-Host 'Premi Ctrl+C per fermare il server.'

Write-Host "`nNOTA primo avvio: il modello viene caricato da RAM/disco in modo lazy." -ForegroundColor Yellow
Write-Host 'La PRIMA domanda puo'' impiegare parecchio tempo: il disco NVMe alimenta la page' -ForegroundColor Yellow
Write-Host 'cache con decine di GB di esperti MoE. E'' normale: NON fermare, aspetta.' -ForegroundColor Yellow
Write-Host 'Dalla seconda domanda in poi e'' molto piu veloce.' -ForegroundColor Yellow

try {
    while ($true) { Start-Sleep -Seconds 10 }
} finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    Write-Host "`nServer fermato."
}