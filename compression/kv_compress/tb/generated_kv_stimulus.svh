// ============================================================
// generated_kv_stimulus.svh -- AUTO-GENERATED, DO NOT EDIT
// Source: model/kv_encoder.c (via gen_kv_stimulus.py)
// Regenerate: python3 gen_kv_stimulus.py
//
// Array fills are `initial` blocks (iverilog 12.0 rejects unpacked
// array localparams). iverilog runs initial blocks in source order
// and this file is included at the TOP of the tb module, so the
// fills land before anything reads them. Keep the include first.
// ============================================================

localparam int GEN_NUM_RAW        = 16;
localparam int GEN_NUM_QUANT      = 16;
localparam int GEN_NUM_TOKENS     = 14;
localparam int GEN_NUM_COMP_BYTES = 7;
localparam logic [31:0] GEN_INIT_STATE = 32'd4;
localparam logic [15:0] GEN_QUANT_SCALE_Q88 = 16'd256;
localparam logic [7:0]  GEN_QUANT_ZERO = 8'd0;

// ---- input tile (integers; tb drives these <<< 16 as Q16.16) ----
logic [31:0] GEN_RAW_VALS [0:15];
initial begin
    GEN_RAW_VALS[0] = 32'd1; GEN_RAW_VALS[1] = 32'd2; GEN_RAW_VALS[2] = 32'd3; GEN_RAW_VALS[3] = 32'd4; GEN_RAW_VALS[4] = 32'd5; GEN_RAW_VALS[5] = 32'd6;
    GEN_RAW_VALS[6] = 32'd1; GEN_RAW_VALS[7] = 32'd2; GEN_RAW_VALS[8] = 32'd3; GEN_RAW_VALS[9] = 32'd4; GEN_RAW_VALS[10] = 32'd5; GEN_RAW_VALS[11] = 32'd6;
    GEN_RAW_VALS[12] = 32'd7; GEN_RAW_VALS[13] = 32'd8; GEN_RAW_VALS[14] = 32'd9; GEN_RAW_VALS[15] = 32'd10;
end

// ---- expected quant_pack output ----
logic [7:0] GEN_QUANT_BYTES [0:15];
initial begin
    GEN_QUANT_BYTES[0] = 8'h01; GEN_QUANT_BYTES[1] = 8'h02; GEN_QUANT_BYTES[2] = 8'h03; GEN_QUANT_BYTES[3] = 8'h04; GEN_QUANT_BYTES[4] = 8'h05; GEN_QUANT_BYTES[5] = 8'h06;
    GEN_QUANT_BYTES[6] = 8'h01; GEN_QUANT_BYTES[7] = 8'h02; GEN_QUANT_BYTES[8] = 8'h03; GEN_QUANT_BYTES[9] = 8'h04; GEN_QUANT_BYTES[10] = 8'h05; GEN_QUANT_BYTES[11] = 8'h06;
    GEN_QUANT_BYTES[12] = 8'h07; GEN_QUANT_BYTES[13] = 8'h08; GEN_QUANT_BYTES[14] = 8'h09; GEN_QUANT_BYTES[15] = 8'h0a;
end

// ---- expected lz_match_finder token stream (9-bit, 256=ESCAPE) ----
logic [8:0] GEN_TOKENS [0:13];
initial begin
    GEN_TOKENS[0] = 9'd1; GEN_TOKENS[1] = 9'd2; GEN_TOKENS[2] = 9'd3; GEN_TOKENS[3] = 9'd4; GEN_TOKENS[4] = 9'd5; GEN_TOKENS[5] = 9'd6;
    GEN_TOKENS[6] = 9'd256; GEN_TOKENS[7] = 9'd0; GEN_TOKENS[8] = 9'd6; GEN_TOKENS[9] = 9'd6; GEN_TOKENS[10] = 9'd7; GEN_TOKENS[11] = 9'd8;
    GEN_TOKENS[12] = 9'd9; GEN_TOKENS[13] = 9'd10;
end

// ---- expected tans_encoder compressed bytes ----
logic [7:0] GEN_COMP_BYTES [0:6];
initial begin
    GEN_COMP_BYTES[0] = 8'h47; GEN_COMP_BYTES[1] = 8'h6a; GEN_COMP_BYTES[2] = 8'h5c; GEN_COMP_BYTES[3] = 8'h90; GEN_COMP_BYTES[4] = 8'h71; GEN_COMP_BYTES[5] = 8'h3b;
    GEN_COMP_BYTES[6] = 8'h00;
end
