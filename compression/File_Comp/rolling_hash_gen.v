`default_nettype none
`timescale 1ns/1ps

module rolling_hash_gen #(
    parameter HASH_W   = 16,
    parameter POS_W    = 18,
    parameter N_HASHES = 8
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [7:0]        in_byte,
    input  wire [POS_W-1:0]  in_pos,
    input  wire              in_valid,
    output reg  [HASH_W-1:0] hash_out [0:N_HASHES-1],
    output reg  [POS_W-1:0]  hash_pos,
    output reg               hash_valid
);
    reg [7:0] window [0:3];
    reg [1:0] fill_cnt;

    localparam [127:0] BASE = {
        16'hF5BD, 16'h71AB, 16'hC6E1, 16'h3B9D,
        16'hD1F3, 16'hA5C7, 16'h6B43, 16'h9E37
    };
    integer i;

    wire [7:0] window_next [0:3];
    assign window_next[0] = in_byte;
    assign window_next[1] = window[0];
    assign window_next[2] = window[1];
    assign window_next[3] = window[2];

    wire [15:0] h_next [0:N_HASHES-1];
    genvar g;
    generate
        for (g = 0; g < N_HASHES; g = g + 1) begin : hash_horner
            wire [15:0] b = BASE[g*16 +: 16];
            wire [15:0] s3 = {8'd0, window_next[3]};
            wire [15:0] s2 = (s3 * b) + {8'd0, window_next[2]};
            wire [15:0] s1 = (s2 * b) + {8'd0, window_next[1]};
            wire [15:0] s0 = (s1 * b) + {8'd0, window_next[0]};
            assign h_next[g] = s0;
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_cnt   <= 2'd0;
            hash_valid <= 1'b0;
            hash_pos   <= {POS_W{1'b0}};
            for (i = 0; i < 4; i = i + 1)
                window[i] <= 8'd0;
            for (i = 0; i < N_HASHES; i = i + 1)
                hash_out[i] <= 16'd0;
        end else if (in_valid) begin
            window[0] <= in_byte;
            window[1] <= window[0];
            window[2] <= window[1];
            window[3] <= window[2];

            if (fill_cnt != 2'd3)
                fill_cnt <= fill_cnt + 1;
            for (i = 0; i < N_HASHES; i = i + 1)
                hash_out[i] <= h_next[i];
            hash_pos   <= in_pos;
            hash_valid <= in_valid; 
        end else begin
            hash_valid <= 1'b0;
        end
    end
endmodule
`default_nettype wire
