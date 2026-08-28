# Real-Time KV-Cache Compressor

Hardware pipeline for compressing freshly generated K/V tiles during
autoregressive generation, before they're written into the memory
hierarchy: `(K_{l,t}, V_{l,t}) -> Tile -> Zstd_{D_KV} -> C_KV` (paper
Section III-F). This is the write-side counterpart to
`zstd_decomp_pipeline` -- weight and FFN tiles are compressed **offline**
in software, so only the KV path needs a hardware encoder at all.

## Status: passing, bit-exact against the golden model

```
[TB] quant  : 16/16 bytes checked, 0 errors
[TB] tokens : 14/14 tokens checked, 0 errors
[TB] comp   : 7/7 bytes checked, 0 errors
[TB] init_state: expected 4 got 4
[TB] compressed_bytes: expected 7 got 7
==================================================
[TB] PASS: KV tile compressed bit-exactly vs golden model!
==================================================
```

Reproduce:

```
python3 gen_kv_stimulus.py
iverilog -g2012 -Itb -o sim.out rtl/*.sv tb/tb_kv_compress_top.sv
vvp sim.out
```

`gen_kv_stimulus.py` is not optional; the testbench `` `include ``s what it
produces, so nothing compiles without it.

## Bugs found and fixed (six total, across the whole debugging arc)

- **`lz_match_finder.sv`: `tile_len_q` was one bit too narrow.**
  Declared `[TILE_ADDR_WIDTH-1:0]`, but a full tile length is
  `TILE_SIZE_BYTES`, which needs `TILE_ADDR_WIDTH+1` bits. At a 16-byte
  tile, `in_offset + 1` = 16 wrapped to 0 in a 4-bit register, making
  `scan_ptr + 1 >= tile_len_q` trivially true, so the FSM jumped straight
  to `S_DONE` after emitting exactly one token. Widened to
  `[TILE_ADDR_WIDTH:0]`.

- **`tb_kv_compress_top.sv`: stimulus driven via blocking assignment
  timed to change in the same simulation instant as the posedge that
  captures it.** This was previously (wrongly) diagnosed as an RTL bug
  in `quant_pack.sv`, because the symptom -- output stream offset by one
  beat, with a spurious leading `0x00` -- reproduced under two different
  handshake styles the project tried at the time. Both styles shared the
  same underlying flaw. The driver set `kv_data_in`/`kv_data_valid`
  immediately after the previous iteration's `@(posedge clk)` returned,
  racing `quant_pack`'s division-chain settling (`in_valid`, a simple
  passthrough, settles in one simulation delta; `q_clamped`, which goes
  through `scale_fixed -> div_result -> scaled_int -> q_clamped`, needs
  a second delta) -- so the capturing `always_ff` could see the new,
  already-settled `in_valid=1` while still seeing the stale, pre-settled
  `q_clamped`. The same race bit the *trailing* edge too: clearing
  `kv_data_valid` immediately after the loop's last iteration raced that
  same edge's own capture of the final beat. Fixed by driving every
  stimulus change on the negedge, a full half period from the posedge
  that consumes it. `quant_pack.sv` itself needed no RTL change.

- **`tans_encoder.sv`, `S_BASE_SCAN`: `base_tbl[]` built in the wrong
  symbol order.** The golden model's `fse_build_table()` (`fse_codec.c`)
  assigns `base[]` while walking symbols in *descending raw count*
  order (ties broken by ascending value) -- the same order
  `build_freq_table()` sorted them into for frequency assignment. The
  RTL instead built `base_tbl[]` in a separate pass over ascending
  *symbol value*, which only coincides with the golden order when no
  tie-breaking or count-based reordering occurred -- true for at most a
  couple of symbols on any real tile. Verified numerically before
  fixing: 6 of 12 symbols had the wrong `base_tbl` entry on the test
  tile. Fixed by folding `base_tbl` construction into the same
  descending-count extraction loop that already determines freq=2
  assignment (`S_NORM_FIND_MAX`/`S_NORM_MARK`), removing the separate
  `S_BASE_SCAN` phase (states left in place, now unreachable, to keep
  the diff minimal).

- **`tans_encoder.sv`: the tile's first-ever token was never counted.**
  Two separate `always_ff` blocks wrote `raw_count[]` on the same edge
  whenever `st==S_IDLE`: one reset every counter every idle cycle, the
  other tallied the incoming token. `in_ready` is also high during
  `S_IDLE` (so the first token of a tile can be accepted without wasting
  a cycle) -- so on that one specific cycle, both blocks wrote the same
  array element, and the reset always won, silently discarding whichever
  symbol happened to arrive first. `nbSymbols_q` came out one short
  every run. Fixed by only resetting on `S_IDLE` when *not* also
  accepting a token that cycle (`if (!(in_valid && in_ready))`); prior
  idle cycles, while waiting for the host to start feeding data, already
  clear everything before the real first token arrives.

- **`tans_encoder.sv`, `S_SER_STEP`: runaway re-processing of the last
  token.** The exit condition required `out_bits_in_shreg==0`, but the
  leftover-flush branch (for a tile whose total bit count doesn't land
  on a byte boundary) never actually cleared it. Since `ser_i` also
  never advances past its terminal value, the FSM could never satisfy
  its own exit check, stayed in `S_SER_STEP`, and kept re-executing --
  re-merging the last token's bits into the shift register again on
  every subsequent cycle. Observed as 3 extra garbage bytes past the
  correct first 7. Fixed with an explicit `ser_done` latch, set once the
  last token's byte(s) are queued, gating the merge logic so it can only
  fire once and letting the FSM exit as soon as nothing is still waiting
  on backpressure -- not on a bit-count check the same step had already
  resolved.

- **`tans_encoder.sv`, `S_SER_STEP`: separately, a missing final byte.**
  Fixing the above revealed a second, distinct gap in the same region:
  the last-token handling only ever checked for a leftover-needs-padding
  byte when `merged_cnt<8`. If `merged_cnt>=8` on the last token (one
  full byte flushes this same cycle) *and* `merged_cnt-8` is also
  nonzero, there's a second, separate trailing byte still owed --
  `fse_codec.c`'s `BitWriter` rounds up to `(bitPos+7)/8` bytes
  regardless of what already flushed cleanly. A single `out_byte`
  register can't emit two bytes in one cycle, so the original code
  silently dropped the second one outright. The test tile hits exactly
  this case: RTL emitted 6 of the golden 7 bytes, byte-exact, missing
  only the trailing all-zero pad byte. Fixed with an explicit extra
  cycle (`final_flush_pending`) that flushes `out_shreg` (already
  correctly holding the leftover bits from the normal branch's own
  assignment) as its own padded final byte, one cycle after the first.

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
gen_kv_stimulus.py      builds tb/generated_kv_stimulus.svh from the C model
run_kv_chia_loop.py     LLM iteration loop over the RTL (see its own notes)
rtl/
  kv_compress_top.sv    top module -- stage wiring (no control FSM yet)
  quant_pack.sv           fp32(placeholder: Q16.16 fixed-point) -> INT8
  lz_match_finder.sv       hash-based greedy LZ77 match finder
  tans_encoder.sv           batch backward-pass tANS/FSE encoder -- PASSING
  axi_dma_if_wr.sv           AXI write master
  dict_mem_kv.sv              single-bank D_KV dictionary SRAM
tb/
  tb_kv_compress_top.sv       scoreboarded testbench
  generated_kv_stimulus.svh   AUTO-GENERATED -- do not hand-edit
model/
  kv_encoder.c              C golden model -- quantize -> LZ77 -> FSE encode.
                             Two build modes: -DKV_ENCODER_SELFTEST runs a
                             round-trip check, -DKV_GEN_VECTORS emits the
                             machine-parseable vectors gen_kv_stimulus.py
                             consumes.
  fse_codec.c                shared with zstd_decomp_pipeline (copied, not
                              symlinked, so this project stays self-contained)
```

## Generating the stimulus

```
python3 gen_kv_stimulus.py
```

That runs two gates before generating anything -- `fse_codec.c`'s entropy
round trip and `kv_encoder.c`'s full-pipeline round trip -- so a broken
oracle is caught before it can produce misleading vectors. It then emits:

| identifier | meaning |
|---|---|
| `GEN_RAW_VALS[]`, `GEN_NUM_RAW` | input tile (integers; tb drives them `<<< 16` as Q16.16) |
| `GEN_QUANT_BYTES[]` | expected `quant_pack` output |
| `GEN_TOKENS[]` | expected `lz_match_finder` output (9-bit, 256 = ESCAPE) |
| `GEN_COMP_BYTES[]`, `GEN_INIT_STATE` | expected `tans_encoder` output |
| `GEN_QUANT_SCALE_Q88`, `GEN_QUANT_ZERO` | quantizer settings, so tb and model can't drift |

To change the test tile, edit `raw[]` in **both** `main()` bodies at the
bottom of `kv_encoder.c` (the self-test and the vector generator use the
same tile deliberately) and re-run.

## Why the scoreboard checks intermediates

The old testbench printed `compressed_bytes` and `init_state` and told you
to eyeball them against the C model. That's not a test -- and "8 bytes
instead of 7" tells you nothing about *which* stage is wrong.

Checking `quant_pack`, `lz_match_finder`, and `tans_encoder` outputs
separately turns a failure into a localised one, and is exactly what made
the six bugs above tractable to find: each one showed up as a specific,
localized mismatch (a byte offset, a token count, a table entry) rather
than just "wrong final answer."

## Pipeline stages and what's real vs. simplified

**quant_pack.sv**: INT8 only (KV wants a lighter/faster quantization than
the static-weight AWQ-INT4 path, since KV accesses are latency-sensitive
-- Section X-E). The fp32-to-fixed-point arithmetic is a
**simulation-only placeholder** (plain Q16.16 fixed-point math, not a real
FPU) -- swap in your actual FPU or fixed-point reciprocal-multiply core
before this is anything but a functional stand-in. The testbench drives
`kv_data_in` as Q16.16 to match. Passing bit-exact.

**lz_match_finder.sv**: hash-based, single-pass, direct-mapped (one
candidate position per hash bucket -- collisions can cause a real match to
be missed; a real implementation would want multi-way buckets). Note this
means the RTL and the C model can legitimately disagree on *which* match
they find, because `kv_encoder.c` does an exhaustive O(n^2) search. They
agree on the current test tile; on a tile where a hash collision hides a
match they will not, and that is not a bug in either. If you change the
test vector and see token mismatches, check this before assuming RTL
fault. Dictionary matching requires the host to pre-populate a hash table
via `dict_hash_wr_*`; there's no automatic re-indexing when D_KV's
contents change yet.

**tans_encoder.sv**: implements the same power-of-2 frequency
normalization as `fse_codec.c` (see that file's header for the exact
derivation and why it's always exact in one pass), then the real backward
encode algorithm. Now verified bit-exact end to end -- entropy table
construction, backward pass, and serialization all match the golden model
on the test tile. The NORMALIZE phase's max-symbol search is a simple
iterative scan (bounded by `nbSymbols <= 257` iterations, each scanning up
to 257 candidates) -- correct but not fast; if this phase's latency turns
out to matter more than raw throughput, that's the place to optimize
first.

**axi_dma_if_wr.sv**: buffers the whole compressed tile before issuing
the AXI write burst, since (unlike the decompression read side) the
compressed length isn't known ahead of time. Not independently stressed
beyond what the single-tile pass exercises.

**dict_mem_kv.sv**: single dictionary bank (D_KV only) -- this module
exists exclusively for the KV path, so unlike the decompressor there's no
dictionary *selection* logic needed. The testbench ties `dict_rd_data` to
zero and the golden model runs with `dictLen=0`, so dictionary matching is
completely unexercised on both sides.

## Toolchain notes (Icarus Verilog 12.0)

Same constraints as `zstd_decomp_pipeline`; both are worth re-testing
under Verilator.

- **Unpacked arrays cannot be `localparam`**, and array declaration
  initializers are unsupported. `generated_kv_stimulus.svh` therefore
  emits plain declarations plus element-wise `initial` fills. iverilog
  runs `initial` blocks in source order and the `` `include `` sits at the
  top of the tb module, so the fills land before anything reads them.
  **Keep the include first.**
- **`NUM_TILES=1` does not elaborate.** `$clog2(1)` is 0, so
  `[$clog2(NUM_TILES)-1:0]` becomes `[-1:0]` and zero-repeat
  concatenations get rejected. The testbench uses `NUM_TILES=2` and drives
  a single tile. Proper fix is a floored width localparam,
  `localparam int TID_W = (NUM_TILES <= 1) ? 1 : $clog2(NUM_TILES);`.
- **Multiple `always_ff` blocks writing the same array element on the
  same edge is a real, silent hazard**, not just a style nit -- see the
  `S_IDLE`/COUNT race above. iverilog (and Verilog in general) doesn't
  flag this; it just picks an implementation-defined winner. Worth an
  explicit lint pass (or a manual grep for `<=` targets shared across
  `always_ff` blocks) before trusting any *other* module in this project
  that hasn't been through this level of scrutiny yet.
- `unique case` qualities and constant selects in `always_*` produce
  "sorry" messages. Benign here.

## Suggested next steps

1. **Give `kv_compress_top.sv` a real control FSM** so `start` and
   `tile_id` mean something and `done` means "tile compressed", not "AXI
   write finished." The single-tile pass above completed without this
   being wired up (the data path's own completion happened to be
   sufficient), but multi-tile operation needs it.
2. **Chain into `zstd_decomp_pipeline`**: encode a tile here, feed the
   resulting compressed bytes + table + `init_state` into
   `zstd_decomp_top`, and confirm the decompressed output matches the
   original quantized input. That round trip is the real correctness bar
   for the KV path, and worth more than either testbench alone -- it
   would catch any convention mismatch between encoder and decoder that
   both testbenches currently miss because they share the same C model's
   assumptions.
3. **Exercise the dictionary on both sides**: give the golden model a
   non-empty `dict[]`, populate `dict_mem_kv` and the dictionary hash
   table in the testbench, and check that a dictionary-crossing match
   round-trips. Note `kv_encoder.c`'s `lz77_match()` emits dictionary
   offsets as `bestOff = n - j`, while the decoder's convention is
   `dict_addr = offset - TILE_SIZE_BYTES` -- those do not agree, and
   neither side is currently tested, so resolve the convention before
   writing the test.
4. **Test a second, independently-chosen tile** (different length,
   different symbol distribution, a case that exercises the
   `merged_cnt>=8`-with-leftover path deliberately rather than by luck)
   to build confidence beyond this one vector.
5. Wire `dict_hash_wr_*` up to whatever maintains D_KV's contents at
   runtime, and decide on a re-indexing policy (rebuild on every
   dictionary update? incremental?).
6. Replace `quant_pack.sv`'s placeholder fixed-point arithmetic with a
   real FPU or fixed-point core, and re-verify.
