`default_nettype none
`timescale 1ns/1ps

module tree_walkers #(
    parameter N_WALKERS    = 32,
    parameter MAX_MATCHES  = 8,
    parameter OFFSET_W     = 23,
    parameter POS_W        = 18,
    parameter MAX_ML       = 255,
    parameter ML_W         = 8,
    parameter WIN_SIZE     = 8388608
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [7:0]              hist_wr_byte,
    input  wire [OFFSET_W-1:0]     hist_wr_addr,
    input  wire                    hist_wr_en,
    input  wire [POS_W-1:0]        cam_pos,
    input  wire [OFFSET_W-1:0]     cam_offsets [0:MAX_MATCHES-1],
    input  wire [MAX_MATCHES-1:0]  cam_valid_vec,
    input  wire [5:0]              cam_count,
    input  wire                    cam_valid,
    input  wire [7:0]              cur_window [0:MAX_ML-1],
    output reg  [OFFSET_W-1:0]     ext_offsets [0:N_WALKERS-1],
    output reg  [ML_W-1:0]         ext_lengths [0:N_WALKERS-1],
    output reg  [N_WALKERS-1:0]    ext_valid_vec,
    output reg  [POS_W-1:0]        ext_pos,
    output reg                     ext_valid
);
    (* ram_style = "block" *)
    reg [7:0] hist_buf [0:WIN_SIZE-1];

    integer h_idx;
    initial begin
        for (h_idx = 0; h_idx < WIN_SIZE; h_idx = h_idx + 1) begin
            hist_buf[h_idx] = 8'd0;
        end
    end

    always @(posedge clk) begin
        if (hist_wr_en)
            hist_buf[hist_wr_addr] <= hist_wr_byte;
    end

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ext_valid <= 1'b0;
        end else begin
            ext_valid <= cam_valid;
            ext_pos   <= cam_pos;
            for (i = 0; i < N_WALKERS; i = i + 1) begin
                if (i < MAX_MATCHES) begin
                    ext_offsets[i]   <= cam_offsets[i];
                    ext_lengths[i]   <= cam_valid_vec[i] ? 8'd4 : 8'd0;
                    ext_valid_vec[i] <= cam_valid_vec[i];
                end else begin
                    ext_offsets[i]   <= '0;
                    ext_lengths[i]   <= 8'd0;
                    ext_valid_vec[i] <= 1'b0;
                end
            end
        end
    end
endmodule
`default_nettype wire
