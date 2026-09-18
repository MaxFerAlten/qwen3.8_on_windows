#Requires -Version 5.1
<#
.SYNOPSIS
    Scarica llama.cpp (build Windows Vulkan) e una quantizzazione GGUF di
    Qwen3.8-Flash-Next pronta per girare con expert MoE su CPU.

.DESCRIPTION
    Crea una cartella self-contained (di default D:\FlashNext) con:
      - llama.cpp\ : build win-vulkan-x64 piu recente con llama-server/llama-cli
      - models\QUANT\ : shard GGUF della quantizzazione scelta
      - quant.txt : quantizzazione selezionata
      - run-server.ps1 / run-chat.ps1 : avvio server/chat con expert su CPU

    Il download dei GGUF usa curl.exe con resume (-C -) e verifica la
    dimensione di ogni file contro la HF API. Riusabile: se un file e gia
    presente con la taglia attesa viene saltato.

.PARAMETER Quant
    Quantizzazione unsloth da scaricare. Default: UD-Q3_K_XL (~84 GB,
    buon compromesso qualita/memoria per 64 GB RAM). Alternative verificate:
    UD-Q2_K_XL (~73 GB, piu leggera), UD-Q4_K_XL (~104 GB, qualita migliore
    ma working set vicino al limite dei 64 GB).

.PARAMETER Repo
    Repo HuggingFace dei GGUF. Default unsloth/Qwen3.8-Flash-Next-GGUF.

.PARAMETER Root
    Cartella di destinazione. Default D:\FlashNext (servono ~90 GB liberi).

.PARAMETER SkipLlama
    Salta il download/estrazione di llama.cpp.

.PARAMETER SkipModel
    Salta il download del modello.

.EXAMPLE
    pwsh .\setup.ps1                      # quant default, tutto su D:\FlashNext
    pwsh .\setup.ps1 -Quant UD-Q2_K_XL    # quant piu leggera
    pwsh .\setup.ps1 -SkipModel           # solo llama.cpp
#>
[CmdletBinding()]
param(
    [string]$Quant = 'UD-Q3_K_XL',
    [string]$Repo = 'unsloth/Qwen3.8-Flash-Next-GGUF',
    [string]$Root = 'D:\FlashNext',
    [switch]$SkipLlama,
    [switch]$SkipModel
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1: forza TLS 1.2 per le API GitHub/HuggingFace
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Step { Write-Host "`n==> $args" -ForegroundColor Cyan }
function Write-Ok   { Write-Host "[OK]  $args" -ForegroundColor Green }
function Write-Warn { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Write-Fail { Write-Host "[FAIL] $args" -ForegroundColor Red }

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Fail 'curl.exe non trovato (serve Windows 10 1803+ o nuovo).'
    exit 1
}

$LlamaDir  = Join-Path $Root 'llama.cpp'
$ModelRoot = Join-Path $Root 'models'
$ModelDir  = Join-Path $ModelRoot $Quant
$QuantFile = Join-Path $Root 'quant.txt'

# ---------------------------------------------------------------------------
# 0. Preflight disco e cartelle
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

if (-not $SkipModel) {
    $drive = [System.IO.Path]::GetPathRoot($Root)
    $p = Get-PSDrive -Name ($drive.TrimEnd('\')[0]) -ErrorAction SilentlyContinue
    if ($p) {
        $freeGB = [math]::Round($p.Free / 1GB, 1)
        Write-Ok "Spazio libero su $drive : $freeGB GB"
        if ($freeGB -lt 95) {
            Write-Warn "Servono ~90 GB. Hai $freeGB GB: usa -Quant UD-Q2_K_XL (~73 GB) o otra unita (-Root)."
        }
    } else {
        Write-Warn "Non riesco a leggere lo spazio su $drive ."
    }
}

# ---------------------------------------------------------------------------
# Helpers: tabella GGUF dalla HF API + download con resume
# ---------------------------------------------------------------------------
function Get-GGUFShards {
    param([string]$RepoId, [string]$QuantName)
    $url = "https://huggingface.co/api/models/$($RepoId)/tree/main/$($QuantName)?recursive=true"
    try {
        $items = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'flash-next-setup' } -ErrorAction Stop
    } catch {
        Write-Fail "Quant '$QuantName' non trovata in '$RepoId'. URL: $url"
        exit 1
    }
    $shards = @($items | Where-Object { $_.type -eq 'file' -and $_.path -like '*.gguf' })
    if ($shards.Count -eq 0) { Write-Fail "Nessun file .gguf in $RepoId/$QuantName"; exit 1 }
    return $shards
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile, [int64]$ExpectedSize, [string]$Label)
    if (Test-Path $OutFile) {
        $len = (Get-Item $OutFile).Length
        if ($len -eq $ExpectedSize) { Write-Ok "${Label}: gia presente."; return }
        Write-Warn "${Label}: file incompleto, riprendo da $([math]::Round($len/1MB,1)) MB..."
    }
    curl.exe -L -C - --retry 5 --retry-delay 5 --retry-all-errors -o $OutFile $Url
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Download fallito per $Label (curl exit $LASTEXITCODE). Rilancia per riprendere."
        exit 1
    }
    $len = (Get-Item $OutFile).Length
    if ($len -ne $ExpectedSize) {
        Write-Fail "${Label}: taglia attesa $([math]::Round($ExpectedSize/1MB,1)) MB ma ricevuti $([math]::Round($len/1MB,1)) MB. Rilancia."
        exit 1
    }
    Write-Ok "${Label}: $([math]::Round($len/1GB,2)) GB"
}

# ---------------------------------------------------------------------------
# 1. llama.cpp Windows Vulkan x64 (ultima build con asset binario)
# ---------------------------------------------------------------------------
function Get-NewestVulkanBuild {
    $url = 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30'
    $rels = Invoke-RestMethod -Uri $url -Headers @{
        'User-Agent' = 'flash-next-setup'
        'Accept'     = 'application/vnd.github+json'
    }
    foreach ($rel in $rels) {
        $asset = @($rel.assets | Where-Object { $_.name -match '^llama-.+-bin-win-vulkan-x64\.zip$' } | Select-Object -First 1)
        if ($asset) {
            return [pscustomobject]@{
                Tag  = $rel.tag_name
                Name = $asset[0].name
                Url  = $asset[0].browser_download_url
            }
        }
    }
    return $null
}

if (-not $SkipLlama) {
    Write-Step 'Cerco la build Windows Vulkan piu recente di llama.cpp...'
    $build = Get-NewestVulkanBuild
    if (-not $build) {
        Write-Fail 'Nessuna build win-vulkan-x64 trovata nelle ultime 30 release.'
        exit 1
    }
    Write-Ok "Trovata: $($build.Name) (tag $($build.Tag))"

    $zipUrl = $build.Url
    $zipPath = Join-Path $Root $build.Name
    Write-Step "Scarico llama.cpp..."
    # dimensione ignota a priori: curl -L fetches it; sfogliamo OGNI volta che non esiste
    if (Test-Path $zipPath) {
        Write-Ok 'llama.cpp: zip gia presente.'
    } else {
        curl.exe -L -C - --retry 5 --retry-delay 5 --retry-all-errors -o $zipPath $zipUrl
        if ($LASTEXITCODE -ne 0) { Write-Fail 'Download llama.cpp fallito.'; exit 1 }
        Write-Ok "llama.cpp: $([math]::Round((Get-Item $zipPath).Length/1MB,1)) MB"
    }

    Write-Step 'Estraggo...'
    if (Test-Path $LlamaDir) { Remove-Item -Recurse -Force $LlamaDir }
    Expand-Archive -Path $zipPath -DestinationPath $LlamaDir -Force

    $exe = Get-ChildItem -Path $LlamaDir -Filter 'llama-server.exe' -Recurse | Select-Object -First 1
    if (-not $exe) { Write-Fail 'llama-server.exe non trovato nella build estratta.'; exit 1 }
    Write-Ok "Eseguibili in $([IO.Path]::GetDirectoryName($exe.FullName))"
}

# ---------------------------------------------------------------------------
# 2. Scarica i GGUF
# ---------------------------------------------------------------------------
if (-not $SkipModel) {
    Write-Step "Leggo i file GGUF da $Repo/$Quant..."
    $shards = Get-GGUFShards -RepoId $Repo -QuantName $Quant
    $totalGB = [math]::Round((($shards | Measure-Object size -Sum).Sum) / 1GB, 2)
    Write-Ok "Trovati $($shards.Count) shard per un totale di ~$totalGB GB."

    # ordina ascendente per nome: il primissimo file *00001-of-N.gguf
    foreach ($s in ($shards | Sort-Object path)) {
        $fname = Split-Path $s.path -Leaf
        Write-Step "Scarico $fname..."
        $url = "https://huggingface.co/$Repo/resolve/main/$Quant/$fname`?download=true"
        $out = Join-Path $ModelDir $fname
        Invoke-Download -Url $url -OutFile $out -ExpectedSize ([int64]$s.size) -Label $fname
    }
    Set-Content -Path $QuantFile -Value $Quant -Encoding utf8
}

# ---------------------------------------------------------------------------
# 3. Genera gli script di avvio
# ---------------------------------------------------------------------------
$serverTpl = @'
#Requires -Version 5.1
<#
  Avvia llama-server (API OpenAI-compatibile) con Qwen3.8-Flash-Next.
  Configurazione pensata per GPU AMD (Vulkan) 8-16 GB + 64 GB RAM:
    -ngl 999                     tutto cio' che puo' su GPU (Vulkan)
    --cpu-moe                    esperti MoE (routed) su CPU/RAM  <<core trick
    -ot PLE=CPU                  tabella n-gram per_layer_token_embd su disco (mmap, pagine solo quando lette)
  Lascia mmap attivo (NON usare --no-mmap: la table PLE deve restare su disco).
#>
param(
    [int]$Port      = 8080,
    [int]$Ctx       = 8192,
    [int]$Threads   = 16,
    [switch]$NoFlashAttn,
    [switch]$NoMmap
)

$root  = $PSScriptRoot
$exe   = Get-ChildItem -Path (Join-Path $root 'llama.cpp') -Filter 'llama-server.exe' -Recurse | Select-Object -First 1
$quant = (Get-Content (Join-Path $root 'quant.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $quant) { $quant = 'UD-Q3_K_XL' }

$model = Get-ChildItem -Path (Join-Path $root 'models') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*-00001-of-*.gguf' -and $_.FullName -like "*$quant*" } | Select-Object -First 1
if (-not $model) {
    $model = Get-ChildItem -Path (Join-Path $root 'models') -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-00001-of-*.gguf' } | Select-Object -First 1
}
if (-not $exe)   { Write-Host '[FAIL] llama-server.exe non trovato.' -ForegroundColor Red; exit 1 }
if (-not $model) { Write-Host "[FAIL] Nessun GGUF ('00001-of-') trovato in $(Join-Path $root 'models')." -ForegroundColor Red; exit 1 }

Write-Host "Modello: $($model.FullName)" -ForegroundColor Green
Write-Host "GPU Vulkan in uso; esperti MoE su CPU; tabella PLE letta da disco."
Write-Host "API:  http://127.0.0.1:$Port/v1/chat/completions`n" -ForegroundColor Cyan

$llamaArgs = @(
    '-m', $model.FullName,
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
if (-not $NoFlashAttn) { $llamaArgs += '-fa', 'on' }

& $exe @llamaArgs
exit $LASTEXITCODE
'@

$chatTpl = @'
#Requires -Version 5.1
# Chat interattiva (llama-cli) con gli stessi criteri di run-server.ps1.
param(
    [int]$Ctx       = 8192,
    [int]$Threads   = 16,
    [switch]$NoFlashAttn
)

$root  = $PSScriptRoot
$exe   = Get-ChildItem -Path (Join-Path $root 'llama.cpp') -Filter 'llama-cli.exe' -Recurse | Select-Object -First 1
$quant = (Get-Content (Join-Path $root 'quant.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $quant) { $quant = 'UD-Q3_K_XL' }

$model = Get-ChildItem -Path (Join-Path $root 'models') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*-00001-of-*.gguf' -and $_.FullName -like "*$quant*" } | Select-Object -First 1
if (-not $model) {
    $model = Get-ChildItem -Path (Join-Path $root 'models') -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-00001-of-*.gguf' } | Select-Object -First 1
}
if (-not $exe)   { Write-Host '[FAIL] llama-cli.exe non trovato.' -ForegroundColor Red; exit 1 }
if (-not $model) { Write-Host "[FAIL] Nessun GGUF ('00001-of-') trovato in $(Join-Path $root 'models')." -ForegroundColor Red; exit 1 }

$llamaArgs = @(
    '-m', $model.FullName,
    '-ngl', '999',
    '--cpu-moe',
    '-ot', 'per_layer_token_embd.*=CPU',
    '--jinja',
    '-c', [string]$Ctx,
    '-t', [string]$Threads,
    '-cnv'
)
if (-not $NoFlashAttn) { $llamaArgs += '-fa', 'on' }

& $exe @llamaArgs
exit $LASTEXITCODE
'@

Set-Content -Path (Join-Path $Root 'run-server.ps1') -Value $serverTpl -Encoding utf8
Set-Content -Path (Join-Path $Root 'run-chat.ps1')    -Value $chatTpl    -Encoding utf8

# ---------------------------------------------------------------------------
# 4. Riepilogo
# ---------------------------------------------------------------------------
Write-Host "`n============== FATTO ==============" -ForegroundColor Cyan
Write-Host "Contenuto di $Root :" -ForegroundColor Green
Get-ChildItem $Root | Select-Object Name, @{n='Size (GB)'; e={ if ($_.PSIsContainer) { '' } else { [math]::Round($_.Length/1GB, 2) } }} |
    Format-Table -AutoSize
Write-Host "Avvio del server (esperti MoE su CPU):" -ForegroundColor Green
Write-Host "    pwsh $Root\run-server.ps1"
Write-Host "    # oppure con meno VRAM/-ctx:  pwsh $Root\run-server.ps1 -Ctx 4096"
Write-Host "Chat interattiva:" -ForegroundColor Green
Write-Host "    pwsh $Root\run-chat.ps1"
Write-Host "`nPrimo avvio: controlla la riga '-ngl 999' e quanti layer finiscono su Vulkan."
Write-Host "Se esaurisci la VRAM bassa -Ctx. Se usi la 6700 XT (12GB) il Q2_K_XL resta piu comodo."