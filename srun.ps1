#Requires -Version 5.1
<#
.SYNOPSIS
    Avviatore unico con scelta della cartella di destinazione.
    Chiede dove mettere FlashNext (default: <cartella corrente>\FlashNext),
    poi esegue setup.ps1 (download/verifica) e infine runllama.ps1 (server).

.DESCRIPTION
    Flusso:  scelta path -> setup.ps1 (-Root) -> runllama.ps1 (-Root).
    Il default proposto e' la cartella FlashNext nella directory in cui
    viene lanciato srun.ps1; puoi accettarlo premendo Invio oppure
    scrivere un nuovo path assoluto.

.PARAMETER Root
    Non richiede il prompt e usa direttamente questo path assoluto.

.PARAMETER SkipSetup
    Salta setup.ps1 e va dritto a runllama.ps1.

.PARAMETER SkipModel
    Inoltra -SkipModel a setup.ps1 (solo binari llama.cpp).

.PARAMETER SkipLlama
    Inoltra -SkipLlama a setup.ps1 (solo GGUF).

.PARAMETER Quant
    Inoltra la quantizzazione a setup.ps1 (es. UD-Q2_K_XL).

.PARAMETER Port / Ctx / Threads / HealthTimeout / NoFlashAttn
    Inoltrati a runllama.ps1 (vedi la sua documentazione).

.EXAMPLE
    .\srun.ps1                      # prompt -> setup -> avvio
    .\srun.ps1 -Root D:\FlashNext   # senza prompt
    .\srun.ps1 -SkipSetup           # riavvio rapido del server
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$Quant,
    [switch]$SkipSetup,
    [switch]$SkipModel,
    [switch]$SkipLlama,
    [int]$Port          = 8080,
    [int]$Ctx           = 8192,
    [int]$Threads       = 16,
    [int]$HealthTimeout = 180,
    [switch]$NoFlashAttn
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$here = $PSScriptRoot
$setupScript    = Join-Path $here 'setup.ps1'
$runLlamaScript = Join-Path $here 'runllama.ps1'

if (-not (Test-Path $setupScript))    { Write-Host '[FAIL] setup.ps1 non trovato accanto a srun.ps1.'    -ForegroundColor Red; exit 1 }
if (-not (Test-Path $runLlamaScript)) { Write-Host '[FAIL] runllama.ps1 non trovato accanto a srun.ps1.' -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# 1. Scelta della cartella di destinazione (path assoluto)
# ---------------------------------------------------------------------------
if (-not $Root) {
    $default = Join-Path (Get-Location).Path 'FlashNext'
    $answer  = Read-Host "Cartella di destinazione (default: $default)"
    if ($answer -and $answer.Trim()) { $Root = $answer.Trim().Trim('"').Trim("'") }
    else { $Root = $default }
}

if (-not [IO.Path]::IsPathRooted($Root)) {
    Write-Host '[FAIL] Il path deve essere assoluto, es. D:\FlashNext.' -ForegroundColor Red
    exit 1
}
$Root = [IO.Path]::GetFullPath($Root.TrimEnd('\')).TrimEnd('\')

Write-Host "`n==> Destinazione: $Root" -ForegroundColor Cyan
if (Test-Path $Root) {
    Write-Host '[OK]  Cartella esistente: i download incompleti verranno ripresi.' -ForegroundColor Green
} else {
    Write-Host '[OK]  Nuova cartella da creare.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 2. setup.ps1 (download/verifica)
# ---------------------------------------------------------------------------
if (-not $SkipSetup) {
    Write-Host "`n==> [1/2] setup.ps1 ...`n"
    $setupArgs = @{ Root = $Root }
    if ($Quant)      { $setupArgs.Quant = $Quant }
    if ($SkipModel)  { $setupArgs.SkipModel = $true }
    if ($SkipLlama)  { $setupArgs.SkipLlama = $true }
    & $setupScript @setupArgs
    if ($LASTEXITCODE) {
        Write-Host "`n[FAIL] setup.ps1 terminato con errore ($LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 3. runllama.ps1 (avvio server)
# ---------------------------------------------------------------------------
Write-Host "`n==> [2/2] Avvio runllama.ps1 ...`n"
$runArgs = @{
    Root          = $Root
    Port          = $Port
    Ctx           = $Ctx
    Threads       = $Threads
    HealthTimeout = $HealthTimeout
}
if ($NoFlashAttn) { $runArgs.NoFlashAttn = $true }
& $runLlamaScript @runArgs
exit $LASTEXITCODE