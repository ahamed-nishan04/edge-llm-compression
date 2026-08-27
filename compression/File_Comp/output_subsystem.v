`default_nettype none
`timescale 1ns/1ps

module output_subsystem #(
    parameter AXI_ADDR_W = 64,
    parameter AXI_DATA_W = 512,
    parameter AXI_ID_W   = 4,
    parameter BUF_DEPTH  = 256,
    parameter POS_W      = 18
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     frame_start,
    input  wire [AXI_ADDR_W-1:0]    dst_addr,
    input  wire [31:0]              content_size,
    input  wire [22:0]              window_size_log,
    input  wire                     block_start,
    input  wire                     block_end,
    input  wire                     block_compressed,
    input  wire                     block_last,
    input  wire  [POS_W-1:0]         block_raw_len,
    input  wire [127:0]             bs_data,
    input  wire [6:0]               bs_bytes,
    input  wire                     bs_valid,
    output reg                      bs_ready,
    input  wire [7:0]               raw_byte,
    input  wire                     raw_valid,
    output reg                      raw_ready,
    output reg  [POS_W-1:0]         comp_block_size,
    output reg                      comp_block_done,
    output reg  [AXI_ID_W-1:0]      axi_awid,
    output reg  [AXI_ADDR_W-1:0]    axi_awaddr,
    output reg  [7:0]               axi_awlen,
    output reg  [2:0]               axi_awsize,
    output reg  [1:0]               axi_awburst,
    output reg                      axi_awvalid,
    input  wire                     axi_awready,
    output reg  [AXI_DATA_W-1:0]    axi_wdata,
    output reg  [AXI_DATA_W/8-1:0]  axi_wstrb,
    output reg                      axi_wlast,
    output reg                      axi_wvalid,
    input  wire                     axi_wready,
    input  wire [AXI_ID_W-1:0]      axi_bid,
    input  wire [1:0]                axi_bresp,
    input  wire                     axi_bvalid,
    output reg                      axi_bready,
    output reg                      done
);
    reg [7:0] hdr_bytes [0:13];
    reg [3:0] hdr_len;
    reg [3:0] hdr_ptr;
    reg       hdr_done;
    reg [AXI_DATA_W-1:0]      wbuf [0:BUF_DEPTH-1];
    reg [$clog2(BUF_DEPTH):0] wbuf_wr, wbuf_rd;
    wire wbuf_full  = (wbuf_wr - wbuf_rd) == BUF_DEPTH;
    wire wbuf_empty = (wbuf_wr == wbuf_rd);

    reg [AXI_DATA_W-1:0] pack_beat;
    reg [5:0]            pack_ptr;
    reg [POS_W-1:0]      bytes_out;

    localparam IDLE=4'd0, FRAME_HDR=4'd1, BLK_HDR=4'd2,
               WRITE_BS=4'd5, WRITE_RAW=4'd6,
               FLUSH=4'd7, DMA_ADDR=4'd8, DMA_DATA=4'd9, DONE=4'd10;
    reg [3:0] state;
    reg [3:0] saved_write_state;

    reg [AXI_ADDR_W-1:0] wr_addr;
    reg [POS_W:0]        wr_bytes_left;
    wire [8:0] avail_beats = wbuf_wr - wbuf_rd;
    wire [7:0] burst_len   = (avail_beats > 9'd256) ? 8'd255 : avail_beats[7:0] - 8'd1;

    task build_frame_header;
        begin
            hdr_bytes[0] <= 8'h28;
            hdr_bytes[1] <= 8'hB5;
            hdr_bytes[2] <= 8'h2F;
            hdr_bytes[3] <= 8'hFD;
            hdr_bytes[4] <= 8'b10_0_0_00_00;
            hdr_bytes[5] <= {5'd0, window_size_log[2:0]};
            hdr_bytes[6] <= content_size[7:0];
            hdr_bytes[7] <= content_size[15:8];
            hdr_bytes[8] <= content_size[23:16];
            hdr_bytes[9] <= content_size[31:24];
            hdr_len      <= 4'd10;
        end
    endtask

    reg        pack_en;
    reg [7:0]  pack_in;
    reg pending_block_start;
    reg [127:0] bs_shift_buf;
    reg [6:0]   bs_shift_cnt;
    reg         bs_draining;
    reg         block_end_seen;
    wire [AXI_DATA_W-1:0] pack_beat_next;
    assign pack_beat_next = pack_beat | ({504'd0, pack_in} << (pack_ptr * 8));

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= IDLE;
            done              <= 1'b0;
            hdr_done          <= 1'b0;
            pack_ptr          <= 6'd0;
            pack_beat         <= '0;
            bytes_out         <= '0;
            wbuf_wr           <= '0;
            wbuf_rd           <= '0;
            wr_addr           <= '0;
            axi_awvalid       <= 1'b0;
            axi_wvalid        <= 1'b0;
            axi_wlast         <= 1'b0;
            axi_bready        <= 1'b0;
            bs_ready          <= 1'b0;
            raw_ready         <= 1'b0;
            comp_block_done   <= 1'b0;
            wr_bytes_left     <= '0;
            saved_write_state <= IDLE;
            pack_en           <= 1'b0;
            pack_in           <= 8'd0;
            pending_block_start <= 1'b0;
            bs_shift_buf      <= '0;
            bs_shift_cnt      <= 7'd0;
            bs_draining       <= 1'b0;
            block_end_seen    <= 1'b0;
        end else begin
            done            <= 1'b0;
            comp_block_done <= 1'b0;
            pack_en         <= 1'b0;

            if (block_start) pending_block_start <= 1'b1;
            if (pack_en && !wbuf_full) begin
                bytes_out <= bytes_out + 1;
                if (pack_ptr == 6'd63) begin
                    wbuf[wbuf_wr[$clog2(BUF_DEPTH)-1:0]] <= pack_beat_next;
                    wbuf_wr   <= wbuf_wr + 1;
                    pack_ptr  <= 6'd0;
                    pack_beat <= '0;
                end else begin
                    pack_beat <= pack_beat_next;
                    pack_ptr  <= pack_ptr + 1;
                end
            end

            case (state)
                IDLE: begin
                    if (frame_start) begin
                        build_frame_header();
                        hdr_ptr   <= 4'd0;
                        wr_addr   <= dst_addr;
                        bytes_out <= '0;
                        state     <= FRAME_HDR;
                    end else if (pending_block_start && hdr_done) begin
                        state <= BLK_HDR;
                        pending_block_start <= 1'b0;
                    end
                end

                FRAME_HDR: begin
                    if (hdr_ptr < hdr_len) begin
                        pack_en  <= 1'b1;
                        pack_in  <= hdr_bytes[hdr_ptr];
                        hdr_ptr  <= hdr_ptr + 1;
                    end else begin
                        hdr_done <= 1'b1;
                        state    <= IDLE;
                    end
                end

                BLK_HDR: begin
                    pack_en <= 1'b1;
                    pack_in <= {5'd0, block_last, block_compressed ? 2'b10 : 2'b00};
                    state     <= block_compressed ? WRITE_BS : WRITE_RAW;
                    bs_ready  <=  block_compressed;
                    raw_ready <= !block_compressed;
                    saved_write_state <= block_compressed ? WRITE_BS : WRITE_RAW;
                end

                WRITE_BS: begin
                    if (block_end) block_end_seen <= 1'b1;
                    if (bs_valid && bs_ready && !bs_draining) begin
                        bs_shift_buf <= bs_data;
                        bs_shift_cnt <= bs_bytes;
                        bs_draining  <= 1'b1;
                        bs_ready     <= 1'b0;
                    end

                    if (bs_draining && !wbuf_full) begin
                        pack_en      <= 1'b1;
                        pack_in      <= bs_shift_buf[7:0];
                        bs_shift_buf <= {8'd0, bs_shift_buf[127:8]};
                        bs_shift_cnt <= bs_shift_cnt - 7'd1;
                        if (bs_shift_cnt == 7'd1) begin
                            bs_draining <= 1'b0;
                            if (block_end || block_end_seen) begin
                                block_end_seen <= 1'b0;
                                state <= FLUSH;
                            end else begin
                                bs_ready <= 1'b1;
                            end
                        end
                    end

                    if ((block_end || block_end_seen) && !bs_draining) begin
                        bs_ready       <= 1'b0;
                        block_end_seen <= 1'b0;
                        state          <= FLUSH;
                    end else if (!bs_draining && !block_end_seen && avail_beats >= 4) begin
                        bs_ready <= 1'b0;
                        state <= DMA_ADDR;
                    end
                end

                WRITE_RAW: begin
                    if (raw_valid && raw_ready && !wbuf_full) begin
                        pack_en <= 1'b1;
                        pack_in <= raw_byte;
                    end
                    if (block_end) begin
                        raw_ready <= 1'b0;
                        state     <= FLUSH;
                    end else if (avail_beats >= 4) begin
                        raw_ready <= 1'b0;
                        state <= DMA_ADDR;
                    end
                end

                FLUSH: begin
                    if (pack_ptr != 6'd0 && !wbuf_full) begin
                        wbuf[wbuf_wr[$clog2(BUF_DEPTH)-1:0]] <= pack_beat;
                        wbuf_wr   <= wbuf_wr + 1;
                        pack_ptr  <= 6'd0;
                        pack_beat <= '0;
                    end
                    comp_block_size <= bytes_out;
                    comp_block_done <= 1'b1;
                    saved_write_state <= FLUSH;
                    state <= DMA_ADDR;
                end

                DMA_ADDR: begin
                    if (wbuf_empty) begin
                        if (saved_write_state == FLUSH) begin
                            if (block_last) state <= DONE;
                            else state <= IDLE;
                        end else begin
                            if (saved_write_state == WRITE_BS) bs_ready <= 1'b1;
                            else raw_ready <= 1'b1;
                            state <= saved_write_state;
                        end
                    end else if (!axi_awvalid) begin
                        axi_awaddr    <= wr_addr;
                        axi_awlen     <= burst_len;
                        axi_awsize    <= 3'b110;
                        axi_awburst   <= 2'b01;
                        axi_awid      <= '0;
                        axi_awvalid   <= 1'b1;
                        wr_bytes_left <= ({2'd0, burst_len} + 1) << 6;
                        
                        axi_wvalid    <= 1'b1;
                        axi_wlast     <= (burst_len == 0);
                        axi_wdata     <= wbuf[wbuf_rd[$clog2(BUF_DEPTH)-1:0]];
                        axi_wstrb     <= {(AXI_DATA_W/8){1'b1}};
                        
                        axi_bready    <= 1'b1;
                        state         <= DMA_DATA;
                    end
                end

                DMA_DATA: begin
                    if (axi_awready && axi_awvalid) begin
                        axi_awvalid <= 1'b0;
                        wr_addr     <= wr_addr + (({9'd0, axi_awlen} + 1) << 6);
                    end

                    if (axi_wvalid && axi_wready) begin
                        wbuf_rd       <= wbuf_rd + 1;
                        wr_bytes_left <= wr_bytes_left - 64;
                        
                        if (axi_wlast) begin
                            axi_wvalid <= 1'b0;
                            axi_wlast  <= 1'b0;
                        end else begin
                            axi_wdata <= wbuf[(wbuf_rd + 1) % BUF_DEPTH];
                            axi_wlast <= (wr_bytes_left <= 128);
                        end
                    end

                    if (axi_bvalid && axi_bready) begin
                        axi_bready <= 1'b0;
                        if (wbuf_empty && !axi_wvalid) begin
                            if (saved_write_state == FLUSH) begin
                                if (block_last) begin
                                    state <= DONE;
                                end else begin
                                    state <= IDLE;
                                end
                            end else begin
                                if (saved_write_state == WRITE_BS)
                                   bs_ready <= 1'b1;
                                else
                                    raw_ready <= 1'b1;
                                state <= saved_write_state;
                            end
                        end else begin
                            state <= DMA_ADDR;
                        end
                    end
                end

                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
