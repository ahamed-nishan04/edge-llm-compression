`default_nettype none
`timescale 1ns/1ps

module entropy_encoder #(
    parameter ML_SYMS    = 53,
    parameter OFF_SYMS   = 32,
    parameter LIT_SYMS   = 256,
    parameter FSE_TB_LOG = 8,
    parameter HUF_MAX_BL = 11,
    parameter POS_W      = 18
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              enc_start,
    input  wire              enc_flush,
    output reg               enc_done,
    input  wire [7:0]        huf_lit_nb   [0:LIT_SYMS-1],
    input  wire [15:0]       huf_lit_code [0:LIT_SYMS-1],
    input  wire [15:0]       fse_ml_norm  [0:ML_SYMS-1],
    input  wire [15:0]       fse_off_norm [0:OFF_SYMS-1],
    input  wire [7:0]        lit_in [0:3],
    input  wire [3:0]        lit_valid,
    output reg               lit_ready,
    input  wire [7:0]        seq_ml,
    input  wire [4:0]        seq_off_sym,
    input  wire [22:0]       seq_off_raw,
    input  wire              seq_valid,
    output reg               seq_ready,
    output reg  [127:0]      bs_data,
    output reg  [6:0]        bs_bytes,
    output reg               bs_valid,
    input  wire              bs_ready
);
    reg [255:0] huf_bits;
    reg [8:0]   huf_bit_cnt;

    reg [FSE_TB_LOG-1:0] fse_ml_state,  fse_off_state;
    reg [31:0]           fse_acc;
    reg [5:0]            fse_acc_cnt;

    reg [255:0] merge_buf;
    reg [8:0]   merge_cnt;

    reg [13:0] fse_ml_enc_table  [0:(1<<FSE_TB_LOG)-1];
    reg [13:0] fse_off_enc_table [0:(1<<FSE_TB_LOG)-1];
    integer tbl_idx;
    initial begin
        for (tbl_idx = 0; tbl_idx < (1<<FSE_TB_LOG); tbl_idx = tbl_idx + 1) begin
            fse_ml_enc_table[tbl_idx] = 14'd0;
            fse_off_enc_table[tbl_idx] = 14'd0;
        end
    end

    wire [10:0] sym_bits [0:3];
    wire [10:0] sym_code [0:3];
    genvar g;
    generate
        for (g = 0; g < 4; g = g+1) begin : huf_par
            assign sym_bits[g] = lit_valid[g] ? {3'd0, huf_lit_nb  [lit_in[g]]} : 11'd0;
            assign sym_code[g] = lit_valid[g] ? huf_lit_code[lit_in[g]][10:0]   : 11'd0;
        end
    endgenerate

    wire [6:0] huf_total = sym_bits[0] + sym_bits[1] + sym_bits[2] + sym_bits[3];
    wire [255:0] huf_group =
        ({245'd0, sym_code[0]} << (255 - sym_bits[0] + 1))
      |
        ({245'd0, sym_code[1]} << (255 - sym_bits[0] - sym_bits[1] + 1))
      |
        ({245'd0, sym_code[2]} << (sym_bits[3]))
      | {245'd0, sym_code[3]};
    wire [255:0] huf_group_shifted = huf_group >> (256 - huf_total - huf_bit_cnt);

    wire [8:0]  fse_ml_next_st  = fse_ml_enc_table [fse_ml_state ][13:5];
    wire [4:0]  fse_ml_nb       = fse_ml_enc_table [fse_ml_state ][4:0];
    wire [8:0]  fse_off_next_st = fse_off_enc_table[fse_off_state][13:5];
    wire [4:0]  fse_off_nb      = fse_off_enc_table[fse_off_state][4:0];
    wire [22:0] off_extra_bits = seq_off_raw & ((23'd1 << seq_off_sym) - 23'd1);
    wire [7:0]  ml_state_bits  = {{(8-FSE_TB_LOG){1'b0}}, fse_ml_state} & ((8'd1 << fse_ml_nb) - 8'd1);
    wire [7:0]  off_state_bits = {{(8-FSE_TB_LOG){1'b0}}, fse_off_state} & ((8'd1 << fse_off_nb) - 8'd1);
    wire [6:0] fse_total = {2'd0, seq_off_sym} + {2'd0, fse_ml_nb} + {2'd0, fse_off_nb};
    wire [31:0] fse_pack =
        ({9'd0, off_extra_bits} << (fse_ml_nb + fse_off_nb))
      |
        ({24'd0, ml_state_bits} << fse_off_nb)
      | {24'd0, off_state_bits};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            huf_bits      <= '0;
            huf_bit_cnt   <= 9'd0;
            lit_ready     <= 1'b0;
            fse_ml_state  <= '0;
            fse_off_state <= '0;
            fse_acc       <= '0;
            fse_acc_cnt   <= 6'd0;
            seq_ready     <= 1'b1;
            merge_buf     <= '0;
            merge_cnt     <= 9'd0;
            bs_valid      <= 1'b0;
            enc_done      <= 1'b0;
            bs_data       <= '0;
            bs_bytes      <= 7'd0;
        end else begin
            bs_valid <= 1'b0;
            enc_done <= 1'b0;

            begin : monolithic_update
                reg [255:0] next_huf_bits;
                reg [8:0]   next_huf_bit_cnt;
                reg [31:0]  next_fse_acc;
                reg [5:0]   next_fse_acc_cnt;
                reg [255:0] next_merge_buf;
                reg [8:0]   next_merge_cnt;

                next_huf_bits    = huf_bits;
                next_huf_bit_cnt = huf_bit_cnt;
                next_fse_acc     = fse_acc;
                next_fse_acc_cnt = fse_acc_cnt;
                next_merge_buf   = merge_buf;
                next_merge_cnt   = merge_cnt;

                if (lit_valid != 4'b0 && lit_ready) begin
                    next_huf_bits    = next_huf_bits | huf_group_shifted;
                    next_huf_bit_cnt = next_huf_bit_cnt + {2'd0, huf_total};
                end

                if (seq_valid && seq_ready) begin
                    fse_ml_state  <= fse_ml_next_st [FSE_TB_LOG-1:0];
                    fse_off_state <= fse_off_next_st[FSE_TB_LOG-1:0];
                    next_fse_acc     = (next_fse_acc << fse_total) | fse_pack;
                    next_fse_acc_cnt = next_fse_acc_cnt + {1'd0, fse_total};
                end

                if (next_huf_bit_cnt >= 9'd64) begin
                    next_merge_buf   = (next_merge_buf << 64) | {192'd0, next_huf_bits[255:192]};
                    next_huf_bits    = next_huf_bits << 64;
                    next_huf_bit_cnt = next_huf_bit_cnt - 9'd64;
                    next_merge_cnt   = next_merge_cnt + 9'd64;
                end else if (next_fse_acc_cnt >= 6'd32) begin
                    next_merge_buf   = (next_merge_buf << 32) | {224'd0, next_fse_acc[31:0]};
                    next_fse_acc     = '0;
                    next_fse_acc_cnt = 6'd0;
                    next_merge_cnt   = next_merge_cnt + 9'd32;
                end

                if (next_merge_cnt >= 9'd128 && bs_ready) begin
                    bs_data        <= next_merge_buf[255:128];
                    bs_bytes       <= 7'd16;
                    bs_valid       <= 1'b1;
                    next_merge_buf = next_merge_buf << 128;
                    next_merge_cnt = next_merge_cnt - 9'd128;
                end

                if (enc_flush) begin
                    if (next_fse_acc_cnt > 0) begin
                        next_merge_buf = (next_merge_buf << next_fse_acc_cnt) | ({224'd0, next_fse_acc} >> (32 - next_fse_acc_cnt));
                        next_merge_cnt   = next_merge_cnt + {3'd0, next_fse_acc_cnt};
                        next_fse_acc     = '0;
                        next_fse_acc_cnt = 6'd0;
                    end

                    if (next_merge_cnt > 0) begin
                        bs_data        <= next_merge_buf[255:128];
                        bs_bytes       <= next_merge_cnt[8:3] + (|next_merge_cnt[2:0] ? 7'd1 : 7'd0);
                        bs_valid       <= 1'b1;
                        next_merge_buf = '0;
                        next_merge_cnt = 9'd0;
                    end
                    enc_done <= 1'b1;
                end

                huf_bits    <= next_huf_bits;
                huf_bit_cnt <= next_huf_bit_cnt;
                fse_acc     <= next_fse_acc;
                fse_acc_cnt <= next_fse_acc_cnt;
                merge_buf   <= next_merge_buf;
                merge_cnt   <= next_merge_cnt;
                lit_ready   <= (next_huf_bit_cnt < 9'd128);
                seq_ready   <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
