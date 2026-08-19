# Edge-LLM Codec: A Compression-Aware Inference Pipeline for Deploying LLMs on Flash/DRAM/SRAM-Constrained Edge Devices

## 1. Motivation

Modern dense LLMs (7–8B+ parameters) cannot fit inside the flash, DRAM, and SRAM budgets of real edge silicon even after aggressive pruning and quantization. Sparsity and low-bit quantization alone typically get an 8B model from ~16 GB (BF16) down to ~5–6 GB — still far above what an edge NPU with tens of MB of on-chip SRAM and a few GB of DRAM can hold or stream at real-time token rates.

This project treats **compression as a first-class part of the inference datapath**, not just a storage optimization. The static weights are pruned, quantized, and then entropy-compressed offline; a **hardware decompression accelerator** reconstructs tiles of weights on the fly as they are streamed into the compute array, so the footprint in flash/DRAM stays at the compressed size while SRAM only ever holds one decompressed tile at a time. Because the KV cache is *not* static — it grows every decode step — it needs the mirror-image problem solved: a **hardware compression accelerator** that compresses freshly generated KV entries in real time before they are written back to DRAM, and decompresses them again on the read path during attention.

## 2. Software Pipeline (already completed)

```
Qwen3-8B (dense, BF16)
       │
       ▼
 SparseGPT one-shot pruning   (unstructured / semi-structured sparsity, layer-wise Hessian reconstruction)
       │
       ▼
 AWQ 4-bit weight quantization (activation-aware per-channel salient weight protection, group-wise scales)
       │
       ▼
 QAT / QAFT fine-tuning        (quantization-aware fine-tuning to recover accuracy lost to pruning + quant)
       │
       ▼
 Tile-wise Zstd compression, split across 3 independent streams:
   1. Attention weight tiles   (Q/K/V/O projections)
   2. FFN / MoE expert tiles   (gate + up + down projections)
   3. KV cache tiles           (dynamic, compressed at runtime — see below)
```

Tiling granularity (rather than whole-tensor or whole-model compression) is deliberate: it caps the SRAM working-set size to one tile, bounds decompression latency per tile so it can be hidden behind MAC-array compute, and lets the accelerator start consuming a tensor before the whole tensor has arrived from flash. The theoretical tradeoffs between model-wise, layer-wise, tensor-wise, and tile-wise compression granularity (compression ratio vs. random-access latency vs. metadata overhead) are analyzed separately in the project report.

## 3. Hardware Pipeline (this stage of the project)

Two complementary accelerators close the loop between the compressed representation and the compute array:

| | **Decompression accelerator** (`/decompression`) | **Compression accelerator** (`/compression`) |
|---|---|---|
| Operates on | Static weight tiles (attention, FFN/MoE) | Dynamic KV cache tiles |
| Direction | Flash/DRAM → SRAM → MAC array | Attention output → DRAM, and back |
| Timing | Prefetch-driven, can be pipelined ahead of compute | Must keep up with per-token decode latency |
| Codec | Tile-wise Zstd (FSE/tANS entropy stage + LZ77-style match stage) | Same KV-cache-specific Zstd library used in the original offline pipeline, run in reverse (encode) |
| Target integration | Shrutam-2 (Conformer encoder + Llama-style decoder, 8-expert SMEAR MoE) and Sooktam NPU projects | Same |

Both accelerators are designed to reuse a common decode-side building block (tANS/FSE decode core, sequence/match reconstruction, AXI-style DMA and double-buffered tile scheduler) so that the KV-cache path only needs an additional forward encode datapath (match finder + FSE table build/encode) rather than a second unrelated design.

See `compression/README.md` and `decompression/README.md` for the block-level architecture of each accelerator.

## 4. Repository Structure

```
edge-llm-codec/
├── README.md                  <- you are here
├── edge-llm-codec-overview.pptx   <- slide summary of the whole project
├── references/
│   └── README.md               <- annotated bibliography (pruning, quantization, entropy-coding hardware, KV-cache compression)
├── compression/
│   └── README.md               <- real-time KV-cache compression accelerator architecture
└── decompression/
    └── README.md               <- real-time weight-tile decompression accelerator architecture
```

## 5. Status

- [x] Dense baseline established (Qwen3-8B)
- [x] SparseGPT pruning
- [x] AWQ 4-bit quantization
- [x] QAT / QAFT recovery fine-tuning
- [x] Offline tile-wise Zstd compression (3 streams: attention, FFN/MoE, KV cache)
- [ ] Decompression accelerator RTL (weights, static path)
- [ ] Compression accelerator RTL (KV cache, dynamic path)
- [ ] End-to-end integration with Shrutam-2 / Sooktam datapath
- [ ] Real-time throughput / latency characterization vs. software baseline

## 6. Target Platforms

- **Shrutam-2**: Conformer-based encoder + Llama-architecture decoder with an 8-expert SMEAR mixture-of-experts FFN, structured (2:4) sparsity support, INT8-normalized mixed-precision MAC arrays.
- **Sooktam**: companion NPU project sharing the same compressed-weight streaming interface.
# edge-llm-compression
