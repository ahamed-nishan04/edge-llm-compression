`default_nettype none
`timescale 1ns/1ps

module topk_heap #(
    parameter N_IN     = 32,
    parameter K        = 64,
    parameter OFFSET_W = 23,
    parameter ML_W     = 8,
    parameter POS_W    = 18
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [OFFSET_W-1:0] in_offsets [0:N_IN-1],
    input  wire [ML_W-1:0]     in_lengths [0:N_IN-1],
    input  wire [N_IN-1:0]     in_valid,
    input  wire [POS_W-1:0]    in_pos,
    input  wire                in_valid_pulse,
    output reg  [OFFSET_W-1:0] out_offsets [0:K-1],
    output reg  [ML_W-1:0]     out_lengths [0:K-1],
    output reg  [K-1:0]        out_valid,
    output reg  [POS_W-1:0]    out_pos,
    output reg                 out_valid_pulse
);
    reg [OFFSET_W-1:0] packed_off [0:N_IN-1];
    reg [ML_W-1:0]     packed_len [0:N_IN-1];
    reg [5:0]          packed_cnt;
    reg [POS_W-1:0]    s1_pos;
    reg                s1_valid;

    integer i, j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid   <= 1'b0;
            packed_cnt <= 6'd0;
        end else begin
            s1_valid <= in_valid_pulse;
            s1_pos   <= in_pos;

            if (in_valid_pulse) begin
                begin : pack_loop
                    integer idx;
                    idx = 0;
                    for (i = 0; i < N_IN; i = i + 1) begin
                        if (in_valid[i]) begin
                            packed_off[idx] <= in_offsets[i];
                            packed_len[idx] <= in_lengths[i];
                            idx = idx + 1;
                        end
                    end
                    packed_cnt <= idx[5:0];
                end
            end else begin
                packed_cnt <= 6'd0;
            end
        end
    end

    reg [OFFSET_W-1:0] heap_off [0:K-1];
    reg [ML_W-1:0]     heap_len [0:K-1];
    reg [K-1:0]        heap_vld;
    reg [5:0]          heap_cnt;
    reg                s2_done;
    reg [POS_W-1:0]    s2_pos;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_pulse <= 1'b0;
            heap_cnt        <= 6'd0;
            heap_vld        <= {K{1'b0}};
            s2_done         <= 1'b0;
        end else begin
            s2_done         <= 1'b0;
            out_valid_pulse <= 1'b0;

            if (s1_valid) begin
                heap_cnt <= 6'd0;
                heap_vld <= {K{1'b0}};
                s2_pos   <= s1_pos;

                begin : heap_loop
                    integer hc;
                    hc = 0;
                    for (i = 0; i < N_IN; i = i + 1) begin
                        if (i < packed_cnt) begin
                            if (hc < K) begin
                                heap_off[hc] <= packed_off[i];
                                heap_len[hc] <= packed_len[i];
                                heap_vld[hc] <= 1'b1;
                                hc = hc + 1;
                            end else begin
                                if (packed_len[i] > heap_len[K-1]) begin
                                    heap_off[K-1] <= packed_off[i];
                                    heap_len[K-1] <= packed_len[i];
                                end
                            end
                        end
                    end
                    heap_cnt <= hc[5:0];
                end

                s2_done <= 1'b1;
            end

            if (s2_done) begin
                out_valid_pulse <= 1'b1;
                out_pos         <= s2_pos;
                for (i = 0; i < K; i = i + 1) begin
                    out_offsets[i] <= heap_off[i];
                    out_lengths[i] <= heap_len[i];
                    out_valid[i]   <= heap_vld[i];
                end
            end
        end
    end
endmodule
`default_nettype wire
