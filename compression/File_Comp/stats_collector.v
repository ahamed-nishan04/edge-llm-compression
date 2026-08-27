`default_nettype none
`timescale 1ns/1ps

module stats_collector #(
    parameter ML_SYMS    = 53,
    parameter OFF_SYMS   = 32,
    parameter LIT_SYMS   = 256,
    parameter COUNT_W    = 20,
    parameter FSE_MAX_TB = 8,
    parameter HUF_MAX_BL = 11
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              pass1_start,
    input  wire              pass1_done_in,
    output reg               pass2_done,
    input  wire [7:0]        ml_sym,
    input  wire [4:0]        off_sym,
    input  wire              seq_valid,
    input  wire [7:0]        lit_byte,
    input  wire              lit_valid,
    output reg  [7:0]        fse_ml_table  [0:255],
    output reg  [7:0]        fse_off_table [0:255],
    output reg  [7:0]        huf_lit_nb    [0:LIT_SYMS-1],
    output reg  [15:0]       huf_lit_code  [0:LIT_SYMS-1],
    output reg  [7:0]        huf_lit_table [0:LIT_SYMS-1],
    output reg  [15:0]       fse_ml_norm   [0:ML_SYMS-1],
    output reg  [15:0]       fse_off_norm  [0:OFF_SYMS-1]
);
    reg [COUNT_W-1:0] ml_freq  [0:ML_SYMS-1];
    reg [COUNT_W-1:0] off_freq [0:OFF_SYMS-1];
    reg [COUNT_W-1:0] lit_freq [0:LIT_SYMS-1];
    reg [COUNT_W-1:0] total_ml, total_off, total_lit;
    localparam P1_IDLE=2'd0, P1_COUNT=2'd1, P1_BUILD=2'd2, P1_DONE=2'd3;
    reg [1:0] p1_state;

    reg [7:0]         build_idx;
    reg [COUNT_W-1:0] build_total;

    reg [7:0] bl_comb;
    always @(*) begin
        if (lit_freq[build_idx] == 0)
            bl_comb = 8'd0;
        else if (lit_freq[build_idx] >= (total_lit >> 1))  bl_comb = 8'd1;
        else if (lit_freq[build_idx] >= (total_lit >> 2))  bl_comb = 8'd2;
        else if (lit_freq[build_idx] >= (total_lit >> 3))  bl_comb = 8'd3;
        else if (lit_freq[build_idx] >= (total_lit >> 4))  bl_comb = 8'd4;
        else if (lit_freq[build_idx] >= (total_lit >> 5))  bl_comb = 8'd5;
        else if (lit_freq[build_idx] >= (total_lit >> 6))  bl_comb = 8'd6;
        else if (lit_freq[build_idx] >= (total_lit >> 7))  bl_comb = 8'd7;
        else if (lit_freq[build_idx] >= (total_lit >> 8))  bl_comb = 8'd8;
        else if (lit_freq[build_idx] >= (total_lit >> 9))  bl_comb = 8'd9;
        else if (lit_freq[build_idx] >= (total_lit >> 10)) bl_comb = 8'd10;
        else                                               bl_comb = 8'd11;
        if (bl_comb > HUF_MAX_BL[7:0])
            bl_comb = HUF_MAX_BL[7:0];
    end

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_state   <= P1_IDLE;
            pass2_done <= 1'b0;
            for (i=0; i<ML_SYMS;  i=i+1) ml_freq[i]  <= {COUNT_W{1'b0}};
            for (i=0; i<OFF_SYMS; i=i+1) off_freq[i] <= {COUNT_W{1'b0}};
            for (i=0; i<LIT_SYMS; i=i+1) lit_freq[i] <= {COUNT_W{1'b0}};
            total_ml  <= {COUNT_W{1'b0}};
            total_off <= {COUNT_W{1'b0}};
            total_lit <= {COUNT_W{1'b0}};
        end else begin
            pass2_done <= 1'b0;
            case (p1_state)
                P1_IDLE: begin
                    if (pass1_start) begin
                        for (i=0; i<ML_SYMS;  i=i+1) ml_freq[i]  <= {COUNT_W{1'b0}};
                        for (i=0; i<OFF_SYMS; i=i+1) off_freq[i] <= {COUNT_W{1'b0}};
                        for (i=0; i<LIT_SYMS; i=i+1) lit_freq[i] <= {COUNT_W{1'b0}};
                        total_ml  <= {COUNT_W{1'b0}};
                        total_off <= {COUNT_W{1'b0}};
                        total_lit <= {COUNT_W{1'b0}};
                        p1_state  <= P1_COUNT;
                    end
                end

                P1_COUNT: begin
                    if (seq_valid) begin
                        ml_freq [ml_sym]  <= ml_freq [ml_sym]  + 1;
                        off_freq[off_sym] <= off_freq[off_sym] + 1;
                        total_ml  <= total_ml  + 1;
                        total_off <= total_off + 1;
                    end
                    if (lit_valid) begin
                        lit_freq[lit_byte] <= lit_freq[lit_byte] + 1;
                        total_lit <= total_lit + 1;
                    end
                    if (pass1_done_in) begin
                        build_idx <= 8'd0;
                        p1_state  <= P1_BUILD;
                    end
                end

                P1_BUILD: begin
                    if (build_idx < ML_SYMS) begin
                        fse_ml_norm[build_idx]  <= (ml_freq[build_idx] == 0) ? 16'd0 : (ml_freq[build_idx] << FSE_MAX_TB) / (total_ml + 1);
                        fse_ml_table[build_idx] <= (ml_freq[build_idx] == 0) ? 8'hFF : (FSE_MAX_TB << 3) - ((ml_freq[build_idx] >= (total_ml >> 4)) ? 8'd32 : (ml_freq[build_idx] >= (total_ml >> 8)) ? 8'd16 : 8'd8);
                    end

                    if (build_idx < OFF_SYMS) begin
                        fse_off_norm[build_idx]  <= (off_freq[build_idx] == 0) ? 16'd0 : (off_freq[build_idx] << FSE_MAX_TB) / (total_off + 1);
                        fse_off_table[build_idx] <= (off_freq[build_idx] == 0) ? 8'hFF : (FSE_MAX_TB << 3) - ((off_freq[build_idx] >= (total_off >> 4)) ? 8'd32 : (off_freq[build_idx] >= (total_off >> 8)) ? 8'd16 : 8'd8);
                    end

                    if (build_idx < LIT_SYMS) begin
                        if (lit_freq[build_idx] == 0) begin
                            huf_lit_nb  [build_idx] <= 8'd0;
                            huf_lit_code[build_idx] <= 16'd0;
                            huf_lit_table[build_idx]<= 8'hFF;
                        end else begin
                            huf_lit_nb  [build_idx] <= bl_comb;
                            huf_lit_code[build_idx] <= {8'd0, build_idx};
                            huf_lit_table[build_idx]<= bl_comb << 3;
                        end
                    end

                    build_idx <= build_idx + 1;
                    if (build_idx == LIT_SYMS - 1) begin
                        p1_state   <= P1_DONE;
                        pass2_done <= 1'b1;
                    end
                end

                P1_DONE: begin
                    pass2_done <= 1'b0;
                    p1_state   <= P1_IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
