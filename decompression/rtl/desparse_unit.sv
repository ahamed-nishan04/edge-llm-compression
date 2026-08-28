// =============================================================================
// desparse_unit.sv
// Expands 2:4 structured-sparse packed data back to dense form.
//
// 2:4 sparsity format assumed (NVIDIA/standard convention): every group of
// 4 output elements has exactly 2 nonzero values. Compressed representation
// per group: 1 index byte (low 4 bits = 4-bit position mask, one bit set
// per nonzero position) + 2 nonzero values. Byte granularity (INT8
// elements) assumed; for NF4/INT4 elements pack 2 per byte before this
// stage or widen in_data accordingly.
//
// `bypass` is a runtime control (wired from top-level desparse_en) so tiles
// that were never sparsified (e.g. KV cache tiles, dense INT8 per your
// design notes) can skip this stage without a separate build. ENABLE is a
// compile-time parameter that, when 0, forces bypass permanently and lets
// synthesis strip the unused group-decode logic if you know a given
// instance will never see sparse data.
//
// Matches golden_model.c's desparse_2_4():
//
//     while (ip + 2 < in_len) {
//         idx = in[ip] & 0x0F; v0 = in[ip+1]; v1 = in[ip+2]; ip += 3;
//         seen = 0;
//         for (pos = 0; pos < 4; pos++)
//             if (idx & (1<<pos)) out[op++] = (seen++ == 0) ? v0 : v1;
//             else                out[op++] = 0x00;
//     }
//
// i.e. for each group of (idx, v0, v1), scan positions 0..3; if idx bit
// `pos` is set, emit v0 for the FIRST set bit seen in the group and v1 for
// every subsequent set bit; otherwise emit 0x00. A trailing partial group
// (fewer than 3 input bytes) produces no output, exactly as the C loop
// guard `ip + 2 < in_len` dictates -- the FSM simply stalls waiting for the
// missing bytes and never emits them.
//
// Coding style note (toolchain portability): EVERY bit-select, part-select
// and vector arithmetic result is produced by a *continuous assignment*,
// never inside an always_* process.  The iverilog build used by this
// project emits "sorry: constant selects in always_* processes are not
// fully supported" for procedural selects, so all procedural code below
// reads and writes whole signals only.  No `unique`/`priority` case
// qualifiers are used either, for the same portability reason.  Both forms
// are plain, synthesis-friendly SystemVerilog-2012.
// =============================================================================

module desparse_unit #(
    parameter int TILE_SIZE_BYTES = 4096,
    parameter int NUM_TILES       = 64,
    parameter bit ENABLE          = 1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic bypass,

    input  logic [7:0]  in_data,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_tile_last,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,
    input  logic [$clog2(TILE_SIZE_BYTES)-1:0] in_tile_offset,

    output logic [7:0]  out_data,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_tile_last,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,
    output logic [$clog2(TILE_SIZE_BYTES)-1:0] out_tile_offset
);

    localparam int TID_W = $clog2(NUM_TILES);
    localparam int OFF_W = $clog2(TILE_SIZE_BYTES);

    // Plain localparams instead of an enum keep this maximally portable
    // across the toolchains this project is built with.
    localparam logic [1:0] S_GET_IDX = 2'd0;
    localparam logic [1:0] S_GET_V0  = 2'd1;
    localparam logic [1:0] S_GET_V1  = 2'd2;
    localparam logic [1:0] S_EMIT    = 2'd3;

    localparam logic [OFF_W-1:0] OFF_ONE  = {{(OFF_W-1){1'b0}}, 1'b1};
    localparam logic [OFF_W-1:0] OFF_ZERO = {OFF_W{1'b0}};
    localparam logic [TID_W-1:0] TID_ZERO = {TID_W{1'b0}};

    // ---------------- state ----------------
    logic [1:0]       st;
    logic [1:0]       st_n;

    logic [3:0]       idx_q;
    logic [7:0]       v0_q;
    logic [7:0]       v1_q;
    logic [1:0]       emit_pos;
    logic [TID_W-1:0] tile_id_q;
    logic [OFF_W-1:0] out_off_q;    // dense OUTPUT byte offset within the tile
    logic             group_last_q; // this group carries the tile's last byte

    // ---------------- bypass ----------------
    // ENABLE == 0 forces permanent bypass; the runtime `bypass` input gives a
    // single netlist the same capability per-tile.
    logic eff_bypass;
    assign eff_bypass = bypass || (ENABLE == 1'b0);

    // ---------------- vector selects (continuous assigns only) ------------
    logic [3:0] in_nib;
    assign in_nib = in_data[3:0];

    logic idx0, idx1, idx2, idx3;
    assign idx0 = idx_q[0];
    assign idx1 = idx_q[1];
    assign idx2 = idx_q[2];
    assign idx3 = idx_q[3];

    logic pos0, pos1, pos2, pos3;
    assign pos0 = (emit_pos == 2'd0);
    assign pos1 = (emit_pos == 2'd1);
    assign pos2 = (emit_pos == 2'd2);
    assign pos3 = (emit_pos == 2'd3);

    logic last_pos;
    assign last_pos = pos3;

    // ---------------- group decode (position -> byte) ----------------
    // bit_set : is position `emit_pos` a nonzero slot?
    // use_v1  : has at least one nonzero slot already been emitted in this
    //           group?  (matches C's `seen` counter: seen==0 -> v0, else v1)
    logic       bit_set;
    logic       use_v1;
    logic [7:0] emit_data;

    assign bit_set = (pos0 & idx0) | (pos1 & idx1) |
                     (pos2 & idx2) | (pos3 & idx3);

    assign use_v1  = (pos1 & idx0) |
                     (pos2 & (idx0 | idx1)) |
                     (pos3 & (idx0 | idx1 | idx2));

    assign emit_data = bit_set ? (use_v1 ? v1_q : v0_q) : 8'h00;

    // ---------------- handshake ----------------
    // in_ready must not depend on in_valid (no combinational handshake loop).
    logic in_fire;
    logic emit_fire;

    assign in_ready  = eff_bypass ? out_ready : (st != S_EMIT);
    assign in_fire   = in_valid && in_ready && !eff_bypass;
    assign emit_fire = (!eff_bypass) && (st == S_EMIT) && out_ready;

    // ---------------- output mux ----------------
    assign out_data        = eff_bypass ? in_data        : emit_data;
    assign out_valid       = eff_bypass ? in_valid       : (st == S_EMIT);
    assign out_tile_id     = eff_bypass ? in_tile_id     : tile_id_q;
    assign out_tile_offset = eff_bypass ? in_tile_offset : out_off_q;
    assign out_tile_last   = eff_bypass ? in_tile_last
                                        : (group_last_q && last_pos);

    // ---------------- precomputed next values (continuous assigns) --------
    // Kept out of the always_ff blocks so no process ever performs a vector
    // select or arithmetic slice -- required for the iverilog build here.
    logic        end_of_tile;
    logic [1:0]  emit_pos_nxt;   // wraps 3 -> 0
    logic [OFF_W-1:0] out_off_inc;
    logic [OFF_W-1:0] out_off_nxt;
    logic [3:0]  group_last_or;  // (unused width guard; see below)

    assign end_of_tile  = group_last_q & last_pos;
    assign emit_pos_nxt = emit_pos + 2'd1;
    assign out_off_inc  = out_off_q + OFF_ONE;
    assign out_off_nxt  = end_of_tile ? OFF_ZERO : out_off_inc;
    assign group_last_or = 4'd0;

    logic group_last_upd;   // sticky tile_last accumulation on v0/v1 beats
    assign group_last_upd = group_last_q | in_tile_last;

    logic group_last_emit;  // cleared once the tile's final byte has gone out
    assign group_last_emit = end_of_tile ? 1'b0 : group_last_q;

    // ---------------- next-state logic ----------------
    always_comb begin
        st_n = S_GET_IDX;
        if (eff_bypass) begin
            st_n = S_GET_IDX;
        end else begin
            case (st)
                S_GET_IDX: st_n = in_fire ? S_GET_V0 : S_GET_IDX;
                S_GET_V0 : st_n = in_fire ? S_GET_V1 : S_GET_V0;
                S_GET_V1 : st_n = in_fire ? S_EMIT   : S_GET_V1;
                S_EMIT   : st_n = (emit_fire && last_pos) ? S_GET_IDX : S_EMIT;
                default  : st_n = S_GET_IDX;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_GET_IDX;
        else        st <= st_n;
    end

    // ---------------- data path registers ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_q        <= 4'd0;
            v0_q         <= 8'd0;
            v1_q         <= 8'd0;
            emit_pos     <= 2'd0;
            tile_id_q    <= TID_ZERO;
            out_off_q    <= OFF_ZERO;
            group_last_q <= 1'b0;
        end else if (eff_bypass) begin
            // Keep the group state clean so that leaving bypass mid-stream
            // always restarts on a fresh group boundary.
            idx_q        <= 4'd0;
            v0_q         <= 8'd0;
            v1_q         <= 8'd0;
            emit_pos     <= 2'd0;
            group_last_q <= 1'b0;
            out_off_q    <= OFF_ZERO;
            tile_id_q    <= in_tile_id;
        end else begin
            case (st)
                S_GET_IDX: begin
                    if (in_fire) begin
                        idx_q        <= in_nib;
                        tile_id_q    <= in_tile_id;
                        group_last_q <= in_tile_last;
                        emit_pos     <= 2'd0;
                    end
                end
                S_GET_V0: begin
                    if (in_fire) begin
                        v0_q         <= in_data;
                        group_last_q <= group_last_upd;
                    end
                end
                S_GET_V1: begin
                    if (in_fire) begin
                        v1_q         <= in_data;
                        group_last_q <= group_last_upd;
                    end
                end
                S_EMIT: begin
                    if (emit_fire) begin
                        emit_pos     <= emit_pos_nxt;   // wraps 3 -> 0
                        out_off_q    <= out_off_nxt;    // restarts at tile end
                        group_last_q <= group_last_emit;
                    end
                end
                default: begin
                    // no-op
                end
            endcase
        end
    end

endmodule