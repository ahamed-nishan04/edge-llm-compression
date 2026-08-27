`default_nettype none
`timescale 1ns/1ps

module price_calculator #(
    parameter K          = 64,
    parameter OFFSET_W   = 23,
    parameter ML_W       = 8,
    parameter POS_W      = 18,
    parameter PRICE_W    = 16,
    parameter CACHE_WAYS = 256
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [OFFSET_W-1:0] in_offsets [0:K-1],
    input  wire [ML_W-1:0]     in_lengths [0:K-1],
    input  wire [K-1:0]        in_valid,
    input  wire [POS_W-1:0]    in_pos,
    input  wire                in_pulse,
    input  wire [7:0]          lit_byte,
    input  wire [7:0]          fse_ml_table  [0:255],
    input  wire [7:0]          fse_off_table [0:255],
    input  wire [7:0]          huf_lit_table [0:255],
    output reg  [PRICE_W-1:0]  out_prices [0:K],
    output reg  [OFFSET_W-1:0] out_offsets[0:K-1],
    output reg  [ML_W-1:0]     out_lengths[0:K-1],
    output reg  [K:0]          out_valid,
    output reg  [POS_W-1:0]    out_pos,
    output reg                 out_pulse
);
    reg [PRICE_W-1:0] price_cache [0:CACHE_WAYS-1];
    reg               cache_valid [0:CACHE_WAYS-1];
    integer cache_idx_init;
    initial begin
        for (cache_idx_init = 0; cache_idx_init < CACHE_WAYS; cache_idx_init = cache_idx_init + 1) begin
            price_cache[cache_idx_init] = '0;
            cache_valid[cache_idx_init] = 1'b0;
        end
    end

    function [7:0] cache_idx;
        input [ML_W-1:0]     ml;
        input [OFFSET_W-1:0] off;
        reg [4:0] off_log;
        integer b;
        begin
            off_log = 5'd0;
            for (b = 0; b <= 22; b = b+1)
                if (off[b]) off_log = b[4:0];
            cache_idx = ml ^ {3'd0, off_log};
        end
    endfunction

    function [7:0] offset_code;
        input [OFFSET_W-1:0] off;
        integer b;
        begin
            offset_code = 8'd0;
            for (b = 1; b <= 22; b = b+1)
                if (off[b]) offset_code = b[7:0];
        end
    endfunction

    reg [PRICE_W-1:0]  pipe_price   [0:K][0:7];
    reg [K:0]          pipe_valid   [0:7];
    reg [POS_W-1:0]    pipe_pos     [0:7];
    reg [OFFSET_W-1:0] pipe_off     [0:K-1][0:7];
    reg [ML_W-1:0]     pipe_len     [0:K-1][0:7];
    reg [7:0]          pipe_offcode [0:K-1][0:7];

    integer i, s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pulse <= 1'b0;
            for (s = 0; s < 8; s = s+1)
                pipe_valid[s] <= '0;
        end else begin
            out_pulse <= 1'b0;
            if (in_pulse) begin
                pipe_valid[0][0] <= 1'b1;
                pipe_pos[0]      <= in_pos;
                pipe_price[0][0] <= {8'd0, huf_lit_table[lit_byte]};
                for (i = 0; i < K; i = i+1) begin
                    pipe_valid[0][i+1] <= in_valid[i];
                    pipe_offcode[i][0] <= offset_code(in_offsets[i]);
                    pipe_price[i+1][0] <= {8'd0, fse_off_table[offset_code(in_offsets[i])]};
                    pipe_off[i][0]     <= in_offsets[i];
                    pipe_len[i][0]     <= in_lengths[i];
                end
            end else begin
                pipe_valid[0] <= '0;
            end

            for (s = 1; s < 8; s = s+1) begin
                pipe_valid[s] <= pipe_valid[s-1];
                pipe_pos[s]   <= pipe_pos[s-1];
                pipe_price[0][s] <= pipe_price[0][s-1];

                for (i = 0; i < K; i = i+1) begin
                    pipe_off[i][s]     <= pipe_off[i][s-1];
                    pipe_len[i][s]     <= pipe_len[i][s-1];
                    pipe_offcode[i][s] <= pipe_offcode[i][s-1];
                    if (s == 1) begin
                        pipe_price[i+1][s] <= pipe_price[i+1][s-1] + {8'd0, fse_ml_table[pipe_len[i][s-1]]};
                    end else if (s == 2) begin
                        pipe_price[i+1][s] <= pipe_price[i+1][s-1] + ({8'd0, pipe_offcode[i][s-1]} << 8);
                    end else begin
                        pipe_price[i+1][s] <= pipe_price[i+1][s-1];
                    end
                end
            end

            if (pipe_valid[7] != '0) begin
                out_pulse     <= 1'b1;
                out_pos       <= pipe_pos[7];
                out_valid     <= pipe_valid[7];
                out_prices[0] <= pipe_price[0][7];
                for (i = 0; i < K; i = i+1) begin
                    out_prices[i+1] <= pipe_price[i+1][7];
                    out_offsets[i]  <= pipe_off[i][7];
                    out_lengths[i]  <= pipe_len[i][7];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (out_pulse) begin
            for (i = 0; i < K; i = i+1) begin
                if (out_valid[i+1]) begin
                    price_cache[cache_idx(out_lengths[i], out_offsets[i])] <= out_prices[i+1];
                    cache_valid[cache_idx(out_lengths[i], out_offsets[i])] <= 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
