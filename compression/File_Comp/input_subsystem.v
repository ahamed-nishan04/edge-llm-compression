`default_nettype none
`timescale 1ns/1ps

module input_subsystem #(
    parameter AXI_ADDR_W   = 64,
    parameter AXI_DATA_W   = 512,
    parameter AXI_ID_W     = 4,
    parameter BUF_DEPTH    = 256,
    parameter MAX_BLOCK_LG = 17
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,
    input  wire [AXI_ADDR_W-1:0]  src_addr,
    input  wire [MAX_BLOCK_LG:0]  src_len,
    output reg                    done,
    output reg                    busy,
    output reg   [AXI_ID_W-1:0]    axi_arid,
    output reg  [AXI_ADDR_W-1:0] axi_araddr,
    output reg  [7:0]             axi_arlen,
    output reg  [2:0]             axi_arsize,
    output reg  [1:0]             axi_arburst,
    output reg                    axi_arvalid,
    input  wire                   axi_arready,
    input  wire [AXI_ID_W-1:0]   axi_rid,
    input  wire [AXI_DATA_W-1:0] axi_rdata,
    input  wire [1:0]             axi_rresp,
    input  wire                   axi_rlast,
    input  wire                   axi_rvalid,
    output wire                   axi_rready,
    output reg  [7:0]             out_byte,
    output reg  [MAX_BLOCK_LG:0]  out_pos,
    output reg                    out_valid,
    input  wire                  out_ready
);
    reg  [AXI_DATA_W-1:0]      fifo_mem [0:BUF_DEPTH-1];
    reg  [$clog2(BUF_DEPTH):0] fifo_wr_ptr, fifo_rd_ptr;
    wire fifo_full  = (fifo_wr_ptr - fifo_rd_ptr) == BUF_DEPTH;
    wire fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);

    assign axi_rready = !fifo_full;
    reg  [AXI_DATA_W-1:0] cur_beat;
    reg  [5:0]            byte_idx;
    reg                   beat_valid;
    reg  [AXI_ADDR_W-1:0]  dma_addr;
    reg  [MAX_BLOCK_LG:0]  bytes_left;
    reg  [MAX_BLOCK_LG:0]  bytes_issued;
    reg  [MAX_BLOCK_LG:0]  position;
    reg                    burst_in_flight;
    localparam IDLE=2'd0, ADDR=2'd1, DATA=2'd2, DRAIN=2'd3;
    reg [1:0] state;

    wire [MAX_BLOCK_LG:0] burst_total;
    assign burst_total = ({{MAX_BLOCK_LG{1'b0}}, axi_arlen} + 1) << 6;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            axi_arvalid     <= 1'b0;
            axi_araddr      <= '0;
            axi_arlen       <= 8'd0;
            axi_arsize      <= 3'b110;
            axi_arburst     <= 2'b01;
            axi_arid        <= '0;
            bytes_left      <= '0;
            bytes_issued    <= '0;
            dma_addr        <= '0;
            fifo_wr_ptr     <= '0;
            burst_in_flight <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        dma_addr     <= src_addr;
                        bytes_left   <= src_len;
                        bytes_issued <= '0;
                        busy         <= 1'b1;
                        state        <= ADDR;
                    end
                end

                ADDR: begin
                    if (!fifo_full && bytes_left > 0) begin
                        axi_araddr  <= dma_addr;
                        axi_arlen   <= (bytes_left >= 64*256) ? 8'd255 : (((bytes_left + 63) >> 6) - 1);
                        axi_arsize  <= 3'b110;
                        axi_arburst <= 2'b01;
                        axi_arvalid <= 1'b1;
                        state       <= DATA;
                    end
                end

                DATA: begin
                    if (axi_arready && axi_arvalid) begin
                        axi_arvalid     <= 1'b0;
                        dma_addr        <= dma_addr + burst_total;
                        bytes_left      <= (burst_total >= bytes_left) ? '0 : bytes_left - burst_total;
                        burst_in_flight <= 1'b1;
                    end

                    if (axi_rvalid && !fifo_full) begin
                        fifo_mem[fifo_wr_ptr[$clog2(BUF_DEPTH)-1:0]] <= axi_rdata;
                        fifo_wr_ptr <= fifo_wr_ptr + 1;
                        if (axi_rlast)
                            burst_in_flight <= 1'b0;
                    end

                    if (bytes_left == 0 && !burst_in_flight)
                        state <= DRAIN;
                    else if (!axi_arvalid && bytes_left > 0 && !fifo_full && !burst_in_flight)
                        state <= ADDR;
                end

                DRAIN: begin
                    if (fifo_empty && !beat_valid) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    wire fifo_rd_en;
    assign fifo_rd_en = !fifo_empty && !beat_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_valid  <= 1'b0;
            byte_idx    <= 6'd0;
            cur_beat    <= '0;
            position    <= '0;
            fifo_rd_ptr <= '0;
            out_valid   <= 1'b0;
            out_byte    <= 8'd0;
            out_pos     <= '0;
        end else begin
            out_valid <= 1'b0;
            if (start)
                position <= '0;
            if (fifo_rd_en) begin
                cur_beat    <= fifo_mem[fifo_rd_ptr[$clog2(BUF_DEPTH)-1:0]];
                fifo_rd_ptr <= fifo_rd_ptr + 1;
                beat_valid  <= 1'b1;
                byte_idx    <= 6'd0;
            end

            if (beat_valid && out_ready) begin
                out_byte  <= cur_beat[byte_idx * 8 +: 8];
                out_pos   <= position;
                out_valid <= 1'b1;
                position  <= position + 1;
                if (byte_idx == 6'd63)
                    beat_valid <= 1'b0;
                else
                    byte_idx <= byte_idx + 1;
            end
        end
    end
endmodule
`default_nettype wire
