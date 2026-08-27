`default_nettype none
`timescale 1ns/1ps

module zstd #(
    parameter WINDOW_LOG   = 16,
    parameter BLOCK_LOG    = 17,
    parameter OFFSET_W     = WINDOW_LOG,
    parameter POS_W        = BLOCK_LOG + 1,
    parameter N_BANKS      = 64,
    parameter CAM_ENTRIES  = 12,
    parameter N_WALKERS    = 64,
    parameter K_MATCHES    = 64,
    parameter MAX_MATCHES  = 16,
    parameter HASH_W       = 16,
    parameter N_HASHES     = 8,
    parameter ML_SYMS      = 53,
    parameter OFF_SYMS     = 32,
    parameter LIT_SYMS     = 256,
    parameter FSE_TB_LOG   = 8,
    parameter HUF_MAX_BL   = 11,
    parameter PRICE_W      = 16,
    parameter AXI_ADDR_W   = 64,
    parameter AXI_DATA_W   = 512,
    parameter AXI_ID_W     = 4
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    csr_start,
    input  wire [AXI_ADDR_W-1:0]   csr_src_addr,
    input  wire [AXI_ADDR_W-1:0]   csr_dst_addr,
    input  wire [31:0]             csr_src_len,
    output reg                     csr_done,
    output reg                     csr_busy,
    output reg  [31:0]             csr_comp_len,
    output reg  [31:0]             csr_ratio_x100,

    output wire [AXI_ID_W-1:0]     m_axi_r_arid,
    output wire [AXI_ADDR_W-1:0]   m_axi_r_araddr,
    output wire [7:0]              m_axi_r_arlen,
    output wire [2:0]              m_axi_r_arsize,
    output wire [1:0]              m_axi_r_arburst,
    output wire                    m_axi_r_arvalid,
    input  wire                    m_axi_r_arready,
    input  wire [AXI_ID_W-1:0]     m_axi_r_rid,
    input  wire [AXI_DATA_W-1:0]   m_axi_r_rdata,
    input  wire [1:0]              m_axi_r_rresp,
    input  wire                    m_axi_r_rlast,
    input  wire                    m_axi_r_rvalid,
    output wire                    m_axi_r_rready,

    output wire [AXI_ID_W-1:0]     m_axi_w_awid,
    output wire [AXI_ADDR_W-1:0]   m_axi_w_awaddr,
    output wire [7:0]              m_axi_w_awlen,
    output wire [2:0]              m_axi_w_awsize,
    output wire [1:0]              m_axi_w_awburst,
    output wire                    m_axi_w_awvalid,
    input  wire                    m_axi_w_awready,
    output wire [AXI_DATA_W-1:0]   m_axi_w_wdata,
    output wire [AXI_DATA_W/8-1:0] m_axi_w_wstrb,
    output wire                    m_axi_w_wlast,
    output wire                    m_axi_w_wvalid,
    input  wire                    m_axi_w_wready,
    input  wire [AXI_ID_W-1:0]     m_axi_w_bid,
    input  wire [1:0]              m_axi_w_bresp,
    input  wire                    m_axi_w_bvalid,
    output wire                    m_axi_w_bready
);
    wire [7:0]             in_byte;
    wire [POS_W-1:0]       in_pos;
    wire                   in_valid;
    wire                   in_ready;
    wire                   in_done;
    wire                   in_busy;
    wire [HASH_W-1:0]      hash_out      [0:N_HASHES-1];
    wire [POS_W-1:0]       hash_pos;
    wire                   hash_valid;
    wire [POS_W-1:0]       bloom_pos;
    wire                   bloom_maybe;
    wire                   bloom_valid;
    wire [POS_W-1:0]       cam_pos;
    wire [OFFSET_W-1:0]    cam_offsets   [0:MAX_MATCHES-1];
    wire [MAX_MATCHES-1:0] cam_valid_vec;
    wire [5:0]             cam_count;
    wire                   cam_result_valid;
    wire [OFFSET_W-1:0]    tw_offsets    [0:N_WALKERS-1];
    wire [7:0]             tw_lengths    [0:N_WALKERS-1];
    wire [N_WALKERS-1:0]   tw_valid_vec;
    wire [POS_W-1:0]       tw_pos;
    wire                   tw_valid_pulse;
    wire [7:0]             cur_window    [0:254];
    wire [OFFSET_W-1:0]    topk_offsets  [0:K_MATCHES-1];
    wire [7:0]             topk_lengths  [0:K_MATCHES-1];
    wire [K_MATCHES-1:0]   topk_valid;
    wire [POS_W-1:0]       topk_pos;
    wire                   topk_pulse;
    wire [7:0]             fse_ml_table  [0:255];
    wire [7:0]             fse_off_table [0:255];
    wire [7:0]             huf_lit_table [0:LIT_SYMS-1];
    wire [7:0]             huf_lit_nb    [0:LIT_SYMS-1];
    wire [15:0]            huf_lit_code  [0:LIT_SYMS-1];
    wire [15:0]            fse_ml_norm   [0:ML_SYMS-1];
    wire [15:0]            fse_off_norm  [0:OFF_SYMS-1];
    wire [PRICE_W-1:0]     price_out     [0:K_MATCHES];
    wire [OFFSET_W-1:0]    price_offsets [0:K_MATCHES-1];
    wire [7:0]             price_lengths [0:K_MATCHES-1];
    wire [K_MATCHES:0]     price_valid;
    wire [POS_W-1:0]       price_pos;
    wire                   price_pulse;
    wire                   bt_start_sig;
    wire [POS_W-1:0]       bt_len_sig;
    wire [POS_W-1:0]       bt_rd_addr;
    wire [OFFSET_W-1:0]    bt_offset;
    wire [7:0]             bt_length;
    wire                   bt_is_match;
    wire [POS_W-1:0]       bt_src_rd_addr;

    wire [7:0]             lit_byte_sig;
    wire [7:0]             lit_in_arr    [0:3];
    assign lit_in_arr[0] = lit_byte_sig;
    assign lit_in_arr[1] = 8'd0;
    assign lit_in_arr[2] = 8'd0;
    assign lit_in_arr[3] = 8'd0;
    wire [7:0]             seq_lit_len;
    wire [7:0]             seq_match_len;
    wire [OFFSET_W-1:0]    seq_offset;
    wire                   seq_valid_sig;
    wire                   seq_ready_sig;
    wire                   lit_valid_sig;
    wire                   lit_ready_sig;
    wire                   bt_done;
    wire                   stats_pass2_done;
    wire [127:0]           bs_data_sig;
    wire [6:0]             bs_bytes_sig;
    wire                   bs_valid_sig;
    wire                   bs_ready_sig;
    wire                   enc_done_sig;
    wire [POS_W-1:0]       comp_block_size;
    wire                   comp_block_done;
    wire                   out_done;
    reg                    block_start_r;
    reg                    block_compressed_r;
    reg                    block_last_r;
    reg [POS_W-1:0]        block_raw_len_r;
    reg                    frame_start_r;
    reg                    stats_pass1_start_r;
    reg                    enc_flush_r;
    reg                    block_end_r;
    reg                    bt_replay_r;
    reg [POS_W-1:0]        block_len_r;

    localparam [22:0] WINDOW_LOG_V = WINDOW_LOG[22:0];
    localparam TOP_IDLE=4'd0, TOP_INIT=4'd1, TOP_COMPRESS=4'd2,
               TOP_BT=4'd3,   TOP_STATS=4'd4, TOP_ENCODE=4'd5,
               TOP_FLUSH_ENC=4'd6, TOP_OUT=4'd7, TOP_DONE=4'd8;
    reg [3:0] top_state;

    wire pass2_active    = (top_state == TOP_ENCODE) || (top_state == TOP_FLUSH_ENC);
    wire enc_seq_ready_sig;
    wire enc_lit_ready_sig;
    assign seq_ready_sig = pass2_active ? enc_seq_ready_sig : 1'b1;
    assign lit_ready_sig = pass2_active ? enc_lit_ready_sig : 1'b1;
    wire enc_seq_valid   = seq_valid_sig & pass2_active;
    wire enc_lit_valid   = lit_valid_sig & pass2_active;
    (* ram_style = "block" *) reg [7:0] block_ram [0:262143];
    integer br_idx;
    initial begin
        for (br_idx = 0; br_idx < 262144; br_idx = br_idx + 1)
            block_ram[br_idx] = 8'd0;
    end
    always @(posedge clk) begin
        if (in_valid) block_ram[in_pos] <= in_byte;
    end
    wire [7:0] price_lit_byte = block_ram[topk_pos];
    wire [7:0] bt_src_byte    = block_ram[bt_src_rd_addr];
    reg [7:0] key_sr [0:2];
    always @(posedge clk) begin
        if (in_valid) begin
            key_sr[0] <= in_byte;
            key_sr[1] <= key_sr[0];
            key_sr[2] <= key_sr[1];
        end
    end
    wire [31:0] insert_key_4g = {key_sr[2], key_sr[1], key_sr[0], in_byte};
    reg [31:0] qk_pipe [0:3];
    always @(posedge clk) begin
        qk_pipe[0] <= insert_key_4g;
        qk_pipe[1] <= qk_pipe[0];
        qk_pipe[2] <= qk_pipe[1];
        qk_pipe[3] <= qk_pipe[2];
    end
    wire [31:0] query_key = qk_pipe[3];
    input_subsystem #(
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
        .AXI_ID_W(AXI_ID_W),     .MAX_BLOCK_LG(BLOCK_LOG)
    ) u_input (
        .clk(clk), .rst_n(rst_n), .start(csr_start),
        .src_addr(csr_src_addr), .src_len(csr_src_len[BLOCK_LOG:0]),
        .done(in_done), .busy(in_busy),
        .axi_arid(m_axi_r_arid),     .axi_araddr(m_axi_r_araddr),
        .axi_arlen(m_axi_r_arlen),   .axi_arsize(m_axi_r_arsize),
        .axi_arburst(m_axi_r_arburst),.axi_arvalid(m_axi_r_arvalid),
        .axi_arready(m_axi_r_arready),.axi_rid(m_axi_r_rid),
        .axi_rdata(m_axi_r_rdata),   .axi_rresp(m_axi_r_rresp),
        .axi_rlast(m_axi_r_rlast),   .axi_rvalid(m_axi_r_rvalid),
        .axi_rready(m_axi_r_rready),
        .out_byte(in_byte), .out_pos(in_pos),
        .out_valid(in_valid), .out_ready(in_ready)
    );
    assign in_ready = 1'b1;

    rolling_hash_gen #(.HASH_W(HASH_W),.POS_W(POS_W),.N_HASHES(N_HASHES))
    u_hash (
        .clk(clk),.rst_n(rst_n),
        .in_byte(in_byte),.in_pos(in_pos),.in_valid(in_valid),
        .hash_out(hash_out),.hash_pos(hash_pos),.hash_valid(hash_valid)
    );
    bloom_filter #(.HASH_W(HASH_W),.POS_W(POS_W),.N_HASH(N_HASHES))
    u_bloom (
        .clk(clk),.rst_n(rst_n),
        .hash_in(hash_out),.hash_pos(hash_pos),.hash_valid(hash_valid),
        .out_pos(bloom_pos),.out_maybe_match(bloom_maybe),.out_valid(bloom_valid),
        .wr_en(hash_valid),.wr_hash(hash_out)
    );
    cam_array #(
        .N_BANKS(N_BANKS),      .ENTRIES_LOG(CAM_ENTRIES),
        .KEY_W(32),             .OFFSET_W(OFFSET_W),
        .POS_W(POS_W),          .HASH_W(HASH_W),
        .N_HASHES(N_HASHES),    .MAX_MATCHES(MAX_MATCHES)
    ) u_cam (
        .clk(clk),.rst_n(rst_n),
        .query_pos(bloom_pos),       .query_key(query_key),
        .query_hash(hash_out),       .query_valid(bloom_valid),
        .match_pos(cam_pos),         .match_offsets(cam_offsets),
        .match_valid_vec(cam_valid_vec),.match_count(cam_count),
        .result_valid(cam_result_valid),
        .insert_en(in_valid),        .insert_pos(in_pos),
        .insert_key(insert_key_4g),  
        .insert_hash(hash_out)    
    );
    genvar gw;
    generate
        for (gw = 0; gw < 255; gw = gw + 1)
            assign cur_window[gw] = 8'd0;
    endgenerate

    tree_walkers #(
        .N_WALKERS(N_WALKERS), .MAX_MATCHES(MAX_MATCHES),
        .OFFSET_W(OFFSET_W),   .POS_W(POS_W),
        .MAX_ML(255),          .ML_W(8),
        .WIN_SIZE(1 << WINDOW_LOG)    
    ) u_walkers (
        .clk(clk),.rst_n(rst_n),
        .hist_wr_byte(in_byte),
        .hist_wr_addr(in_pos[OFFSET_W-1:0]),
        .hist_wr_en(in_valid),
        .cam_pos(cam_pos),       .cam_offsets(cam_offsets),
        .cam_valid_vec(cam_valid_vec),.cam_count(cam_count),
        .cam_valid(cam_result_valid), .cur_window(cur_window),
        .ext_offsets(tw_offsets),    .ext_lengths(tw_lengths),
        .ext_valid_vec(tw_valid_vec),.ext_pos(tw_pos),
        .ext_valid(tw_valid_pulse)
    );
    topk_heap #(
        .N_IN(N_WALKERS),.K(K_MATCHES),
        .OFFSET_W(OFFSET_W),.ML_W(8),.POS_W(POS_W)
    ) u_topk (
        .clk(clk),.rst_n(rst_n),
        .in_offsets(tw_offsets),    .in_lengths(tw_lengths),
        .in_valid(tw_valid_vec),    .in_pos(tw_pos),
        .in_valid_pulse(tw_valid_pulse),
        .out_offsets(topk_offsets), .out_lengths(topk_lengths),
        .out_valid(topk_valid),     .out_pos(topk_pos),
        .out_valid_pulse(topk_pulse)
    );

    price_calculator #(
        .K(K_MATCHES),.OFFSET_W(OFFSET_W),.ML_W(8),.POS_W(POS_W),.PRICE_W(PRICE_W)
    ) u_price (
        .clk(clk),.rst_n(rst_n),
        .in_offsets(topk_offsets),  .in_lengths(topk_lengths),
        .in_valid(topk_valid),      .in_pos(topk_pos),
        .in_pulse(topk_pulse),      .lit_byte(price_lit_byte),
        .fse_ml_table(fse_ml_table),.fse_off_table(fse_off_table),
        .huf_lit_table(huf_lit_table),
        .out_prices(price_out),   
        .out_offsets(price_offsets),
        .out_lengths(price_lengths),.out_valid(price_valid),
        .out_pos(price_pos),        .out_pulse(price_pulse)
    );
    dp_engine #(
        .K(K_MATCHES),.PRICE_W(PRICE_W),.OFFSET_W(OFFSET_W),.ML_W(8),.POS_W(POS_W)
    ) u_dp (
        .clk(clk),.rst_n(rst_n),
        .block_start(block_start_r),
        .block_len(block_len_r),
        .price_in(price_out),        .off_in(price_offsets),
        .len_in(price_lengths),      .valid_in(price_valid),
        .pos_in(price_pos),          
        .price_pulse(price_pulse),
        .bt_start(bt_start_sig),     .bt_len(bt_len_sig),
        .bt_rd_addr(bt_rd_addr),     .bt_offset(bt_offset),
        .bt_length(bt_length),       .bt_is_match(bt_is_match)
    );
    backtracker #(.POS_W(POS_W),.OFFSET_W(OFFSET_W),.ML_W(8),.LIT_W(8))
    u_bt (
        .clk(clk),.rst_n(rst_n),
        .bt_start(bt_start_sig),      .bt_replay(bt_replay_r),
        .bt_len(bt_len_sig),          .dp_rd_addr(bt_rd_addr),
        .dp_offset(bt_offset),        .dp_length(bt_length),
        .dp_is_match(bt_is_match),    .src_rd_addr(bt_src_rd_addr),
        .src_byte(bt_src_byte),       .seq_lit_len(seq_lit_len),
        .seq_match_len(seq_match_len),.seq_offset(seq_offset),
        .seq_valid(seq_valid_sig),    .seq_ready(seq_ready_sig),
        .lit_byte(lit_byte_sig),      .lit_valid(lit_valid_sig),
        .lit_ready(lit_ready_sig),    .done(bt_done)
    );
    stats_collector #(
        .ML_SYMS(ML_SYMS),.OFF_SYMS(OFF_SYMS),.LIT_SYMS(LIT_SYMS),
        .FSE_MAX_TB(FSE_TB_LOG),.HUF_MAX_BL(HUF_MAX_BL)
    ) u_stats (
        .clk(clk),.rst_n(rst_n),
        .pass1_start(stats_pass1_start_r),.pass1_done_in(bt_done),
        .pass2_done(stats_pass2_done),
        .ml_sym(seq_match_len),   .off_sym(seq_offset[4:0]),
        .seq_valid(seq_valid_sig),.lit_byte(lit_byte_sig),
        .lit_valid(lit_valid_sig),
        .fse_ml_table(fse_ml_table),.fse_off_table(fse_off_table),
        .huf_lit_nb(huf_lit_nb),   
        .huf_lit_code(huf_lit_code),
        .huf_lit_table(huf_lit_table),
        .fse_ml_norm(fse_ml_norm), .fse_off_norm(fse_off_norm)
    );
    entropy_encoder #(
        .ML_SYMS(ML_SYMS),.OFF_SYMS(OFF_SYMS),.LIT_SYMS(LIT_SYMS),
        .FSE_TB_LOG(FSE_TB_LOG),.HUF_MAX_BL(HUF_MAX_BL),.POS_W(POS_W)
    ) u_entropy (
        .clk(clk),.rst_n(rst_n),
        .enc_start(stats_pass2_done),.enc_flush(enc_flush_r),
        .huf_lit_nb(huf_lit_nb),     .huf_lit_code(huf_lit_code),
        .fse_ml_norm(fse_ml_norm),   .fse_off_norm(fse_off_norm),
        .lit_in(lit_in_arr),
        .lit_valid({3'b000, enc_lit_valid}), .lit_ready(enc_lit_ready_sig),
        .seq_ml(seq_match_len),
        .seq_off_sym(seq_offset[4:0]),       .seq_off_raw({{(23-OFFSET_W){1'b0}}, seq_offset}),
        .seq_valid(enc_seq_valid),           .seq_ready(enc_seq_ready_sig),
        .enc_done(enc_done_sig),
        .bs_data(bs_data_sig),.bs_bytes(bs_bytes_sig),
        .bs_valid(bs_valid_sig),.bs_ready(bs_ready_sig)
    );
    output_subsystem #(
        .AXI_ADDR_W(AXI_ADDR_W),.AXI_DATA_W(AXI_DATA_W),
        .AXI_ID_W(AXI_ID_W),.POS_W(POS_W)
    ) u_output (
        .clk(clk),.rst_n(rst_n),
        .frame_start(frame_start_r),      .dst_addr(csr_dst_addr),
        .content_size(csr_src_len),       .window_size_log(WINDOW_LOG_V),
        .block_start(block_start_r),      .block_compressed(block_compressed_r),
        .block_last(block_last_r),        .block_raw_len(block_raw_len_r),
        .block_end(block_end_r),
        .bs_data(bs_data_sig),  .bs_bytes(bs_bytes_sig),
        .bs_valid(bs_valid_sig),.bs_ready(bs_ready_sig),
        .raw_byte(in_byte),.raw_valid(1'b0),.raw_ready(),
        .comp_block_size(comp_block_size),.comp_block_done(comp_block_done),
        .axi_awid(m_axi_w_awid),    .axi_awaddr(m_axi_w_awaddr),
        .axi_awlen(m_axi_w_awlen),  .axi_awsize(m_axi_w_awsize),
        .axi_awburst(m_axi_w_awburst),.axi_awvalid(m_axi_w_awvalid),
        .axi_awready(m_axi_w_awready),.axi_wdata(m_axi_w_wdata),
        .axi_wstrb(m_axi_w_wstrb),  .axi_wlast(m_axi_w_wlast),
        .axi_wvalid(m_axi_w_wvalid),.axi_wready(m_axi_w_wready),
        .axi_bid(m_axi_w_bid),      .axi_bresp(m_axi_w_bresp),
        .axi_bvalid(m_axi_w_bvalid),.axi_bready(m_axi_w_bready),
        .done(out_done)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state          <= TOP_IDLE;
            csr_done           <= 1'b0;
            csr_busy           <= 1'b0;
            csr_comp_len       <= 32'd0;
            csr_ratio_x100     <= 32'd0;
            frame_start_r      <= 1'b0;
            block_start_r      <= 1'b0;
            block_compressed_r <= 1'b1;
            block_last_r       <= 1'b1;
            block_raw_len_r    <= {POS_W{1'b0}};
            stats_pass1_start_r<= 1'b0;
            enc_flush_r        <= 1'b0;
            block_end_r        <= 1'b0;
            bt_replay_r        <= 1'b0;
            block_len_r        <= {POS_W{1'b0}};
        end else begin
            csr_done           <= 1'b0;
            frame_start_r      <= 1'b0;
            block_start_r      <= 1'b0;
            stats_pass1_start_r<= 1'b0;
            block_end_r        <= 1'b0;
            bt_replay_r        <= 1'b0;
            case (top_state)
                TOP_IDLE:     if (csr_start) begin
                                  csr_busy      <= 1'b1;
                                  frame_start_r <= 1'b1;
                                  top_state     <= TOP_INIT;
                               end
                TOP_INIT:     if (in_busy) begin
                                  block_start_r      <= 1'b1;
                                  block_compressed_r <= 1'b1;
                                  block_last_r       <= 1'b1;
                                  stats_pass1_start_r<= 1'b1;
                                  block_len_r        <= (csr_src_len[31:BLOCK_LOG] != {(32-BLOCK_LOG){1'b0}}) ? {{1'b0}, {(BLOCK_LOG){1'b1}}} : csr_src_len[POS_W-1:0];
                                  top_state          <= TOP_COMPRESS;
                               end
                TOP_COMPRESS: if (bt_start_sig) top_state <= TOP_BT;
                TOP_BT:       if (bt_done)      top_state <= TOP_STATS;
                TOP_STATS:    if (stats_pass2_done) begin
                                  bt_replay_r <= 1'b1;
                                  top_state   <= TOP_ENCODE;
                              end
                TOP_ENCODE:   if (bt_done) begin
                                  enc_flush_r <= 1'b1;
                                  top_state   <= TOP_FLUSH_ENC;
                              end
                TOP_FLUSH_ENC: begin
                                  if (enc_done_sig) begin
                                      enc_flush_r <= 1'b0;
                                      block_end_r <= 1'b1;
                                      top_state   <= TOP_OUT;
                                  end else begin
                                      enc_flush_r <= 1'b1;
                                  end
                               end
                TOP_OUT:      if (comp_block_done) begin
                                  csr_comp_len   <= {14'd0, comp_block_size};
                                  csr_ratio_x100 <= ({32'd0, csr_src_len} * 64'd100) / ({14'd0, comp_block_size} + 1);
                                  top_state      <= TOP_DONE;
                              end
                TOP_DONE:     begin
                                  csr_done  <= 1'b1;
                                  csr_busy  <= 1'b0;
                                  top_state <= TOP_IDLE;
                              end
            endcase
        end
    end

endmodule
`default_nettype wire
