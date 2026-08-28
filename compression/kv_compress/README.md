# Real-Time KV-Cache Compressor

Hardware pipeline for compressing freshly generated K/V tiles during
autoregressive generation, before they're written into the memory
hierarchy: `(K_{l,t}, V_{l,t}) -> Tile -> Zstd_{D_KV} -> C_KV` (paper
Section III-F). This is the write-side counterpart to
`zstd_decomp_pipeline` -- weight and FFN tiles are compressed **offline**
in software, so only the KV path needs a hardware encoder at all.

## Status: compiles clean, NOT yet behaviorally debugged

Unlike `zstd_decomp_pipeline` (which went through several real,
iteratively-found-and-fixed bugs before it passed simulation),
`tb_kv_compress_top.sv` currently times out without reaching `done`. The
RTL elaborates without errors under `iverilog -g2012`, but that's as far
as verification has gone. Expect to find real bugs here the same way the
decompression side needed -- start by comparing intermediate state
(`freq[]`/`base_tbl[]` after the NORMALIZE/BASE phases, `result_bits[]`/
`result_nbbits[]` after BACKWARD) against `model/kv_encoder.c`'s printed
output for the *same* input tile. That C model's own round-trip
self-test passes (`gcc -DKV_ENCODER_SELFTEST kv_encoder.c -o kv_selftest
-lm && ./kv_selftest`), so it's the right oracle to debug the RTL against.

## Why this can't just stream tokens straight into the entropy coder

tANS/FSE encoding is a **backward pass**: the encoder needs to already
know the state that resulted from processing symbols *after* the current
one before it can compute what to emit for the current one (see
`model/kv_encoder.c`'s header for the full derivation -- it's the same
fact that makes decode a *forward* pass with a running state). There's no
way around this for a table-driven entropy coder; real Zstd has the exact
same property.

What this means practically: the whole tile's token sequence must be
buffered before entropy encoding can start. This is **not** actually a
real-time-breaking constraint for the KV-cache use case specifically --
the attention operation that will eventually read this tile back also
needs the whole tile written first, so buffering a tile before writing it
compressed is no worse than buffering it uncompressed. The added latency
is one backward pass over the token stream (roughly `TILE_SIZE_BYTES`
cycles, same cost class as the decoder's forward pass) plus match-finding
time -- see `RQ5` in the paper for where that latency needs to land
relative to compute slack.

## Layout

```
rtl/
  kv_compress_top.sv    top module -- stage wiring, real-time framing
  quant_pack.sv           fp32(placeholder: Q16.16 fixed-point in sim) -> INT8
  lz_match_finder.sv       hash-based greedy LZ77 match finder
  tans_encoder.sv           batch backward-pass tANS/FSE encoder (the novel part)
  axi_dma_if_wr.sv           AXI-512 write master
  dict_mem_kv.sv              single-bank D_KV dictionary SRAM
tb/
  tb_kv_compress_top.sv   testbench (compiles; doesn't pass yet -- see above)
model/
  kv_encoder.c              C golden model -- quantize -> LZ77 -> FSE encode,
                             with a verified round-trip self-test
  fse_codec.c                shared with zstd_decomp_pipeline (copied, not
                              symlinked, so this project stays self-contained)
```

## Pipeline stages and what's real vs. simplified

**quant_pack.sv**: INT8 only (KV is expected to want a lighter/faster
quantization than the static-weight AWQ-INT4 path, since KV accesses are
latency-sensitive -- Section X-E). The fp32-to-fixed-point arithmetic is
a **simulation-only placeholder** (plain Q16.16 fixed-point math, not a
real FPU) -- swap in your actual FPU or fixed-point reciprocal-multiply
core before this is anything but a functional stand-in. The testbench
drives `kv_data_in` as Q16.16 to match.

**lz_match_finder.sv**: hash-based, single-pass, direct-mapped (one
candidate position per hash bucket -- collisions can cause a real match
to be missed; a real implementation would want multi-way buckets).
Dictionary matching requires the host to pre-populate a hash table via
`dict_hash_wr_*`; there's no automatic re-indexing when D_KV's contents
change yet.

**tans_encoder.sv**: implements the same power-of-2 frequency
normalization as `fse_codec.c` (see that file's header for the exact
derivation and why it's always exact in one pass), then the real backward
encode algorithm. The NORMALIZE phase's max-symbol search is a simple
iterative scan (bounded by `remaining <= nbSymbols <= 257` iterations,
each scanning up to 257 candidates) -- correct but not fast; if this
phase's latency turns out to matter more than raw throughput, that's the
place to optimize first.

**axi_dma_if_wr.sv**: buffers the whole compressed tile before issuing
the AXI write burst, since (unlike the decompression read side) the
compressed length isn't known ahead of time.

**dict_mem_kv.sv**: single dictionary bank (D_KV only) -- this module
exists exclusively for the KV path, so unlike the decompressor there's no
dictionary *selection* logic needed.

## Suggested next steps

1. Debug `tb_kv_compress_top.sv` against `kv_encoder.c`'s printed
   intermediate state, the same iterative way `tb_zstd_decomp_top.sv` got
   debugged in `zstd_decomp_pipeline` -- compile, run, trace the first
   place RTL and C disagree, fix, repeat.
2. Once compression round-trips correctly in isolation, chain it into
   `zstd_decomp_pipeline`: encode a tile here, feed the resulting
   compressed bytes + table + init_state into `zstd_decomp_top`, and
   confirm the decompressed output matches the original quantized input.
   That end-to-end check is the real correctness bar for the KV path.
3. Wire `dict_hash_wr_*` up to whatever maintains D_KV's contents at
   runtime, and decide on a re-indexing policy (rebuild on every
   dictionary update? incremental?).
4. Replace `quant_pack.sv`'s placeholder fixed-point arithmetic with a
   real FPU or fixed-point core, and re-verify.
