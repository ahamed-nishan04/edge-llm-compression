# Tile-wise Zstd Decompression Accelerator

Hardware pipeline for run time decompression of quantized LLM weights/KV-cache/
FFN tensors, using 3 role-specific dictionaries and configurable tile size,
targeting Shrutam-2/Sooktam-class edge NPUs.

## Status: simulation-passing structural skeleton

`tb/tb_zstd_decomp_top.sv` passes end-to-end: all 4 test tiles complete
through DMA fetch -> tANS decode -> LZ reconstruct -> desparse -> dequant
-> output, with correct tile-loop control flow, AXI burst sequencing
across repeated tiles, backpressure through all 5 stages, and the
scheduler correctly gating each new tile's fetch on the *previous* tile's
full pipeline drain (not just its DMA fetch completing).

```
[TB] PASS: completed 4/4 tiles
```

This validates **wiring and control flow** for arbitrary `TILE_SIZE_BYTES`
/ `NUM_TILES` parameter choices. It does **not** yet validate bit-exact
Zstd/tANS decode against a real compressed stream -- see "What's real vs.
what's a documented skeleton" below.

## Layout

```
rtl/
  zstd_decomp_top.sv    top module -- all tunable parameters live here
  tile_scheduler.sv     tile loop FSM, double-buffer handshake, addressing
  axi_dma_if.sv          AXI-512 read master + compressed-byte FIFO
  tans_decoder.sv         tANS/FSE entropy decode front-end
  lz_reconstruct.sv       LZ77 match reconstruction (history + dictionary)
  desparse_unit.sv        2:4 structured-sparsity expansion (bypassable)
  dequant_unit.sv          INT8 / NF4 / AWQ-INT4 dequantization
  dict_mem.sv               3-bank dictionary memory (weights/KV/FFN)
tb/
  tb_zstd_decomp_top.sv   testbench + behavioral AXI memory model
model/
  golden_model.c            C reference (literal-passthrough + LZ + desparse
                             + dequant), compiles and runs standalone
```

## Changing tile size / tile count

Every knob is a `parameter` on `zstd_decomp_top`:

```systemverilog
zstd_decomp_top #(
    .TILE_SIZE_BYTES (4096),   // decompressed bytes per tile
    .NUM_TILES       (64),     // max tiles this instance can loop over
    .NUM_DOUBLE_BUFS (2),      // buffering depth for fetch/decode overlap
    .DICT_DEPTH_BYTES(32768)   // per-dictionary size (weights/KV/FFN)
) u_decomp ( ... );
```

`num_tiles_this_run` (a runtime **input port**, not a parameter) lets you
run fewer than `NUM_TILES` tiles per invocation without resynthesizing.

## Running the testbench

```
iverilog -g2012 -o sim.out rtl/*.sv tb/tb_zstd_decomp_top.sv
vvp sim.out
```
(tested with Icarus Verilog; `unique case` and constant-select warnings
from iverilog are tool limitations, not functional issues -- both
constructs are standard synthesizable SystemVerilog.)

## What's real vs. what's a documented skeleton

**Structurally real and verified:** top-level parameterization, tile
scheduler FSM (fetch -> wait-for-fetch -> wait-for-pipeline-drain -> swap
-> next, with a genuine per-tile address stride derived from
`TILE_SIZE_BYTES`), AXI-512 DMA burst sequencing, FIFO occupancy
accounting, valid/ready backpressure through every stage, dictionary bank
selection, and the double-buffer swap handshake.

**Documented skeleton, needs real implementation before tape-out /
real-data testing:**
- `tans_decoder.sv`: single-stream only (real Zstd uses 2-4 interleaved
  FSE streams for throughput); bit-reader shifts 1 bit/cycle rather than
  a real byte-aligned/bit-packed reader; LZ-token vs. literal
  classification and the offset/length sub-decode are stubbed
  (`out_is_lz_token` always 0 currently).
- `lz_reconstruct.sv`: match-copy path is implemented (history + dictionary
  addressing) but only exercised by literal symbols in the current test,
  since the entropy stage doesn't yet emit real LZ tokens.
- `desparse_unit.sv`: 2:4 group decode logic is implemented, but needs a
  real 2:4-sparse-encoded input stream to exercise (this testbench
  correctly bypasses it, since KV-cache-style dense tiles do too).
- `dequant_unit.sv`: NF4 LUT values are placeholders -- verify against
  your actual training-time NF4 quantile export before use.
- Double-buffered SRAM staging for the *decompressed* side isn't modeled;
  output streams straight to the consumer port. Add real staging if your
  consumer can't keep up cycle-by-cycle.

## Suggested next steps

1. Point `golden_model.c` at real `zstd --ultra -22`-compressed tiles (or
   a real FSE table export) and extend it to bit-exact tANS decode.
2. Rewrite `tans_decoder.sv`'s bit-reader against that same bit-packing
   convention, and wire real LZ-token decode into `out_is_lz_token`.
3. Extend the testbench with a scoreboard: `$readmemh` golden-model output,
   compare against `out_data` per tile.
4. Once (1)-(3) pass, benchmark decompression throughput (bytes/sec) vs.
   your target DRAM bandwidth at the tile size you'll actually use --
   that ratio, not the compression ratio alone, is what determines
   whether this gives you a throughput win or just a footprint win (see
   the earlier discussion in this conversation).
