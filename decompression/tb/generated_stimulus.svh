// ============================================================
// generated_stimulus.svh -- AUTO-GENERATED, DO NOT EDIT
// Source: model/compute_test_vectors.c (via gen_stimulus.py)
// Regenerate: python3 gen_stimulus.py
//
// The array fills below are `initial` blocks. iverilog runs
// initial blocks in source order, and this file is included at
// the TOP of the tb module, so these run before the tb's own
// time-0 AXI `mem` init that reads GEN_COMP_BYTES. Keep the
// `include` first in the module -- moving it below the mem
// initial block would read X's.
// ============================================================

localparam int GEN_TILE_SIZE_BYTES   = 12;
localparam int GEN_NUM_COMP_BYTES    = 5;
localparam int GEN_NUM_TABLE_ENTRIES = 16;
localparam logic [31:0] GEN_INIT_STATE  = 32'd1;
localparam logic [31:0] GEN_NUM_SYMBOLS = 32'd10;

// ---- FSE decode table preload ----
logic [11:0] GEN_TABLE_ADDR [0:15];
initial begin
    GEN_TABLE_ADDR[0] = 12'd0; GEN_TABLE_ADDR[1] = 12'd1; GEN_TABLE_ADDR[2] = 12'd2; GEN_TABLE_ADDR[3] = 12'd3; GEN_TABLE_ADDR[4] = 12'd4; GEN_TABLE_ADDR[5] = 12'd5;
    GEN_TABLE_ADDR[6] = 12'd6; GEN_TABLE_ADDR[7] = 12'd7; GEN_TABLE_ADDR[8] = 12'd8; GEN_TABLE_ADDR[9] = 12'd9; GEN_TABLE_ADDR[10] = 12'd10; GEN_TABLE_ADDR[11] = 12'd11;
    GEN_TABLE_ADDR[12] = 12'd12; GEN_TABLE_ADDR[13] = 12'd13; GEN_TABLE_ADDR[14] = 12'd14; GEN_TABLE_ADDR[15] = 12'd15;
end
logic [8:0] GEN_TABLE_SYMBOL [0:15];
initial begin
    GEN_TABLE_SYMBOL[0] = 9'd0; GEN_TABLE_SYMBOL[1] = 9'd5; GEN_TABLE_SYMBOL[2] = 9'd6; GEN_TABLE_SYMBOL[3] = 9'd10; GEN_TABLE_SYMBOL[4] = 9'd17; GEN_TABLE_SYMBOL[5] = 9'd34;
    GEN_TABLE_SYMBOL[6] = 9'd170; GEN_TABLE_SYMBOL[7] = 9'd187; GEN_TABLE_SYMBOL[8] = 9'd256; GEN_TABLE_SYMBOL[9] = 9'd256; GEN_TABLE_SYMBOL[10] = 9'd256; GEN_TABLE_SYMBOL[11] = 9'd256;
    GEN_TABLE_SYMBOL[12] = 9'd256; GEN_TABLE_SYMBOL[13] = 9'd256; GEN_TABLE_SYMBOL[14] = 9'd256; GEN_TABLE_SYMBOL[15] = 9'd256;
end
logic [4:0] GEN_TABLE_NBBITS [0:15];
initial begin
    GEN_TABLE_NBBITS[0] = 5'd4; GEN_TABLE_NBBITS[1] = 5'd4; GEN_TABLE_NBBITS[2] = 5'd4; GEN_TABLE_NBBITS[3] = 5'd4; GEN_TABLE_NBBITS[4] = 5'd4; GEN_TABLE_NBBITS[5] = 5'd4;
    GEN_TABLE_NBBITS[6] = 5'd4; GEN_TABLE_NBBITS[7] = 5'd4; GEN_TABLE_NBBITS[8] = 5'd1; GEN_TABLE_NBBITS[9] = 5'd1; GEN_TABLE_NBBITS[10] = 5'd1; GEN_TABLE_NBBITS[11] = 5'd1;
    GEN_TABLE_NBBITS[12] = 5'd1; GEN_TABLE_NBBITS[13] = 5'd1; GEN_TABLE_NBBITS[14] = 5'd1; GEN_TABLE_NBBITS[15] = 5'd1;
end
logic [11:0] GEN_TABLE_NEWSTATE [0:15];
initial begin
    GEN_TABLE_NEWSTATE[0] = 12'd0; GEN_TABLE_NEWSTATE[1] = 12'd0; GEN_TABLE_NEWSTATE[2] = 12'd0; GEN_TABLE_NEWSTATE[3] = 12'd0; GEN_TABLE_NEWSTATE[4] = 12'd0; GEN_TABLE_NEWSTATE[5] = 12'd0;
    GEN_TABLE_NEWSTATE[6] = 12'd0; GEN_TABLE_NEWSTATE[7] = 12'd0; GEN_TABLE_NEWSTATE[8] = 12'd0; GEN_TABLE_NEWSTATE[9] = 12'd2; GEN_TABLE_NEWSTATE[10] = 12'd4; GEN_TABLE_NEWSTATE[11] = 12'd6;
    GEN_TABLE_NEWSTATE[12] = 12'd8; GEN_TABLE_NEWSTATE[13] = 12'd10; GEN_TABLE_NEWSTATE[14] = 12'd12; GEN_TABLE_NEWSTATE[15] = 12'd14;
end

// ---- compressed bitstream (loaded into AXI memory model) ----
logic [7:0] GEN_COMP_BYTES [0:4];
initial begin
    GEN_COMP_BYTES[0] = 8'h76; GEN_COMP_BYTES[1] = 8'h43; GEN_COMP_BYTES[2] = 8'h85; GEN_COMP_BYTES[3] = 8'h44; GEN_COMP_BYTES[4] = 8'h00;
end

// ---- expected LZ-reconstructed bytes (scoreboard target) ----
logic [7:0] GEN_EXPECTED_LZ_BYTES [0:11];
initial begin
    GEN_EXPECTED_LZ_BYTES[0] = 8'h05; GEN_EXPECTED_LZ_BYTES[1] = 8'haa; GEN_EXPECTED_LZ_BYTES[2] = 8'hbb; GEN_EXPECTED_LZ_BYTES[3] = 8'h0a; GEN_EXPECTED_LZ_BYTES[4] = 8'h11; GEN_EXPECTED_LZ_BYTES[5] = 8'h22;
    GEN_EXPECTED_LZ_BYTES[6] = 8'h05; GEN_EXPECTED_LZ_BYTES[7] = 8'haa; GEN_EXPECTED_LZ_BYTES[8] = 8'hbb; GEN_EXPECTED_LZ_BYTES[9] = 8'h0a; GEN_EXPECTED_LZ_BYTES[10] = 8'h11; GEN_EXPECTED_LZ_BYTES[11] = 8'h22;
end
