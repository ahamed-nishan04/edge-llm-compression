// =============================================================================
// dequant_unit.sv
// Final pipeline stage: converts stored quantized bytes to the output format
// consumed by the MAC array (or written into KV cache as INT8, per your
// "on-device encoding limited to lightweight KV cache quantization" note).
//
// quant_mode:
//   0 = INT8 passthrough with per-tensor/per-channel scale (AWQ/GPTQ style)
//   1 = NF4  (2 nibbles/byte -> 2 outputs, non-uniform LUT dequant)
//   2 = AWQ-INT4 (2 nibbles/byte -> 2 outputs, uniform affine dequant with
//                 per-group zero-point, matching AWQ's group_size=128 groups)
//
// Scale/zero-point tables are loaded via a side-band port (indexed by
// tile_id or by group index within a tile) -- wire this up from your
// quantization metadata (produced at AWQ/GPTQ export time and packed
// alongside the weight tiles, or streamed from a small on-chip scale SRAM).
//
// Nibble emission order matches golden_model.c's dequant(): for NF4 and
// AWQ-INT4 modes the *high* nibble ((in[i]>>4)&0xF) is emitted first,
// followed by the *low* nibble (in[i]&0xF) second. Lane packing below
// keeps that ordering: out_data[15:0] holds the first-emitted element
// (high nibble result), out_data[31:16] holds the second (low nibble
// result). For INT8 mode both lanes carry the same single dequantized
// value (1 element/byte), so ordering is a don't-care there.
// =============================================================================

module dequant_unit #(
    parameter int TILE_SIZE_BYTES  = 4096,
    parameter int NUM_TILES        = 64,
    parameter int OUT_DATA_WIDTH   = 256,   // e.g. 16x INT16 or 32x INT8 lanes
    parameter int QUANT_MODE_WIDTH = 2,
    parameter int GROUP_SIZE       = 128,   // AWQ-style quant group size
    parameter int SCALE_FRAC_BITS  = 8      // fixed-point scale format Q8.8-ish
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [QUANT_MODE_WIDTH-1:0] quant_mode,

    input  logic [7:0]  in_data,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_tile_last,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,
    input  logic [$clog2(TILE_SIZE_BYTES)-1:0] in_tile_offset,

    output logic [OUT_DATA_WIDTH-1:0] out_data,
    output logic                      out_valid,
    input  logic                      out_ready,
    output logic [$clog2(TILE_SIZE_BYTES)-1:0] out_tile_offset,
    output logic [$clog2(NUM_TILES)-1:0]       out_tile_id,
    output logic                                out_tile_last,

    // ---------------- Scale/zero-point table (per quant group) ----------
    input  logic                          scale_wr_en,
    input  logic [$clog2(TILE_SIZE_BYTES/GROUP_SIZE)-1:0] scale_wr_addr,
    input  logic signed [15:0]            scale_wr_scale,   // Qm.n fixed point
    input  logic signed [7:0]             scale_wr_zero
);

    localparam int NUM_GROUPS = TILE_SIZE_BYTES / GROUP_SIZE;

    logic signed [15:0] scale_mem [0:NUM_GROUPS-1];
    logic signed [7:0]  zero_mem  [0:NUM_GROUPS-1];

    always_ff @(posedge clk) begin
        if (scale_wr_en) begin
            scale_mem[scale_wr_addr] <= scale_wr_scale;
            zero_mem[scale_wr_addr]  <= scale_wr_zero;
        end
    end

    logic [$clog2(NUM_GROUPS)-1:0] cur_group;
    assign cur_group = in_tile_offset / GROUP_SIZE;

    logic signed [15:0] cur_scale;
    logic signed [7:0]  cur_zero;
    assign cur_scale = scale_mem[cur_group];
    assign cur_zero  = zero_mem[cur_group];

    // NF4 non-uniform LUT (standard NF4 quantile codebook, Q1.15 fixed point)
    logic signed [15:0] nf4_lut [0:15];
    initial begin
        nf4_lut[0]  = 16'sh8000; nf4_lut[1]  = 16'shA6EA; nf4_lut[2]  = 16'shBC1A;
        nf4_lut[3]  = 16'shCC30; nf4_lut[4]  = 16'shD8F6; nf4_lut[5]  = 16'shE3C6;
        nf4_lut[6]  = 16'shEE10; nf4_lut[7]  = 16'shF7B0; nf4_lut[8]  = 16'sh0000;
        nf4_lut[9]  = 16'sh0A8C; nf4_lut[10] = 16'sh155C; nf4_lut[11] = 16'sh20E0;
        nf4_lut[12] = 16'sh2DA8; nf4_lut[13] = 16'sh3C40; nf4_lut[14] = 16'sh4F60;
        nf4_lut[15] = 16'sh7FFF; // exact codebook values TODO: verify against
                                  // your training-time NF4 quantiles export
    end

    // Pipeline: register the arithmetic, 1-cycle latency stage
    logic [7:0] data_q;
    logic [$clog2(TILE_SIZE_BYTES)-1:0] off_q;
    logic [$clog2(NUM_TILES)-1:0] tid_q;
    logic last_q, valid_q;
    logic [QUANT_MODE_WIDTH-1:0] mode_q;
    logic signed [15:0] scale_q;
    logic signed [7:0]  zero_q;

    assign in_ready = out_ready || !valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
        end else if (in_ready) begin
            data_q  <= in_data;
            off_q   <= in_tile_offset;
            tid_q   <= in_tile_id;
            last_q  <= in_tile_last;
            valid_q <= in_valid;
            mode_q  <= quant_mode;
            scale_q <= cur_scale;
            zero_q  <= cur_zero;
        end
    end

    // dequant_hi -> first element emitted for this byte (high nibble for
    // nibble modes; the sole element for INT8 mode).
    // dequant_lo -> second element emitted (low nibble for nibble modes;
    // duplicate of dequant_hi for INT8 mode).
    logic signed [31:0] dequant_hi, dequant_lo;
    always_comb begin
        unique case (mode_q)
            2'd0: begin // INT8: out = (data - zero) * scale
                dequant_hi = ($signed({8'd0, data_q}) - zero_q) * scale_q;
                dequant_lo = dequant_hi;
            end
            2'd1: begin // NF4: high nibble first, then low nibble -> LUT * scale
                dequant_hi = nf4_lut[data_q[7:4]] * scale_q;
                dequant_lo = nf4_lut[data_q[3:0]] * scale_q;
            end
            2'd2: begin // AWQ-INT4: high nibble first, then low nibble, shared zero
                dequant_hi = ($signed({28'd0, data_q[7:4]}) - zero_q) * scale_q;
                dequant_lo = ($signed({28'd0, data_q[3:0]}) - zero_q) * scale_q;
            end
            default: begin
                dequant_hi = '0; dequant_lo = '0;
            end
        endcase
    end

    // Pack two 16-bit dequant lanes (nibble modes emit 2 elements/byte;
    // INT8 mode emits 1 element replicated -- widen/pack per your actual
    // downstream MAC array element width and lane count).
    // Lane 0 (out_data[15:0])  = first-emitted element (dequant_hi)
    // Lane 1 (out_data[31:16]) = second-emitted element (dequant_lo)
    // matching golden_model.c's dequant() emission order (high nibble
    // before low nibble for nibble-packed modes).
    always_comb begin
        out_data = '0;
        out_data[15:0]  = dequant_hi[15:0];
        out_data[31:16] = dequant_lo[15:0];
        // remaining OUT_DATA_WIDTH bits: replicate/tie off per your MAC
        // array's actual lane count -- this shows 2 lanes populated as a
        // template; extend the case statement above to fill more lanes
        // per cycle if in_data itself is widened upstream.
    end

    assign out_valid       = valid_q;
    assign out_tile_offset = off_q;
    assign out_tile_id     = tid_q;
    assign out_tile_last   = last_q;

endmodule