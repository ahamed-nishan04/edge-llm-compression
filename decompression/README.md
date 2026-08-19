# Decompression Accelerator — Real-Time Weight Tile Reconstruction

## Purpose

Attention (Q/K/V/O) and FFN/MoE-expert weight tiles are compressed **offline** with tile-wise Zstd after SparseGPT pruning, AWQ 4-bit quantization, and QAT/QAFT recovery. On the edge device these tiles live in flash/DRAM in their compressed form; they are only ever expanded to full width **inside SRAM, just before a tile is consumed by the MAC array**. This block is the hardware path that does that expansion in real time, so decode latency is fully hidden behind compute and SRAM never has to hold more than one (or a small pipelined handful of) decompressed tile(s).

This is the *static* half of the codec (weights only — the dynamic KV-cache path lives in `/compression`, and is symmetric — see below).

## Rough Pipeline Structure

```
Flash / DRAM (compressed tile stream)
        │
        ▼
 ┌───────────────────┐
 │  Tile Fetch / DMA  │  AXI-style burst reads, tile-header parsing (size, codec params,
 │  + Tile Scheduler  │  target SRAM bank), double-buffered so fetch of tile N+1 overlaps
 └─────────┬──────────┘  decode + consumption of tile N
           ▼
 ┌───────────────────┐
 │  Sequence Decoder  │  Parses Zstd frame/block headers, separates the literals stream
 │  (LZ77 stage)      │  from the sequences (offset/match-length) stream, reconstructs
 │                    │  the raw byte stream via match-copy from the sliding window
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  Entropy Decode    │  FSE/tANS decode core for literals + sequence symbols (Huffman
 │  Core (FSE/tANS)   │  fallback path for literal-heavy tiles if the library selects it)
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  Dequant / Format  │  Unpacks AWQ 4-bit codes + per-group scale/zero-point back to the
 │  Reconstruction    │  compute array's native width (e.g. INT8-normalized for the MAC
 │                    │  array, per Shrutam-2), applies structured-sparsity mask reinsertion
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  Double-Buffered   │  Two (or more) SRAM banks per tile slot: one being written by the
 │  Output SRAM       │  decoder while the other feeds the MAC array — hides decode latency
 └─────────┬──────────┘
           ▼
      MAC Array (Shrutam-2 / Sooktam compute datapath)
```

## Key Design Points to Work Out

- **Tile granularity**: must be chosen jointly with the compression-ratio-vs-latency analysis in the main report — small enough that one tile's decode time fits comfortably under one MAC-array pass, large enough that per-tile metadata (Zstd frame header, FSE tables) doesn't dominate.
- **Fixed-throughput vs. bursty decode**: entropy decoding is inherently variable-rate (see Huff-LLM's "bubble cycle" problem, `references/README.md`). The decoder needs either (a) a small output FIFO that absorbs rate variation before the double-buffered SRAM stage, or (b) a decode core wide enough (multi-symbol/cycle FSE table lookup) that worst-case throughput still beats the MAC array's consumption rate.
- **Two consumers, two formats**: attention-tile and FFN/MoE-tile streams were compressed with separate library configurations (different literal alphabets / table sizes), so the entropy decode core either needs to be parameterizable per-stream or the design needs two lightweight instances sharing the same DMA/scheduler front end.
- **MoE routing interaction**: for the 8-expert SMEAR FFN, only a subset of experts are active per token/batch — the tile scheduler should prefetch/decompress only the tiles for routed experts, not the whole FFN weight set, to avoid wasting decode bandwidth.
- **Reuse from the prior general-purpose Zstd accelerator work**: the tANS decode core, AXI DMA block, and double-buffer scheduler design are being carried over and adapted (parameter widths, table sizes) rather than redesigned from scratch — only the dequant/reconstruction stage and MoE-aware scheduling are new for this project.

## Interfaces

- **Upstream**: flash/DRAM controller (compressed tile stream + per-tile metadata table produced by the offline compression pipeline).
- **Downstream**: MAC array input SRAM, in the compute array's native tile format (dimensions, quantization width) expected by Shrutam-2 / Sooktam.

## Open Items

- [ ] Finalize tile size sweep (SRAM budget vs. decode-latency-hidden-behind-compute)
- [ ] Decide FSE table storage strategy (per-tile embedded table vs. shared global table to save flash space)
- [ ] Define MoE-aware prefetch policy for expert tile selection
- [ ] Verify dequant stage matches the AWQ group size used during offline quantization
