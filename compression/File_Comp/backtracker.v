`default_nettype none
`timescale 1ns/1ps

module backtracker #(
    parameter POS_W    = 18,
    parameter OFFSET_W = 23,
    parameter ML_W     = 8,
    parameter LIT_W    = 8,
    parameter SEQ_BUF  = 131072,
    parameter LIT_BUF  = 131072
)( 
    input  wire              clk,
    input  wire              rst_n,
    input  wire              bt_start,
    input  wire              bt_replay, 
    input  wire [POS_W-1:0]  bt_len,
    output reg  [POS_W-1:0]  dp_rd_addr,
    input  wire [OFFSET_W-1:0] dp_offset,
    input  wire [ML_W-1:0]     dp_length,
    input  wire              dp_is_match,
    output reg  [POS_W-1:0]  src_rd_addr,
    input  wire [7:0]        src_byte,
    output reg  [ML_W-1:0]     seq_lit_len,
    output reg  [ML_W-1:0]     seq_match_len,
    output reg  [OFFSET_W-1:0] seq_offset,
    output reg                 seq_valid,
    input  wire              seq_ready,
    output reg  [7:0]          lit_byte,
    output reg                 lit_valid,
    input  wire              lit_ready,
    output reg                 done
);
    reg [POS_W-1:0]    sbuf_ll  [0:SEQ_BUF-1];
    reg [ML_W-1:0]     sbuf_ml  [0:SEQ_BUF-1];
    reg [OFFSET_W-1:0] sbuf_off [0:SEQ_BUF-1];
    reg [$clog2(SEQ_BUF):0] sbuf_wr;
    reg [$clog2(SEQ_BUF):0] sbuf_rd;

    reg [7:0]      lbuf [0:LIT_BUF-1];
    reg [POS_W:0]  lbuf_wr;
    reg [POS_W:0]  lbuf_rd;

    integer idx_init;
    initial begin
        for (idx_init = 0; idx_init < SEQ_BUF; idx_init = idx_init + 1) begin
            sbuf_ll[idx_init] = '0;
            sbuf_ml[idx_init] = '0;
            sbuf_off[idx_init] = '0;
        end
        for (idx_init = 0; idx_init < LIT_BUF; idx_init = idx_init + 1) begin
            lbuf[idx_init] = 8'd0;
        end
    end

    localparam IDLE      = 3'd0,
               BT_WALK   = 3'd1,
               BT_LIT    = 3'd2,
               EMIT_SEQ  = 3'd3,
               EMIT_LIT  = 3'd4,
               FINISH    = 3'd5;
    reg [2:0] state;

    reg [POS_W-1:0] cur_pos;
    reg [POS_W-1:0] pending_lits;

    reg              rd_pending;
    reg [OFFSET_W-1:0] rd_offset_r;
    reg [ML_W-1:0]   rd_length_r;
    reg              rd_is_match_r;
    reg [$clog2(SEQ_BUF)-1:0] fwd_idx;
    reg [$clog2(SEQ_BUF):0]   fwd_idx_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            done          <= 1'b0;
            seq_valid     <= 1'b0;
            lit_valid     <= 1'b0;
            sbuf_wr       <= '0;
            sbuf_rd       <= '0;
            lbuf_wr       <= '0;
            lbuf_rd       <= '0;
            rd_pending    <= 1'b0;
            dp_rd_addr    <= '0;
            src_rd_addr   <= '0;
            cur_pos       <= '0;
            pending_lits  <= '0;
        end else begin
            done      <= 1'b0;
            seq_valid <= 1'b0;
            lit_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (bt_start) begin
                        cur_pos      <= bt_len - 1;
                        pending_lits <= '0;
                        sbuf_wr      <= '0;
                        sbuf_rd      <= '0;
                        lbuf_wr      <= '0;
                        lbuf_rd      <= '0;
                        rd_pending   <= 1'b0;
                        dp_rd_addr   <= bt_len - 1;
                        rd_pending   <= 1'b1;
                        state        <= BT_WALK;
                    end else if (bt_replay) begin
                        sbuf_rd <= '0;
                        lbuf_rd <= lbuf_wr;
                        state   <= EMIT_SEQ;
                    end
                end

                BT_WALK: begin
                    if (rd_pending) begin
                        rd_offset_r   <= dp_offset;
                        rd_length_r   <= dp_length;
                        rd_is_match_r <= dp_is_match;
                        rd_pending    <= 1'b0;
                    end else begin
                        if (rd_is_match_r) begin
                            sbuf_ll [sbuf_wr[$clog2(SEQ_BUF)-1:0]] <= pending_lits;
                            sbuf_ml [sbuf_wr[$clog2(SEQ_BUF)-1:0]] <= rd_length_r;
                            sbuf_off[sbuf_wr[$clog2(SEQ_BUF)-1:0]] <= rd_offset_r;
                            sbuf_wr      <= sbuf_wr + 1;
                            pending_lits <= '0;
                            if (cur_pos < rd_length_r) begin
                                state <= EMIT_SEQ;
                            end else begin
                                cur_pos    <= cur_pos - rd_length_r;
                                dp_rd_addr <= cur_pos - rd_length_r;
                                rd_pending <= 1'b1;
                            end
                        end else begin
                            src_rd_addr <= cur_pos;
                            state       <= BT_LIT;
                        end
                    end
                end

                BT_LIT: begin
                    lbuf[lbuf_wr[POS_W-1:0]] <= src_byte;
                    lbuf_wr      <= lbuf_wr + 1;
                    pending_lits <= pending_lits + 1;
                    if (cur_pos == 0) begin
                        state <= EMIT_SEQ;
                    end else begin
                        cur_pos    <= cur_pos - 1;
                        dp_rd_addr <= cur_pos - 1;
                        rd_pending <= 1'b1;
                        state      <= BT_WALK;
                    end
                end

                EMIT_SEQ: begin
                    if (sbuf_rd == sbuf_wr) begin
                        lbuf_rd <= lbuf_wr;
                        state   <= EMIT_LIT;
                    end else if (seq_ready) begin
                        fwd_idx_full = sbuf_wr - 1 - sbuf_rd;
                        fwd_idx = fwd_idx_full[$clog2(SEQ_BUF)-1:0];
                        seq_lit_len   <= sbuf_ll [fwd_idx];
                        seq_match_len <= sbuf_ml [fwd_idx];
                        seq_offset    <= sbuf_off[fwd_idx];
                        seq_valid     <= 1'b1;
                        sbuf_rd       <= sbuf_rd + 1;
                    end
                end

                EMIT_LIT: begin
                    if (lbuf_rd == '0) begin
                        state <= FINISH;
                    end else if (lit_ready) begin
                        lbuf_rd  <= lbuf_rd - 1;
                        lit_byte  <= lbuf[lbuf_rd[POS_W-1:0] - 1];
                        lit_valid <= 1'b1;
                    end
                end

                FINISH: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
