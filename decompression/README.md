# Tile-wise Zstd Decompression Accelerator

Hardware pipeline for JIT decompression of quantized LLM weights/KV-cache/
FFN tensors, using 3 role-specific dictionaries and configurable tile size,
targeting Shrutam-2/Sooktam-class edge NPUs.

## Status: real, bit-exact single-tile FSE decode -- passing

`tb/tb_zstd_decomp_top.sv` now exercises GENUINE tANS/FSE entropy decode
(real variable bit-length codes, not a literal-passthrough placeholder)
plus a real LZ77 match reconstruction, checked byte-for-byte against
`model/compute_test_vectors.c`'s golden output:

```
[SCOREBOARD MATCH] Offset 0: 32'h05000500
...
[SCOREBOARD MATCH] Offset 11: 32'h22002200
[TB] PASS: Real FSE tile decoded and matched golden model!
```

This is driven by `tb/generated_stimulus.svh`, auto-generated fresh from
the golden C model (see `run_zstd_chia_loop.py` in the project root) --
so the table, compressed bytes, and expected output all come from one
place, not a hand-picked fixture.

An earlier control-flow-only smoke test (literal passthrough, 4 tiles,
no real entropy coding) previously passed and validated tile-loop
control flow / AXI burst sequencing / backpressure independent of the
entropy format; that test's logic is superseded by this one but the
underlying control-flow correctness it established still holds.

## Real bugs found and fixed getting here (worth knowing about)

- **AXI beat vs. compressed-FIFO-depth mismatch**: a 512-bit AXI beat
  (64 bytes) silently corrupts a compressed FIFO smaller than one beat --
  it wraps around and overwrites itself within a single write cycle, and
  the occupancy counter overflows back toward 0. Only shows up for tiles
  whose *compressed* FIFO is smaller than one AXI beat; production tiles
  (hundreds+ bytes) don't hit this at `AXI_DATA_WIDTH=512`. The current
  testbench sidesteps it by using a narrower bus for its small test tile
  -- if you add a genuinely tiny production tile size, either widen its
  `COMP_FIFO_DEPTH` or narrow the bus to match.
- **`lz_reconstruct.sv` copy-loop stale-address bug**: the match-copy
  path recomputed its read address unconditionally every cycle from the
  *pre-increment* write pointer, so on the cycle a byte both committed
  and the pointer advanced, it fetched using the stale address --
  silently repeating the first byte of every match instead of advancing
  through it. Fixed with an explicit, correctly-sequenced source pointer.
- **`axi_dma_if.sv` `done` semantics bug**: required every byte of a
  (padded) burst to be popped by the consumer before firing. A real
  entropy decoder legitimately stops pulling bytes once it's decoded all
  the symbols it needs -- fewer bytes than a conservatively-sized burst.
  `done` now means "the AXI fetch itself completed", which is what it
  should have meant all along; full pipeline drain is the scheduler's
  separate `pipe_tile_done` check.
- **iverilog toolchain limitations** (not RTL bugs, but cost real debug
  time): large (4096-entry) packed-struct arrays silently fail to write
  correctly for some indices in this iverilog version, and indexing a
  struct field through an array inside `$display` crashes the compiler
  outright. Worked around by parameterizing `tans_decoder`'s table down
  to the size a given test actually needs (`STATE_BITS` override) and by
  reading whole-struct values (no `.field` chaining through an array
  index) in testbench debug prints. Worth re-testing against a different
  Verilog toolchain (Verilator, a commercial simulator) before assuming
  the underlying RTL pattern itself is unsafe at full size.

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
  golden_model.c            desparse/dequant reference (real for those two
                             stages; entropy/LZ here are a DIFFERENT, older
                             toy scheme -- do not use as the entropy/LZ
                             golden reference, see fse_codec.c instead)
  fse_codec.c                REAL tANS/FSE encode+decode + LZ token format
                             (ESCAPE=256 symbol), self-verified round trip
  compute_test_vectors.c     generates the table/compressed-bytes/expected-
                             output vectors tb/generated_stimulus.svh is
                             built from
```

## Changing tile size / tile count

Every knob you asked for is a `parameter` on `zstd_decomp_top`:

```systemverilog
zstd_decomp_top #(
    .TILE_SIZE_BYTES (4096),
    .NUM_TILES       (64),
    .NUM_DOUBLE_BUFS (2),
    .DICT_DEPTH_BYTES(32768)
) u_decomp ( ... );
```

`num_tiles_this_run` (a runtime **input port**, not a parameter) lets you
run fewer than `NUM_TILES` tiles per invocation without resynthesizing.

## Running the testbench

```
iverilog -g2012 -Itb -o sim.out rtl/*.sv tb/tb_zstd_decomp_top.sv
vvp sim.out
```
`-Itb` is required so the ``` `include "generated_stimulus.svh" ``` inside
the testbench module resolves. (Tested with Icarus Verilog; `unique case`
and constant-select warnings from iverilog are tool limitations, not
functional issues -- both constructs are standard synthesizable
SystemVerilog. See the toolchain-limitations note above for two sharper
edges this project actually hit.)

To regenerate the stimulus from the golden model yourself (rather than
via the chia loop script):
```
gcc model/compute_test_vectors.c -o /tmp/gen && /tmp/gen
# then re-run write_stimulus_include() from run_zstd_chia_loop.py,
# or hand-port its output into tb/generated_stimulus.svh
```

## What's real vs. what's a documented skeleton

**Structurally real and verified:** top-level parameterization, tile
scheduler FSM (fetch -> wait-for-fetch -> wait-for-pipeline-drain -> swap
-> next, with a genuine per-tile address stride derived from
`TILE_SIZE_BYTES`), AXI DMA burst sequencing, FIFO occupancy accounting,
valid/ready backpressure through every stage, dictionary bank selection,
the double-buffer swap handshake, **and now real bit-exact tANS/FSE
entropy decode with real LZ77 match reconstruction** (see Status above)
for a single tile.

**Still a documented skeleton / known gaps:**
- `tans_decoder.sv`: single-stream only (real Zstd uses 2-4 interleaved
  FSE streams for throughput). The core table-driven decode algorithm and
  bit-reader are real and verified, not a placeholder.
- `lz_reconstruct.sv`: in-tile history matching is real and verified.
  Cross-tile **dictionary** matching has a known latent bug -- it reads
  `dict_rd_data` the same cycle it drives `dict_rd_addr`, one cycle too
  early for `dict_mem`'s registered read port. Needs a pipeline stage
  before a real dictionary-crossing match will work; not exercised by
  the current test (its one match stays within tile history).
- Only tested at single-tile scope (`NUM_TILES=1`) with the real FSE
  path -- the earlier 4-tile literal-passthrough test validated
  multi-tile looping, but that combination (multi-tile + real variable-
  length FSE) hasn't been run together yet. Per-tile metadata
  (`init_state`/`num_symbols_this_tile`) is currently a single static
  value per testbench run, not sourced per-tile from a metadata table --
  fine for this scope, a real gap for genuine multi-tile deployment.
- `desparse_unit.sv`: 2:4 group decode logic is implemented, but needs a
  real 2:4-sparse-encoded input stream to exercise (this testbench
  correctly bypasses it, since KV-cache-style dense tiles do too).
- `dequant_unit.sv`: NF4 LUT values are placeholders -- verify against
  your actual training-time NF4 quantile export before use.
- Double-buffered SRAM staging for the *decompressed* side isn't modeled;
  output streams straight to the consumer port. Add real staging if your
  consumer can't keep up cycle-by-cycle.

## Suggested next steps

1. Fix the dictionary-read timing bug in `lz_reconstruct.sv` (add a
   pipeline stage matching `dict_mem`'s 1-cycle read latency), then add a
   test case whose match actually crosses into the dictionary to verify it.
2. Extend `compute_test_vectors.c` / the chia loop to generate multiple
   tiles' worth of vectors, and test real FSE decode across a multi-tile
   run (not just single-tile).
3. Point `fse_codec.c` at real `zstd --ultra -22`-compressed data (or a
   real FSE table export) instead of its own self-consistent toy format,
   for actual Zstd-format compliance.
4. Once real Zstd-format vectors pass, benchmark decompression throughput
   (bytes/sec) vs. your target DRAM bandwidth at the tile size you'll
   actually use -- that ratio, not the compression ratio alone, is what
   determines whether this gives you a throughput win or just a footprint
   win (see the earlier discussion in this conversation).
