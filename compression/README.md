# Compression Accelerator — Real-Time KV-Cache Compression

## Purpose

Unlike attention and FFN/MoE weights, the KV cache is **generated at runtime**, one new (K, V) pair per token per layer, and grows for the length of the sequence. It cannot be compressed offline. To keep it inside DRAM/SRAM budget on the edge device, every newly produced KV tile has to be **compressed on the write path, in real time, at decode-token rate**, using the same Zstd-based KV-cache library used for the offline attention/FFN streams (so the format stays consistent and the decompression side — see below — can reuse the same decode core). On the read path (every attention step needs the full KV history), tiles are decompressed back out, which is effectively the `/decompression` pipeline pointed at the KV-cache stream instead of the weight streams.

This is the *dynamic* half of the codec. It is the harder half: it sits directly in the per-token critical path, so it cannot be hidden behind a long prefetch window the way static weight decompression can.

## Rough Pipeline Structure

### Write path (compress new KV entries)

```
Attention layer output (new K, V vectors for current token, per layer, per head)
        │
        ▼
 ┌───────────────────┐
 │  Tile Accumulator  │  Buffers incoming K/V vectors until a full compression tile is
 │                    │  formed (tile = fixed number of tokens × head-dim, matching the
 │                    │  granularity used by the KV-cache library offline)
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  Quantize          │  Per-channel (Key) / per-token (Value) quantization, matching the
 │  (K: per-channel,  │  asymmetric scheme used in the software KV-cache library, so the
 │   V: per-token)    │  quantization step is identical between offline dev/test and the
 │                    │  on-device runtime path
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  Match Finder      │  LZ77-style match search within the tile / a short sliding window
 │  (LZ stage,        │  — small window relative to the general-purpose accelerator since
 │   small window)    │  KV tiles are much smaller and more local than full weight tensors
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  FSE/tANS Table    │  Builds (or selects from a small precomputed set of) entropy
 │  Build + Encode    │  tables for the literal/sequence symbol distribution of this tile,
 │                    │  then encodes — this is the new block relative to the decompression
 │                    │  accelerator, since encoding wasn't needed for the static weight path
 └─────────┬──────────┘
           ▼
 ┌───────────────────┐
 │  Compressed Tile   │  Written back to DRAM in the same tile-wise Zstd KV-cache format
 │  Writeback + DMA   │  used by the offline pipeline
 └────────────────────┘
```

### Read path (decompress KV history for attention)

Reuses the decompression accelerator's Sequence Decoder + Entropy Decode Core + Dequant stages from `/decompression`, pointed at the KV-cache tile stream instead of the weight-tile stream, feeding the attention unit instead of the MAC array's weight input.

```
DRAM (compressed KV tiles) → Tile Fetch/DMA → Sequence Decoder → FSE/tANS Decode
                                              → Dequant (per-channel K / per-token V) → Attention unit
```

## Key Design Points to Work Out

- **Latency budget is per-token, not per-tile-fetch**: unlike the weight-decompression path, this cannot rely on a long prefetch window — the compress step for a new token's KV entry has to complete (or be well-pipelined) before the next token is due, so the match-finder window and FSE table-build cost need to be kept small and bounded, not maximized for compression ratio.
- **Tile accumulation vs. immediacy tradeoff**: compressing per-token would minimize latency exposure but gives poor compression ratio (too little context for the LZ/entropy stages); accumulating a small tile of tokens before compressing amortizes better but adds latency before the tile is safely in compressed form — needs to be tuned against the decode token rate target.
- **Shared FSE tables vs. per-tile tables**: building a fresh entropy table per tile is expensive at this rate; consider a small set of precomputed/adaptive tables (e.g. periodically refreshed from running statistics of K vs. V distributions) rather than a full table build per tile, trading a little compression ratio for a large latency win — this is the main open research question for this half of the project.
- **K vs. V asymmetry**: K and V have different statistical structure (channel-wise vs. token-wise outliers per the KIVI-style asymmetric quantization referenced in `references/README.md`), so the quantization step (and possibly the entropy table selection) should be parameterized separately for K and V rather than sharing one path.
- **Reuse of the older KV-cache compression library**: per the project brief, this accelerator should stay bit-compatible with the *specific* Zstd-based KV-cache library already used offline (not the general-purpose weight-compression library), so results are comparable to the existing offline benchmarking numbers.
- **Read/write path sharing**: since the read path reuses most of `/decompression`'s blocks, it's worth deciding early whether the write-path match finder and FSE encoder are separate hardware or a shared encode/decode core that time-multiplexes — similar to the encoder/decoder phase time-multiplexing already planned for Shrutam-2's entropy-decode/dequant/desparse pipeline.

## Interfaces

- **Upstream (write path)**: attention output (post Q·K^T / softmax·V stage), per layer, per head, per token.
- **Downstream (write path)**: DRAM, compressed KV-cache tile stream.
- **Upstream (read path)**: DRAM, compressed KV-cache tile stream.
- **Downstream (read path)**: attention unit (needs the full decompressed KV history for the current layer to compute attention scores).

## Open Items

- [ ] Decide tile accumulation size (tokens per compression tile) against target decode tokens/sec
- [ ] Decide adaptive vs. fixed FSE table strategy for the encode side
- [ ] Confirm bit-exact compatibility with the existing offline KV-cache Zstd library
- [ ] Decide whether encode (write) and decode (read) cores are separate or time-multiplexed shared hardware
- [ ] Characterize worst-case per-token latency vs. target token rate on Shrutam-2 / Sooktam
