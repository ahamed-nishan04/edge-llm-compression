// =============================================================================
// quant_pack.sv
// Converts incoming fp32 K/V elements to INT8 (uniform scale/zero for this
// tile) as they arrive. INT8-only for now, matching the paper's note that
// the KV path is expected to use a lighter/faster quantization than the
// static-weight AWQ-INT4 path (KV accesses are latency-sensitive -- see
// Section X-E). Extend quant_mode handling here (and the corresponding
// pack-to-nibble logic) if KV ever needs NF4/AWQ-INT4 too.
// =============================================================================

module quant_pack #(
    parameter int TILE_ADDR_WIDTH = 12,
    parameter int QUANT_MODE_WIDTH = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [QUANT_MODE_WIDTH-1:0] quant_mode,   // 0 = INT8 (only mode implemented)
    input  logic signed [15:0] scale,                  // same Q-format as dequant_unit.sv
    input  logic signed [7:0]  zero,

    input  logic [31:0] in_data,   // fp32
    input  logic         in_valid,
    output logic         in_ready,
    input  logic         in_last,

    output logic [7:0]  out_byte,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_last,
    output logic [TILE_ADDR_WIDTH-1:0] out_offset
);

    // ---------------- "fp32" -> int8 quantize: q = round(x/scale) + zero,
    // clamped to [0,255] -- mirrors model/kv_encoder.c's quantize_int8()
    // exactly so RTL and golden model agree bit-for-bit.
    //
    // SIMULATION-ONLY PLACEHOLDER: in_data is treated here as a Q16.16
    // fixed-point value, NOT true IEEE-754 fp32 bits ($bitstoshortreal
    // isn't supported by every simulator, iverilog included, so this
    // avoids it entirely rather than depending on it). Real hardware
    // would take actual fp32 in_data through an FPU (or a fixed-point
    // reciprocal-multiply core); this sketch is a stand-in for that,
    // same as the original real-number version was. The TESTBENCH must
    // drive in_data as Q16.16 to match (see tb_kv_compress_top.sv).
    logic signed [31:0] scaled_int;
    logic signed [31:0] scale_fixed;   // scale, widened from Q8.8 to Q16.16
    logic signed [63:0] div_result;
    logic signed [63:0] numer;
    logic signed [63:0] denom;
    logic signed [63:0] half_abs;
    logic signed [63:0] adj_numer;

    assign scale_fixed = {{16{scale[15]}}, scale} <<< 8;
    assign numer        = ($signed({{32{in_data[31]}}, in_data}) <<< 16);
    assign denom         = {{32{scale_fixed[31]}}, scale_fixed};
    // half_abs must represent half of one unit at the bit-16 (integer)
    // boundary of the Q16.16 quotient, i.e. 0.5 * 2^16 * |denom|, not
    // 0.5 * |denom|. Using the latter rounds the raw (pre-shift)
    // quotient to its nearest 2^-16 value, which has no effect once the
    // fractional bits are discarded by the final >>16 -- effectively
    // truncating (flooring) instead of rounding to nearest integer.
    assign half_abs      = (denom[63] ? -denom : denom) <<< 15;
    assign adj_numer     = (numer[63] ^ denom[63]) ? (numer - half_abs) : (numer + half_abs);
    assign div_result    = (scale_fixed != 0) ? (adj_numer / denom) : 64'sd0;
    assign scaled_int  = div_result[47:16]; // back to a plain integer

    logic signed [31:0] q_with_zero;
    assign q_with_zero = scaled_int + zero;

    logic [7:0] q_clamped;
    always_comb begin
        if (q_with_zero < 0)          q_clamped = 8'd0;
        else if (q_with_zero > 255)   q_clamped = 8'd255;
        else                          q_clamped = q_with_zero[7:0];
    end

    logic [TILE_ADDR_WIDTH-1:0] offset_ctr;

    assign in_ready = out_ready || !out_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_byte   <= '0;
            out_valid  <= 1'b0;
            out_last   <= 1'b0;
            out_offset <= '0;
            offset_ctr <= '0;
        end else if (in_ready) begin
            out_byte   <= q_clamped;
            out_valid  <= in_valid;
            out_last   <= in_last;
            out_offset <= offset_ctr;
            if (in_valid) begin
                offset_ctr <= in_last ? '0 : offset_ctr + 1'b1;
            end
        end
    end

endmodule