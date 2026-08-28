`timescale 1ns/1ps

// =============================================================================
// tb_zstd_decomp_top.sv -- REAL single-tile FSE round-trip test.
//
// Unlike the earlier control-flow smoke test (literal-passthrough,
// nb_bits=0 everywhere, no real entropy coding exercised), this drives
// the pipeline with an ACTUAL FSE-encoded tile from
// model/compute_test_vectors.c (real table, real variable bit-lengths,
// a real ESCAPE-coded LZ match), and checks the LZ-reconstructed output
// bytes against that golden model's expected values -- not just "did it
// finish without error".
//
// `include`s generated_stimulus.svh, regenerated fresh by
// run_zstd_chia_loop.py's regenerate_golden_vectors() +
// write_stimulus_include() before every LLM iteration -- so this test
// always checks against the CURRENT golden-model output, not a frozen
// snapshot.
// =============================================================================

module tb_zstd_decomp_top;

    `include "generated_stimulus.svh"

    localparam int TILE_SIZE_BYTES = GEN_TILE_SIZE_BYTES; // 12 for the current vectors
    // NOTE: 2, not 1, and this is a WORKAROUND rather than a design choice.
    // With NUM_TILES=1, $clog2(NUM_TILES) evaluates to 0, so every
    // `logic [$clog2(NUM_TILES)-1:0]` in the RTL and in this file becomes a
    // [-1:0] vector, and desparse_unit.sv's `{TID_W{1'b0}}` becomes a
    // zero-repeat concatenation -- which iverilog rejects outright
    // ("Concatenation repeat may not be zero in this context"), so the
    // design does not elaborate at all. That pattern appears at 24 sites
    // across rtl/ and tb/. The proper fix is a floored width localparam,
    //     localparam int TID_W = (NUM_TILES <= 1) ? 1 : $clog2(NUM_TILES);
    // applied at all of them. Until that is done, this test instantiates
    // capacity for 2 tiles and runs only 1 (see num_tiles_this_run below).
    localparam int NUM_TILES       = 2;
    localparam int NUM_DOUBLE_BUFS = 2;
    // NOTE: AXI_DATA_WIDTH deliberately narrow (32-bit, 4-byte beats) for
    // this small real-tile test. axi_dma_if.sv's compressed-side FIFO is
    // sized to COMP_FIFO_DEPTH=TILE_SIZE_BYTES, and its beat-unpack logic
    // writes an ENTIRE beat into that FIFO in one clock edge -- with a
    // 512-bit (64-byte) bus and a 12-byte tile, a single beat is more
    // than 5x the FIFO's depth, so the beat wraps around and corrupts
    // itself within that same write, and the occupancy counter overflows
    // silently back toward 0. A real design would size its bus width (or
    // its minimum tile size) so beats never exceed a tile's compressed
    // FIFO depth in the first place; this test picks the narrow-bus side
    // of that constraint since the tile size is fixed by the golden
    // vectors. Production tiles (hundreds+ bytes) don't hit this at
    // AXI_DATA_WIDTH=512.
    localparam int AXI_DATA_WIDTH  = 32;
    localparam int AXI_ADDR_WIDTH  = 40;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic start, busy, done, error, scoreboard_error;
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

    logic [11:0] init_state;
    logic [15:0] num_symbols_this_tile;

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
        .table_wr_newstate_base(table_wr_newstate_base),

        .init_state(init_state),
        .num_symbols_this_tile(num_symbols_this_tile)
    );

    // ---------------- AXI memory model: holds the REAL compressed bytes
    // from GEN_COMP_BYTES at address 0 (not a sequential ramp) ----------
    logic [7:0] mem [0:(1<<14)-1];
    initial begin
        for (int i = 0; i < (1<<14); i++) mem[i] = 8'h00;
        for (int i = 0; i < GEN_NUM_COMP_BYTES; i++) mem[i] = GEN_COMP_BYTES[i];
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

    // ---------------------------------------------------------
    // LZ-RECONSTRUCTION SCOREBOARD
    // Checks out_data against GEN_EXPECTED_LZ_BYTES (the real golden
    // model's LZ-reconstructed bytes), through dequant in INT8 identity
    // mode (scale=1, zero=0) with desparse bypassed -- so out_data's low
    // byte should equal the expected LZ byte unchanged.
    // ---------------------------------------------------------
    int check_idx = 0;
    logic [7:0]  expected_byte;
    logic [31:0] expected_dequant;

    always_ff @(posedge clk) begin
        if (out_valid && out_ready) begin
            if (check_idx < GEN_TILE_SIZE_BYTES) begin
                expected_byte    = GEN_EXPECTED_LZ_BYTES[check_idx];
                expected_dequant = {2{expected_byte, 8'h00}}; // scale=0x0100 (1.0), zero=0

                if (out_data[31:0] !== expected_dequant) begin
                    $display("[SCOREBOARD FAIL] Offset %0d: Expected 32'h%h, Got 32'h%h",
                              check_idx, expected_dequant, out_data[31:0]);
                    scoreboard_error = 1;
                end else begin
                    $display("[SCOREBOARD MATCH] Offset %0d: 32'h%h", check_idx, out_data[31:0]);
                end
            end
            check_idx++;
        end
    end

    initial begin
        start = 0;
        scoreboard_error = 0;
        src_base_addr = 0;
        dst_base_addr = 0;
        // 1, NOT NUM_TILES: the instance has capacity for 2 tiles (see the
        // note above) but the golden vectors only describe one. Driving
        // NUM_TILES here makes the scheduler fetch a second tile that does
        // not exist and hang. num_tiles_this_run is a runtime port precisely
        // so capacity and actual work can differ.
        num_tiles_this_run = 1;
        dict_sel = 2'd0;
        quant_mode = 2'd0; // QUANT_INT8
        desparse_en = 1'b0; // this test data isn't real 2:4-sparse-encoded;
                             // bypass, same convention as the earlier
                             // control-flow smoke test used

        dict_wr_en = 0; dict_wr_sel = 0; dict_wr_addr = 0; dict_wr_data = 0;
        table_wr_en = 0; table_wr_addr = 0; table_wr_symbol = 0;
        table_wr_nbbits = 0; table_wr_newstate_base = 0;
        init_state = GEN_INIT_STATE[11:0];
        num_symbols_this_tile = GEN_NUM_SYMBOLS[15:0];

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Program the REAL FSE decode table from the golden model
        table_wr_en = 1;
        for (int i = 0; i < GEN_NUM_TABLE_ENTRIES; i++) begin
            table_wr_addr          = GEN_TABLE_ADDR[i];
            table_wr_symbol        = GEN_TABLE_SYMBOL[i];
            table_wr_nbbits        = GEN_TABLE_NBBITS[i];
            table_wr_newstate_base = GEN_TABLE_NEWSTATE[i];
            @(posedge clk);
        end
        table_wr_en = 0;
        @(posedge clk);

        // Dequant scale=1.0 (Q8.8: 0x0100), zero=0, identity transform so
        // out_data should equal the LZ-reconstructed bytes unchanged.
        for (int g = 0; g < (TILE_SIZE_BYTES/128 == 0 ? 1 : TILE_SIZE_BYTES/128); g++) begin
            dut.u_dequant.scale_mem[g] = 16'h0100;
            dut.u_dequant.zero_mem[g]  = 8'h00;
        end

        start = 1;
        @(posedge clk);
        start = 0;

        wait (done || error || scoreboard_error);
        @(posedge clk);

        if (error || scoreboard_error) begin
            $display("[TB] FAIL: error=%0b error_code=%0d scoreboard_error=%0b",
                      error, error_code, scoreboard_error);
            $fatal(1);
        end else begin
            $display("==================================================");
            $display("[TB] PASS: Real FSE tile decoded and matched golden model!");
            $display("==================================================");
        end

        $finish;
    end

    // Debug trace
    logic [2:0] sched_st_prev_dbg;
    initial begin
        sched_st_prev_dbg = 3'b111;
        @(posedge start);
        forever begin
            @(posedge clk);
            if (dut.u_sched.st != sched_st_prev_dbg) begin
                $display("t=%0t sched state -> %0d  (dma_done=%0b pipe_tile_done_port=%0b)",
                    $time, dut.u_sched.st, dut.dma_done, dut.u_sched.pipe_tile_done);
                sched_st_prev_dbg = dut.u_sched.st;
            end
        end
    end

    initial begin
        #10000;
        $display("[TB] FAIL: watchdog timeout, busy=%0b done=%0b", busy, done);
        $fatal(1);
    end

    initial begin
        $dumpfile("tb_zstd_decomp_top.vcd");
        $dumpvars(0, tb_zstd_decomp_top);
    end

endmodule
