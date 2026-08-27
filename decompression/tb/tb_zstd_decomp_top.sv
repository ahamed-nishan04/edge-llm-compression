`timescale 1ns/1ps

module tb_zstd_decomp_top;

    localparam int TILE_SIZE_BYTES = 256;   
    localparam int NUM_TILES       = 4;     
    localparam int NUM_DOUBLE_BUFS = 2;
    localparam int AXI_DATA_WIDTH  = 512;
    localparam int AXI_ADDR_WIDTH  = 40;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk; 

    logic start, busy, done, error;
    logic [31:0] tiles_completed;
    logic [3:0]  error_code;
    logic [AXI_ADDR_WIDTH-1:0] src_base_addr, dst_base_addr;
    logic [$clog2(NUM_TILES+1)-1:0] num_tiles_this_run;
    logic [1:0] dict_sel;
    logic [1:0] quant_mode;
    logic desparse_en;

    logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [5:0] m_axi_arid;
    logic m_axi_arvalid, m_axi_arready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    logic m_axi_rvalid, m_axi_rlast, m_axi_rready;

    logic [255:0] out_data;
    logic out_valid, out_ready, out_tile_last;
    logic [$clog2(TILE_SIZE_BYTES)-1:0] out_tile_offset;
    logic [$clog2(NUM_TILES)-1:0] out_tile_id;

    logic dict_wr_en;
    logic [1:0] dict_wr_sel;
    logic [14:0] dict_wr_addr;
    logic [7:0] dict_wr_data;

    logic table_wr_en;
    logic [11:0] table_wr_addr;
    logic [8:0]  table_wr_symbol;
    logic [4:0]  table_wr_nbbits;
    logic [11:0] table_wr_newstate_base;

    zstd_decomp_top #(
        .TILE_SIZE_BYTES (TILE_SIZE_BYTES),
        .NUM_TILES       (NUM_TILES),
        .NUM_DOUBLE_BUFS (NUM_DOUBLE_BUFS),
        .AXI_DATA_WIDTH  (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH  (AXI_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .src_base_addr(src_base_addr),
        .dst_base_addr(dst_base_addr),
        .num_tiles_this_run(num_tiles_this_run),
        .dict_sel(dict_sel),
        .quant_mode(quant_mode),
        .desparse_en(desparse_en),
        .busy(busy), .done(done),
        .tiles_completed(tiles_completed),
        .error(error), .error_code(error_code),

        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arid(m_axi_arid),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rlast(m_axi_rlast), .m_axi_rready(m_axi_rready),

        .out_data(out_data), .out_valid(out_valid),
        .out_tile_offset(out_tile_offset), .out_tile_id(out_tile_id),
        .out_tile_last(out_tile_last), .out_ready(out_ready),

        .dict_wr_en(dict_wr_en), .dict_wr_sel(dict_wr_sel),
        .dict_wr_addr(dict_wr_addr), .dict_wr_data(dict_wr_data),

        .table_wr_en(table_wr_en), .table_wr_addr(table_wr_addr),
        .table_wr_symbol(table_wr_symbol), .table_wr_nbbits(table_wr_nbbits),
        .table_wr_newstate_base(table_wr_newstate_base)
    );

    logic [7:0] mem [0:(1<<14)-1]; 
                                     
    initial begin
        for (int i = 0; i < (1<<14); i++) mem[i] = i[7:0];
    end

    typedef enum {M_IDLE, M_DATA} mstate_e;
    mstate_e mstate;
    logic [AXI_ADDR_WIDTH-1:0] beat_addr;
    logic [7:0] beat_cnt, beat_total;

    assign m_axi_rvalid = (mstate == M_DATA);
    assign m_axi_rlast  = (mstate == M_DATA) && (beat_cnt == beat_total);
    always_comb begin
        for (int b = 0; b < AXI_DATA_WIDTH/8; b++)
            m_axi_rdata[b*8 +: 8] = mem[(beat_addr + b) % (1<<14)];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstate <= M_IDLE;
            m_axi_arready <= 1'b1;
        end else begin
            unique case (mstate)
                M_IDLE: begin
                    m_axi_arready <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        beat_addr  <= m_axi_araddr;
                        beat_total <= m_axi_arlen; 
                        beat_cnt   <= '0;
                        mstate     <= M_DATA;
                        m_axi_arready <= 1'b0;
                    end
                end
                M_DATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (beat_cnt == beat_total) begin
                            mstate <= M_IDLE;
                        end else begin
                            beat_cnt  <= beat_cnt + 1;
                            beat_addr <= beat_addr + AXI_DATA_WIDTH/8;
                        end
                    end
                end
            endcase
        end
    end

    assign out_ready = 1'b1;

    initial begin
        start = 0;
        src_base_addr = 0;
        dst_base_addr = 0;
        num_tiles_this_run = NUM_TILES;
        dict_sel = 2'd0;      
        quant_mode = 2'd0;    
        desparse_en = 1'b0;
        dict_wr_en = 0; dict_wr_sel = 0; dict_wr_addr = 0; dict_wr_data = 0;
        table_wr_en = 0; table_wr_addr = 0; table_wr_symbol = 0;
        table_wr_nbbits = 0; table_wr_newstate_base = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        dict_wr_en = 1;
        for (int a = 0; a < 256; a++) begin
            dict_wr_sel  = 2'd0;
            dict_wr_addr = a;
            dict_wr_data = a[7:0];
            @(posedge clk);
        end
        dict_wr_en = 0;
        @(posedge clk);

        table_wr_en             = 1;
        table_wr_addr            = 12'd0;
        table_wr_symbol          = 9'd0;
        table_wr_nbbits          = 5'd0;
        table_wr_newstate_base   = 12'd0;
        @(posedge clk);
        table_wr_en = 0;
        @(posedge clk);

        num_tiles_this_run = NUM_TILES;

        start = 1;
        @(posedge clk);
        start = 0;

        wait (done || error);
        @(posedge clk);

        if (error) begin
            $display("[TB] FAIL: pipeline reported error_code=%0d", error_code);
            $fatal(1);
        end else begin
            $display("[TB] PASS: completed %0d/%0d tiles", tiles_completed, NUM_TILES);
        end

        $finish;
    end

    logic [31:0] tiles_completed_prev;
    logic [2:0] sched_st_prev;
    initial begin
        tiles_completed_prev = 0;
        sched_st_prev = 3'b111;
        @(posedge start);
        forever begin
            @(posedge clk);
            if (tiles_completed != tiles_completed_prev) begin
                $display("t=%0t *** TILE COMPLETE: tiles_completed=%0d ***", $time, tiles_completed);
                tiles_completed_prev = tiles_completed;
            end
            if (dut.u_sched.st != sched_st_prev) begin
                $display("t=%0t sched state -> %0d", $time, dut.u_sched.st);
                sched_st_prev = dut.u_sched.st;
            end
        end
    end

    initial begin
        #80000000; 
                    
        $display("[TB] FAIL: watchdog timeout, busy=%0b done=%0b", busy, done);
        $fatal(1);
    end

    initial begin
        $dumpfile("tb_zstd_decomp_top.vcd");
        $dumpvars(0, tb_zstd_decomp_top);
    end

endmodule
