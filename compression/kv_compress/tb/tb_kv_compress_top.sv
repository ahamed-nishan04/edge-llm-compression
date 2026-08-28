// =============================================================================
// tb_kv_compress_top.sv
//
// Scoreboarded testbench for kv_compress_top. Checks THREE stages against
// model/kv_encoder.c's golden output, not just the final byte count:
//
//   quant_pack       -> GEN_QUANT_BYTES
//   lz_match_finder  -> GEN_TOKENS        (9-bit, 256 = ESCAPE)
//   tans_encoder     -> GEN_COMP_BYTES + GEN_INIT_STATE
//
// Checking intermediates is the point. "8 compressed bytes instead of 7"
// tells you nothing about which stage is wrong; "quant OK, tokens OK,
// first compressed byte differs" localises the bug immediately, and gives
// an automated fix loop a gradient to climb.
//
// Stimulus comes from tb/generated_kv_stimulus.svh, regenerated from the
// C model by gen_kv_stimulus.py. Nothing compiles without running that
// first.
// =============================================================================

`timescale 1ns/1ps

module tb_kv_compress_top;

    `include "generated_kv_stimulus.svh"

    localparam int TILE_SIZE_BYTES  = 16;
    // 2, not 1: $clog2(1)==0 makes every [$clog2(NUM_TILES)-1:0] a [-1:0]
    // vector and turns {TID_W{1'b0}}-style constructs into zero-repeat
    // concatenations, which iverilog rejects outright. Only one tile is
    // actually driven.
    localparam int NUM_TILES        = 2;
    localparam int DICT_DEPTH_BYTES = 1024;
    localparam int AXI_DATA_WIDTH   = 512;
    localparam int AXI_ADDR_WIDTH   = 40;

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

    // ---------------- AXI write sink (accepts everything) ----------------
    assign m_axi_awready = 1'b1;
    assign m_axi_wready  = 1'b1;
    assign m_axi_bvalid  = 1'b1;

    // ---------------- Empty D_KV dictionary ------------------------------
    // The golden model runs with dictLen=0, so the RTL must see an empty
    // dictionary too or the two will legitimately disagree.
    assign dict_rd_data = 8'h00;

    // =========================================================================
    // SCOREBOARDS
    // =========================================================================
    int q_idx = 0, t_idx = 0, c_idx = 0;
    int q_err = 0, t_err = 0, c_err = 0;
    logic sb_fail;
    assign sb_fail = (q_err != 0) || (t_err != 0) || (c_err != 0);

    // ---- Stage 1: quant_pack output ----
    always_ff @(posedge clk) begin
        if (rst_n && dut.quant_valid && dut.quant_ready) begin
            if (q_idx < GEN_NUM_QUANT) begin
                if (dut.quant_byte !== GEN_QUANT_BYTES[q_idx]) begin
                    $display("[QUANT FAIL] %0d: expected 0x%02h got 0x%02h",
                             q_idx, GEN_QUANT_BYTES[q_idx], dut.quant_byte);
                    q_err++;
                end
            end else begin
                $display("[QUANT FAIL] extra byte %0d (golden has %0d)",
                         q_idx, GEN_NUM_QUANT);
                q_err++;
            end
            q_idx++;
        end
    end

    // ---- Stage 2: lz_match_finder token stream ----
    always_ff @(posedge clk) begin
        if (rst_n && dut.tok_valid && dut.tok_ready) begin
            if (t_idx < GEN_NUM_TOKENS) begin
                if (dut.tok_symbol !== GEN_TOKENS[t_idx]) begin
                    $display("[TOKEN FAIL] %0d: expected %0d got %0d",
                             t_idx, GEN_TOKENS[t_idx], dut.tok_symbol);
                    t_err++;
                end
            end else begin
                $display("[TOKEN FAIL] extra token %0d (golden has %0d)",
                         t_idx, GEN_NUM_TOKENS);
                t_err++;
            end
            t_idx++;
        end
    end

    // ---- Stage 3: tans_encoder compressed bytes ----
    always_ff @(posedge clk) begin
        if (rst_n && dut.comp_valid && dut.comp_ready) begin
            if (c_idx < GEN_NUM_COMP_BYTES) begin
                if (dut.comp_byte !== GEN_COMP_BYTES[c_idx]) begin
                    $display("[COMP FAIL] %0d: expected 0x%02h got 0x%02h",
                             c_idx, GEN_COMP_BYTES[c_idx], dut.comp_byte);
                    c_err++;
                end
            end else begin
                $display("[COMP FAIL] extra byte %0d (golden has %0d)",
                         c_idx, GEN_NUM_COMP_BYTES);
                c_err++;
            end
            c_idx++;
        end
    end

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        start = 0;
        dst_base_addr = 0;
        tile_id = '0;
        quant_mode = 2'd0;                    // INT8
        quant_scale = GEN_QUANT_SCALE_Q88;
        quant_zero  = GEN_QUANT_ZERO;
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

        // Proper valid/ready handshake: hold valid, advance only on a cycle
        // where ready was actually high. (The previous version advanced a
        // clock first and checked ready afterwards, which can drop beats.)
        // BUG FIX (testbench): driving kv_data_in/valid via a blocking
        // assignment scheduled in the SAME simulation instant as the
        // posedge that captures it races the DUT's own always_ff for
        // that edge -- on the leading edge (racing quant_pack's
        // division-chain settling) and, when clearing valid right after
        // the loop, on the trailing edge too. Drive every change on the
        // negedge, a full half period from the posedge that consumes it.
        for (int i = 0; i < GEN_NUM_RAW; i++) begin
            @(negedge clk);
            kv_data_in    = GEN_RAW_VALS[i] <<< 16;   // Q16.16
            kv_data_valid = 1'b1;
            kv_data_last  = (i == GEN_NUM_RAW - 1);
            wait (kv_data_ready);
            @(posedge clk);
        end
        @(negedge clk);
        kv_data_valid = 0;
        kv_data_last  = 0;

        wait (done || error || sb_fail);
        repeat (2) @(posedge clk);

        $display("--------------------------------------------------");
        $display("[TB] quant  : %0d/%0d bytes checked, %0d errors",
                 q_idx, GEN_NUM_QUANT, q_err);
        $display("[TB] tokens : %0d/%0d tokens checked, %0d errors",
                 t_idx, GEN_NUM_TOKENS, t_err);
        $display("[TB] comp   : %0d/%0d bytes checked, %0d errors",
                 c_idx, GEN_NUM_COMP_BYTES, c_err);
        $display("[TB] init_state: expected %0d got %0d",
                 GEN_INIT_STATE, out_init_state);
        $display("[TB] compressed_bytes: expected %0d got %0d",
                 GEN_NUM_COMP_BYTES, compressed_bytes);
        $display("--------------------------------------------------");

        if (error) begin
            $display("[TB] FAIL: compressor asserted error");
            $fatal(1);
        end
        if (sb_fail) begin
            $display("[TB] FAIL: scoreboard mismatch");
            $fatal(1);
        end
        if (q_idx != GEN_NUM_QUANT || t_idx != GEN_NUM_TOKENS ||
            c_idx != GEN_NUM_COMP_BYTES) begin
            $display("[TB] FAIL: stage produced wrong number of beats");
            $fatal(1);
        end
        if (out_init_state !== GEN_INIT_STATE[11:0]) begin
            $display("[TB] FAIL: init_state mismatch");
            $fatal(1);
        end
        if (compressed_bytes !== GEN_NUM_COMP_BYTES) begin
            $display("[TB] FAIL: compressed_bytes mismatch");
            $fatal(1);
        end

        $display("==================================================");
        $display("[TB] PASS: KV tile compressed bit-exactly vs golden model!");
        $display("==================================================");
        $finish;
    end

    // Watchdog. Prints per-stage progress so a hang is diagnosable rather
    // than just "timed out".
    initial begin
        #200000;
        $display("[TB] quant  : %0d/%0d", q_idx, GEN_NUM_QUANT);
        $display("[TB] tokens : %0d/%0d", t_idx, GEN_NUM_TOKENS);
        $display("[TB] comp   : %0d/%0d", c_idx, GEN_NUM_COMP_BYTES);
        $display("[TB] lz st=%0d enc st=%0d  quant v/r=%0b/%0b tok v/r=%0b/%0b comp v/r=%0b/%0b",
                 dut.u_lz.st, dut.u_tans_enc.st,
                 dut.quant_valid, dut.quant_ready,
                 dut.tok_valid, dut.tok_ready,
                 dut.comp_valid, dut.comp_ready);
        $display("[TB] FAIL: watchdog timeout, busy=%0b done=%0b", busy, done);
        $fatal(1);
    end

    initial begin
        $dumpfile("tb_kv_compress_top.vcd");
        $dumpvars(0, tb_kv_compress_top);
    end

endmodule
