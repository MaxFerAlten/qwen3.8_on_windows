# Qwen3.8-Flash-Next on llama.cpp (Vulkan + CPU MoE, Windows)

Run the **[Qwen3.8-Flash-Next](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)** 68.8B model on **Windows** with a **Vulkan** GPU (AMD / NVIDIA / Intel Arc) and the **Mixture-of-Experts on CPU**, using official precompiled **llama.cpp** binaries.

No CUDA, no ROCm, no compilation, no Python.

> **Why this exists** — the original [flash-next-8gb](https://github.com/lna-lab/flash-next-8gb) project (ExLlamaV3) is NVIDIA **CUDA-only** and does not run on AMD GPUs. Official llama.cpp ships Windows Vulkan builds that work on any GPU vendor, and its `--cpu-moe` flag lets you run the expert layers **on CPU/RAM** — the same hybrid trick that makes the model fit on a 8–16 GB VRAM card. This repo scripts that setup end-to-end.

---

## 1. How it works

The GGUF is split across **three memory zones** at inference time:

| Component | Size ~ | Where | Mechanism |
|---|---|---|---|
| Per-layer tensors (attention, norms, router, shared expert, delta-net) | 5–8 GB | **VRAM** | `-ngl 999` (Vulkan) |
| Mixture-of-Experts layers (the bulk of the model) | ~60–70 GB on disk | **RAM** | `--cpu-moe` + memory-mapped GGUF |
| N-gram table `per_layer_token_embd` (PLE) | ~9 GB | **Disk → RAM on demand** | `-ot per_layer_token_embd.*=CPU` + mmap |

Key facts about the setup:

- **MMap, not full load**: the model file is memory-mapped, so llama.cpp never needs all ~84 GB resident. The OS pages the touched tensors from the NVMe on demand and evicts them when RAM runs short.
- **PLE stays on disk**: the n-gram table is pinned to a CPU buffer while mmap stays enabled, so its ~9 GB is only read when actually needed. **Do not use `--no-mmap` / `--mlock` / `-lm none`** — that would defeat this and push RAM usage up with no benefit.
- **GPU handoff**: with hybrid CPU+GPU inference, the default batch sizes (`-b 2048 -ub 512`) are tuned for GPU-only runs and tend to be too small. The launchers use `-b 4096 -ub 1024`.
- **Flash Attention** is enabled (`-fa on`) when the Vulkan backend supports it.

Flags used by every launcher:

```
-m <model> -ngl 999 --cpu-moe -ot per_layer_token_embd.*=CPU --jinja
-c <ctx> -t <threads> --host 127.0.0.1 --port <port> -b 4096 -ub 1024 -fa on
```

All flags were verified against the shipped binary (`llama-server --help`).

---

## 2. Requirements

- **Windows 10 1803+ / Windows 11** (PowerShell 5.1 or 7, both supported)
- **curl.exe** (bundled with Windows 10 1803+)
- **GPU with Vulkan 1.1+**: tested on AMD Radeon RX 6700 XT (12 GB), works on NVIDIA and Intel Arc as well
- **RAM** — see the sizing table below
- **Free disk**: ~90 GB for the default quant (`Q3_K_XL`), ~80 GB for `Q2_K_XL`

Reference machine used during development:

| Part | Spec |
|---|---|
| CPU | i7-13700KF 16C/24T (AVX2, no AVX-512) |
| RAM | 64 GB DDR5-4800 (2×32) |
| GPU | AMD Radeon RX 6700 XT 12 GB (Vulkan) |
| Disk | 2 TB NVMe (D:) |
| OS | Windows 11 Pro |

---

## 3. Quick start

Open a terminal (PowerShell; optionally `Set-ExecutionPolicy -Scope Process Bypass`) and run:

```powershell
git clone <this-repo>
cd <this-repo>\tools\flash-next-llamacpp

.\srun.ps1
```

`srun.ps1` will:

1. **Ask for the destination folder** (absolute path). Default: `FlashNext` inside the folder where you launched the script — just press Enter to accept, or type a new path.
2. Run **setup.ps1**: find the newest llama.cpp *win-vulkan-x64* release on GitHub, download it, then download the model GGUF shards from HuggingFace (`UD-Q3_K_XL`, ~84 GB) with **resumable downloads and size verification**.
3. Run **runllama.ps1**: start `llama-server` in the background, wait for the `/health` endpoint, open the browser on the built-in Web UI, and stay in the foreground until you press **Ctrl+C** (which also stops the server).

First startup takes a while (loading ~84 GB of weights); you should see a line like `llama_model_load: ...` and the Vulkan device selection. The server is ready when the browser opens.

> **⚠️ first-run note** — the model is streamed **lazily from disk**: pages of the expert weights are pulled into RAM only when the first prompt touches them. Because of this, the **very first question can take a long time** (up to several minutes while the NVMe feeds ~40+ GB into the page cache). This is **normal** — don't stop the server, just wait. Once the expert pages are warm in RAM, **subsequent messages are much faster**. The same applies every time you restart from cold: the first prompt is the slow one.

---

## 4. Quantization options

Model repo: [`unsloth/Qwen3.8-Flash-Next-GGUF`](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF)

| Quant (`-Quant`) | ~Disk size | Expert working set ~ | Recommended RAM |
|---|---|---|---|
| **`UD-Q2_K_XL`** | 73 GB | 27–30 GB | **32 GB** (fits), 24 GB very tight |
| **`UD-Q3_K_XL`** *(default)* | 84 GB | 39–44 GB | 48–64 GB |
| `UD-Q4_K_XL` | 104 GB | 45+ GB | 64 GB+, tight |
| `UD-IQ4_XS` | 87 GB | ~40 GB | 48–64 GB |

VRAM usage is roughly the same for every quant (5–8 GB, per-layer tensors only).

Select a quant either at the prompt time or explicitly:

```powershell
.\srun.ps1 -Quant UD-Q2_K_XL
```

> **Running with less RAM**: it won't crash — the OS simply evicts model pages from RAM and re-reads them from the NVMe when needed ("thrashing"). The practical floor is ~24 GB of RAM with `UD-Q2_K_XL`.

---

## 5. Scripts reference

All scripts live in the same folder and must stay together. Paths are forwarded via `-Root` throughout.

### `srun.ps1` — everything in one go

```
.\srun.ps1                      # prompt for path -> setup -> launch
.\srun.ps1 -Root D:\FlashNext   # no prompt
.\srun.ps1 -Quant UD-Q2_K_XL    # different quantization
.\srun.ps1 -SkipSetup           # relaunch server only, no setup
.\srun.ps1 -Ctx 4096            # lower context (less RAM/VRAM)
```

| Param | Default | Meaning |
|---|---|---|
| `-Root` | prompt | Destination folder (absolute). Default prompt: `<cwd>\FlashNext` |
| `-Quant` | `UD-Q3_K_XL` | Quantization to download |
| `-SkipSetup` | off | Skip setup, go straight to `runllama.ps1` |
| `-SkipModel` | off | Forwarded to setup: binaries only |
| `-SkipLlama` | off | Forwarded to setup: model files only |
| `-Port` | `8080` | HTTP port (forwarded to runllama) |
| `-Ctx` | `8192` | Context size (forwarded) |
| `-Threads` | `16` | CPU threads (forwarded) |
| `-HealthTimeout` | `180` | Max seconds waiting for readiness (forwarded) |
| `-NoFlashAttn` | off | Disable Flash Attention (forwarded) |

### `setup.ps1` — download & prepare everything

- Resolves the **newest official build** with a `llama-*-bin-win-vulkan-x64.zip` asset. It scans the release history because the GitHub `latest` release (`v0.4.1`) ships **no binaries** — only rolling daily builds like `b11043`.
- Downloads the GGUF **shards** from HuggingFace (`curl.exe -L -C -`, retry on failure) and verifies each file size against the HuggingFace API. Interrupted runs **resume** — just re-run.
- Generates `run-server.ps1` and `run-chat.ps1` inside the destination folder.
- Checks free disk space and warns if below ~95 GB.

```
.\setup.ps1                     # everything into D:\FlashNext
.\setup.ps1 -Root D:\FlashNext -Quant UD-Q2_K_XL
.\setup.ps1 -SkipModel          # llama.cpp only
.\setup.ps1 -SkipLlama          # model files only
```

### `runllama.ps1` — start / stop the server

Starts `llama-server` in the background (logs in `<Root>\logs\server.log` and `server.err.log`), polls `GET /health`, opens the Web UI in your browser, then waits for Ctrl+C to stop the server. If a server is already answering on the port, it only reopens the browser.

### Generated launchers (inside the destination folder)

Created by `setup.ps1` at runtime:

| File | Purpose |
|---|---|
| `<Root>\run-server.ps1` | Foreground `llama-server` (API). Params: `-Port -Ctx -Threads -NoFlashAttn` |
| `<Root>\run-chat.ps1` | Foreground interactive chat (`llama-cli -cnv`) with the same hybrid flags |
| `<Root>\quant.txt` | Which quantization was downloaded |
| `<Root>\logs\` | `server.log` / `server.err.log` |

---

## 6. Using the server (OpenAI-compatible API)

Once running:

- **Web UI**: `http://127.0.0.1:8080/`
- **API**: `http://127.0.0.1:8080/v1/chat/completions` — drop-in OpenAI-compatible endpoint

```powershell
curl.exe http://127.0.0.1:8080/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{\"model\":\"Qwen3.8-Flash-Next\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}],\"stream\":true}'
```

You can point `Open WebUI`, `SillyTavern`, `LM Studio`-style clients, or any OpenAI SDK at this URL.

---

## 7. What you get after setup

```
<Root>\                       # default D:\FlashNext
├── llama.cpp\                # precompiled Vulkan build (llama-server.exe, llama-cli.exe, ...)
├── llama-b11043-bin-win-vulkan-x64.zip   # downloaded build (can be deleted, ~30 MB)
├── models\
│   └── UD-Q3_K_XL\
│       ├── Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf   # metadata shard
│       ├── ...-00002-of-00003.gguf                             # weights (auto-loaded)
│       └── ...-00003-of-00003.gguf
├── quant.txt                  # selected quant
├── run-server.ps1 / run-chat.ps1
└── logs\
```

Only the **first shard** (`*-00001-of-*.gguf`) is passed to llama.cpp; the others are auto-loaded from the same folder.

---

## 8. Measured memory usage (RX 6700 XT, 64 GB RAM)

Taken from a running `UD-Q3_K_XL` session:

| Metric | Value |
|---|---|
| RAM total / used / free | 63.8 / 56.9 / 6.9 GB |
| `llama-server` resident (Working Set) | ~44 GB (experts touched so far) |
| `llama-server` private | 8 GB |
| `llama-server` virtual (mmap) | ~352 GB |
| VRAM dedicated usage | ~7.7 GB / 12 GB |
| VRAM shared (from RAM) | ~1 GB |
| VRAM total committed | ~8.8 GB |

This validates the design: per-layer tensors live on the GPU, expert weights page in and out of RAM, and the PLE table stays largely on disk.

---

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `#requires` PowerShell 7 error | You're on Windows PowerShell 5.1 — that's fine: all scripts support 5.1. Or install [pwsh](https://github.com/PowerShell/PowerShell). |
| Download interrupted / size mismatch | Just re-run: downloads resume with `curl -C -` and already-complete files are skipped. |
| Out of VRAM | Lower context: `.\srun.ps1 -Ctx 4096` or `-NoFlashAttn`. |
| Out of RAM / heavy swapping | Use a lighter quant: `.\srun.ps1 -Quant UD-Q2_K_XL`. |
| Vulkan errors with Flash Attention | `.\srun.ps1 -NoFlashAttn`. |
| Server won't become ready | Check `<Root>\logs\server.err.log` (dumped automatically). |
| Wrong GPU selected | Pass `-devid` manually via the generated `run-server.ps1` (needs a manual edit). |
| I deleted the model shards | Re-run `setup.ps1` — it downloads only what's missing. |

### Environment / PSP notes

- All scripts force **TLS 1.2** on Windows PowerShell 5.1 for the GitHub/HuggingFace APIs.
- Execution policy: `powershell -ExecutionPolicy Bypass -File srun.ps1` if restricted.
- llama.cpp builds are fetched dynamically — the exact tag (`b11043`) may differ over time; the script always picks the newest available Vulkan x64 build.

---

## 10. Project layout / publish hints

```
tools/flash-next-llamacpp/
├── README.md
├── srun.ps1        # entry point
├── setup.ps1       # download & prepare
└── runllama.ps1    # start/stop server
```

The three scripts are self-contained (no dependencies besides the OS); `srun.ps1` and `runllama.ps1` auto-invoke `setup.ps1` from their own folder, so the tree above can be published as-is or copied into a GitHub repo. The destination `<Root>` folder is entirely separate.

---

## 11. Attribution & licensing

- **Model**: [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) by Alibaba / Qwen — [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)
- **GGUF conversions**: [unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF) — Apache-2.0
- **llama.cpp**: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) — [MIT](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE), precompiled Windows Vulkan binaries from the official releases
- **Original project inspiration**: [lna-lab/flash-next-8gb](https://github.com/lna-lab/flash-next-8gb) (CUDA/ExLlamaV3-only)

The scripts in this repo are provided as-is; check each upstream project's license before redistribution.