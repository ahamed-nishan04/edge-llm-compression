module dequant_unit #(
    parameter int TILE_SIZE_BYTES  = 4096,
    parameter int NUM_TILES        = 64,
    parameter int OUT_DATA_WIDTH   = 256,   
    parameter int QUANT_MODE_WIDTH = 2,
    parameter int GROUP_SIZE       = 128,   
    parameter int SCALE_FRAC_BITS  = 8      
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

    input  logic                          scale_wr_en,
    input  logic [$clog2(TILE_SIZE_BYTES/GROUP_SIZE)-1:0] scale_wr_addr,
    input  logic signed [15:0]            scale_wr_scale,   
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

    logic signed [15:0] nf4_lut [0:15];
    initial begin
        nf4_lut[0]  = 16'sh8000; nf4_lut[1]  = 16'shA6EA; nf4_lut[2]  = 16'shBC1A;
        nf4_lut[3]  = 16'shCC30; nf4_lut[4]  = 16'shD8F6; nf4_lut[5]  = 16'shE3C6;
        nf4_lut[6]  = 16'shEE10; nf4_lut[7]  = 16'shF7B0; nf4_lut[8]  = 16'sh0000;
        nf4_lut[9]  = 16'sh0A8C; nf4_lut[10] = 16'sh155C; nf4_lut[11] = 16'sh20E0;
        nf4_lut[12] = 16'sh2DA8; nf4_lut[13] = 16'sh3C40; nf4_lut[14] = 16'sh4F60;
        nf4_lut[15] = 16'sh7FFF; 
    end

    logic [7:0] data_q;
    logic [$clog2(TILE_SIZE_BYTES)-1:0] off_q;
    logic [$clog2(NUM_TILES)-1:0] tid_q;
    logic last_q, valid_q;
    logic [1:0] mode_q;
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

    logic signed [31:0] dequant_hi, dequant_lo;
    always_comb begin
        unique case (mode_q)
            2'd0: begin 
                dequant_hi = ($signed({8'd0, data_q}) - zero_q) * scale_q;
                dequant_lo = dequant_hi;
            end
            2'd1: begin 
                dequant_hi = nf4_lut[data_q[7:4]] * scale_q;
                dequant_lo = nf4_lut[data_q[3:0]] * scale_q;
            end
            2'd2: begin 
                dequant_hi = ($signed({28'd0, data_q[7:4]}) - zero_q) * scale_q;
                dequant_lo = ($signed({28'd0, data_q[3:0]}) - zero_q) * scale_q;
            end
            default: begin
                dequant_hi = '0; dequant_lo = '0;
            end
        endcase
    end

    always_comb begin
        out_data = '0;
        out_data[15:0]  = dequant_lo[15:0];
        out_data[31:16] = dequant_hi[15:0];
    end

    assign out_valid       = valid_q;
    assign out_tile_offset = off_q;
    assign out_tile_id     = tid_q;
    assign out_tile_last   = last_q;

endmodule
