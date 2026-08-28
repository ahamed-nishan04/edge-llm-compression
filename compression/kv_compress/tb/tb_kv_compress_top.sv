// =============================================================================
// tb_kv_compress_top.sv
// Structural testbench for kv_compress_top. STATUS: written but NOT yet
// run through iterative simulation debugging -- unlike the decompression
// side (which went through several real bugs found via `iverilog`/`vvp`
// before it passed), this has only been checked for syntax, not behavior.
// Expect the same kind of bring-up work the decompression testbench
// needed: declaration-order issues, off-by-ones in the backward-pass
// index bookkeeping, and FSM race conditions are all plausible here given
// tans_encoder.sv's complexity. Start debugging by comparing intermediate
// signals (freq[]/base_tbl[] after NORMALIZE/BASE phases, result_bits[]/
// result_nbbits[] after BACKWARD) against model/kv_encoder.c's printed
// intermediate state for the SAME input tile -- that C model is verified
// (its own round-trip self-test passes), so it's the right oracle.
// =============================================================================

`timescale 1ns/1ps

module tb_kv_compress_top;

    localparam int TILE_SIZE_BYTES = 16;
    localparam int NUM_TILES       = 1;
    localparam int DICT_DEPTH_BYTES = 1024;
    localparam int AXI_DATA_WIDTH  = 512;
    localparam int AXI_ADDR_WIDTH  = 40;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic start, busy, done, error;
    logic [31:0] compressed_bytes;
    logic [11:0] out_init_state;
    logic [AXI_ADDR_WIDTH-1:0] dst_base_addr;
    logic [$clog2(NUM_TILES)-1:0] tile_id;
    logic [1:0] quant_mode;
    logic signed [15:0] quant_scale;
    logic signed [7:0]  quant_zero;

    logic [31:0] kv_data_in;
    logic kv_data_valid, kv_data_ready, kv_data_last;

    logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [5:0] m_axi_awid;
    logic m_axi_awvalid, m_axi_awready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    logic m_axi_wlast, m_axi_wvalid, m_axi_wready, m_axi_bvalid, m_axi_bready;

    logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_rd_addr;
    logic [7:0] dict_rd_data;
    logic dict_rd_en;

    kv_compress_top #(
        .TILE_SIZE_BYTES  (TILE_SIZE_BYTES),
        .NUM_TILES        (NUM_TILES),
        .DICT_DEPTH_BYTES (DICT_DEPTH_BYTES),
        .AXI_DATA_WIDTH   (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH   (AXI_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .dst_base_addr(dst_base_addr),
        .tile_id(tile_id),
        .quant_mode(quant_mode),
        .quant_scale(quant_scale),
        .quant_zero(quant_zero),
        .busy(busy), .done(done),
        .compressed_bytes(compressed_bytes),
        .out_init_state(out_init_state),
        .error(error),

        .kv_data_in(kv_data_in),
        .kv_data_valid(kv_data_valid),
        .kv_data_ready(kv_data_ready),
        .kv_data_last(kv_data_last),

        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awid(m_axi_awid),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),

        .dict_rd_addr(dict_rd_addr), .dict_rd_data(dict_rd_data),
        .dict_rd_en(dict_rd_en)
    );

    // ---------------- Trivial AXI write sink (accepts everything) -------
    assign m_axi_awready = 1'b1;
    assign m_axi_wready  = 1'b1;
    assign m_axi_bvalid  = 1'b1; // always-ready response, simplification

    // ---------------- Empty D_KV dictionary for this smoke test ---------
    assign dict_rd_data = 8'h00;

    // ---------------- Stimulus: matches kv_encoder.c's self-test tile ---
    // (1,2,3,4,5,6 repeated, then 7,8,9,10) so RTL output can be diffed
    // against that C model's printed intermediate/final values.
    // NOTE: kv_data_in is driven as Q16.16 fixed-point here (value <<< 16),
    // matching quant_pack.sv's simulation-only placeholder arithmetic --
    // NOT true IEEE-754 fp32 bits. See that file's header for why.
    int raw_vals[0:15];
    initial begin
        raw_vals[0]=1; raw_vals[1]=2; raw_vals[2]=3; raw_vals[3]=4;
        raw_vals[4]=5; raw_vals[5]=6; raw_vals[6]=1; raw_vals[7]=2;
        raw_vals[8]=3; raw_vals[9]=4; raw_vals[10]=5; raw_vals[11]=6;
        raw_vals[12]=7; raw_vals[13]=8; raw_vals[14]=9; raw_vals[15]=10;
    end

    initial begin
        start = 0;
        dst_base_addr = 0;
        tile_id = 0;
        quant_mode = 2'd0;
        quant_scale = 16'h0100; // Q8.8: 1.0
        quant_zero  = 8'h00;
        kv_data_valid = 0;
        kv_data_in = 0;
        kv_data_last = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        start = 1;
        @(posedge clk);
        start = 0;

        for (int i = 0; i < 16; i++) begin
            kv_data_in    = raw_vals[i] <<< 16; // Q16.16
            kv_data_valid = 1;
            kv_data_last  = (i == 15);
            @(posedge clk);
            while (!kv_data_ready) @(posedge clk);
        end
        kv_data_valid = 0;
        kv_data_last  = 0;

        wait (done || error);
        @(posedge clk);

        if (error) begin
            $display("[TB] FAIL: compressor reported error");
            $fatal(1);
        end else begin
            $display("[TB] Compressed %0d bytes, init_state=%0d",
                      compressed_bytes, out_init_state);
            $display("[TB] Compare against model/kv_encoder.c's self-test output");
        end

        $finish;
    end

    initial begin
        #100000;
        $display("[TB] FAIL: watchdog timeout, busy=%0b done=%0b", busy, done);
        $fatal(1);
    end

endmodule
