`default_nettype none
`timescale 1ns/1ps

module zstd_tb;
    localparam AXI_ADDR_W  = 64;
    localparam AXI_DATA_W  = 512;
    localparam AXI_ID_W    = 4;
    localparam CLK_HALF    = 2;
    localparam SRC_BYTES   = 256;
    localparam SRC_ADDR    = 64'h0000_1000;
    localparam DST_ADDR    = 64'h0000_8000;
    localparam TIMEOUT_NS  = 500_000;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;
    initial begin #(CLK_HALF*10); rst_n = 1'b1; end

    reg                    csr_start    = 1'b0;
    reg  [AXI_ADDR_W-1:0]  csr_src_addr = SRC_ADDR;
    reg  [AXI_ADDR_W-1:0]  csr_dst_addr = DST_ADDR;
    reg  [31:0]            csr_src_len  = SRC_BYTES;
    wire                   csr_done;
    wire                   csr_busy;
    wire [31:0]            csr_comp_len;
    wire [31:0]            csr_ratio_x100;

    wire [AXI_ID_W-1:0]    m_axi_r_arid;
    wire [AXI_ADDR_W-1:0]  m_axi_r_araddr;
    wire [7:0]             m_axi_r_arlen;
    wire [2:0]             m_axi_r_arsize;
    wire [1:0]             m_axi_r_arburst;
    wire                   m_axi_r_arvalid;
    reg                    m_axi_r_arready = 1'b0;
    reg  [AXI_ID_W-1:0]    m_axi_r_rid     = '0;
    reg  [AXI_DATA_W-1:0]  m_axi_r_rdata   = '0;
    reg  [1:0]             m_axi_r_rresp   = 2'b00;
    reg                    m_axi_r_rlast   = 1'b0;
    reg                    m_axi_r_rvalid  = 1'b0;
    wire                   m_axi_r_rready;

    wire [AXI_ID_W-1:0]      m_axi_w_awid;
    wire [AXI_ADDR_W-1:0]    m_axi_w_awaddr;
    wire [7:0]               m_axi_w_awlen;
    wire [2:0]               m_axi_w_awsize;
    wire [1:0]               m_axi_w_awburst;
    wire                     m_axi_w_awvalid;
    reg                      m_axi_w_awready = 1'b0;
    wire [AXI_DATA_W-1:0]    m_axi_w_wdata;
    wire [AXI_DATA_W/8-1:0]  m_axi_w_wstrb;
    wire                     m_axi_w_wlast;
    wire                     m_axi_w_wvalid;
    reg                      m_axi_w_wready  = 1'b0;
    reg  [AXI_ID_W-1:0]      m_axi_w_bid     = '0;
    reg  [1:0]               m_axi_w_bresp   = 2'b00;
    reg                      m_axi_w_bvalid  = 1'b0;
    wire                     m_axi_w_bready;

    zstd #(
        .WINDOW_LOG (16),
        .BLOCK_LOG  (17),
        .N_BANKS    (64),
        .CAM_ENTRIES(12),
        .N_WALKERS  (64),
        .K_MATCHES  (64),
        .MAX_MATCHES(16),
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_DATA_W (AXI_DATA_W),
        .AXI_ID_W   (AXI_ID_W)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .csr_start        (csr_start),
        .csr_src_addr     (csr_src_addr),
        .csr_dst_addr     (csr_dst_addr),
        .csr_src_len      (csr_src_len),
        .csr_done         (csr_done),
        .csr_busy         (csr_busy),
        .csr_comp_len     (csr_comp_len),
        .csr_ratio_x100   (csr_ratio_x100),
        .m_axi_r_arid     (m_axi_r_arid),
        .m_axi_r_araddr   (m_axi_r_araddr),
        .m_axi_r_arlen    (m_axi_r_arlen),
        .m_axi_r_arsize   (m_axi_r_arsize),
        .m_axi_r_arburst  (m_axi_r_arburst),
        .m_axi_r_arvalid  (m_axi_r_arvalid),
        .m_axi_r_arready  (m_axi_r_arready),
        .m_axi_r_rid      (m_axi_r_rid),
        .m_axi_r_rdata    (m_axi_r_rdata),
        .m_axi_r_rresp    (m_axi_r_rresp),
        .m_axi_r_rlast    (m_axi_r_rlast),
        .m_axi_r_rvalid   (m_axi_r_rvalid),
        .m_axi_r_rready   (m_axi_r_rready),
        .m_axi_w_awid     (m_axi_w_awid),
        .m_axi_w_awaddr   (m_axi_w_awaddr),
        .m_axi_w_awlen    (m_axi_w_awlen),
        .m_axi_w_awsize   (m_axi_w_awsize),
        .m_axi_w_awburst  (m_axi_w_awburst),
        .m_axi_w_awvalid  (m_axi_w_awvalid),
        .m_axi_w_awready  (m_axi_w_awready),
        .m_axi_w_wdata    (m_axi_w_wdata),
        .m_axi_w_wstrb    (m_axi_w_wstrb),
        .m_axi_w_wlast    (m_axi_w_wlast),
        .m_axi_w_wvalid   (m_axi_w_wvalid),
        .m_axi_w_wready   (m_axi_w_wready),
        .m_axi_w_bid      (m_axi_w_bid),
        .m_axi_w_bresp    (m_axi_w_bresp),
        .m_axi_w_bvalid   (m_axi_w_bvalid),
        .m_axi_w_bready   (m_axi_w_bready)
    );

    reg [7:0] src_mem [0:SRC_BYTES-1];
    integer   fi;
    initial begin
        for (fi = 0; fi < 64; fi = fi + 1)
            src_mem[fi] = 8'h00;
        for (fi = 64; fi < 96; fi = fi + 1)
            src_mem[fi] = 8'h41 + ((fi - 64) % 8);
        for (fi = 96; fi < 128; fi = fi + 1)
            src_mem[fi] = 8'h00;
        for (fi = 128; fi < 192; fi = fi + 1)
            src_mem[fi] = 8'h41 + ((fi - 128) % 8);
        for (fi = 192; fi < 224; fi = fi + 1)
            src_mem[fi] = (fi % 2 == 0) ? 8'hAB : 8'hCD;
        for (fi = 224; fi < 256; fi = fi + 1)
            src_mem[fi] = 8'hFF;
    end

    function [AXI_DATA_W-1:0] read_beat;
        input [AXI_ADDR_W-1:0] beat_addr;
        integer bi;
        reg [AXI_ADDR_W-1:0] off;
        begin
            for (bi = 0; bi < AXI_DATA_W/8; bi = bi + 1) begin
                off = (beat_addr - SRC_ADDR) + bi;
                read_beat[bi*8 +: 8] = (off < SRC_BYTES) ? src_mem[off[7:0]] : 8'h00;
            end
        end
    endfunction

    reg [1:0]            ar_st;
    reg [7:0]            ar_beats_rem;
    reg [AXI_ADDR_W-1:0] ar_addr_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_st           <= 2'd0;
            m_axi_r_arready <= 1'b0;
            m_axi_r_rvalid  <= 1'b0;
            m_axi_r_rlast   <= 1'b0;
            m_axi_r_rid     <= '0;
            m_axi_r_rdata   <= '0;
        end else begin
            case (ar_st)
                2'd0: begin
                    m_axi_r_arready <= 1'b1;
                    if (m_axi_r_arvalid & m_axi_r_arready) begin
                        m_axi_r_arready <= 1'b0;
                        ar_addr_r       <= m_axi_r_araddr;
                        ar_beats_rem    <= m_axi_r_arlen;
                        m_axi_r_rid     <= m_axi_r_arid;
                        m_axi_r_rdata   <= read_beat(m_axi_r_araddr);
                        m_axi_r_rlast   <= (m_axi_r_arlen == 8'd0);
                        m_axi_r_rvalid  <= 1'b1;
                        ar_st           <= 2'd1;
                    end
                end
                2'd1: begin
                    if (m_axi_r_rvalid & m_axi_r_rready) begin
                        if (ar_beats_rem == 8'd0) begin
                            m_axi_r_rvalid  <= 1'b0;
                            m_axi_r_rlast   <= 1'b0;
                            m_axi_r_arready <= 1'b1;
                            ar_st           <= 2'd0;
                        end else begin
                            ar_beats_rem  <= ar_beats_rem - 1'b1;
                            ar_addr_r     <= ar_addr_r + (AXI_DATA_W/8);
                            m_axi_r_rdata <= read_beat(ar_addr_r + (AXI_DATA_W/8));
                            m_axi_r_rlast <= (ar_beats_rem == 8'd1);
                        end
                    end
                end
                default: ar_st <= 2'd0;
            endcase
        end
    end

    reg [1:0] aw_st;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_st           <= 2'd0;
            m_axi_w_awready <= 1'b0;
            m_axi_w_wready  <= 1'b0;
            m_axi_w_bvalid  <= 1'b0;
            m_axi_w_bid     <= '0;
        end else begin
            case (aw_st)
                2'd0: begin
                    m_axi_w_awready <= 1'b1;
                    m_axi_w_wready  <= 1'b0;
                    m_axi_w_bvalid  <= 1'b0;
                    if (m_axi_w_awvalid & m_axi_w_awready) begin
                        m_axi_w_awready <= 1'b0;
                        m_axi_w_wready  <= 1'b1;
                        m_axi_w_bid     <= m_axi_w_awid;
                        aw_st           <= 2'd1;
                    end
                end
                2'd1: begin
                    if (m_axi_w_wvalid & m_axi_w_wready & m_axi_w_wlast) begin
                        m_axi_w_wready <= 1'b0;
                        m_axi_w_bvalid <= 1'b1;
                        aw_st          <= 2'd2;
                    end
                end
                2'd2: begin
                    if (m_axi_w_bvalid & m_axi_w_bready) begin
                        m_axi_w_bvalid  <= 1'b0;
                        m_axi_w_awready <= 1'b1;
                        aw_st           <= 2'd0;
                    end
                end
                default: aw_st <= 2'd0;
            endcase
        end
    end

    initial begin
        $dumpfile("zstd_tb.vcd");
        $dumpvars(1, zstd_tb);
    end

    task show_zone;
        input [191:0] label; 
        input integer base;
        input integer len;
        integer k;
        begin
            $write("  %s [%3d-%3d]: ", label, base, base+len-1);
            for (k = base; k < base+6 && k < base+len; k = k+1)
                $write("%02x ", src_mem[k]);
            if (len > 6) $write("...");
            $display("");
        end
    endtask

    initial begin
        幕posedge rst_n);
        repeat(10) @(posedge clk);

        $display("");
        $display("=============================================================");
        $display("  ZSTD Level-22 Testbench");
        $display("  Source: %0d bytes  |  WINDOW_LOG=16  |  N_BANKS=64", SRC_BYTES);
        $display("  N_WALKERS=64  |  K_MATCHES=64  |  PRUNE_MARGIN=0x7FFF");
        $display("=============================================================");
        $display("  Source zones:");
        show_zone("A: 64x 0x00 (zeros)     ", 0,   64);
        show_zone("B: ABCDEFGH repeat x4   ", 64,  32);
        show_zone("C: 32x 0x00 (ref->A)    ", 96,  32);
        show_zone("D: ABCDEFGH repeat x8   ", 128, 64);
        show_zone("E: 0xAB,0xCD repeat x16 ", 192, 32);
        show_zone("F: 32x 0xFF (ones)      ", 224, 32);
        $display("-------------------------------------------------------------");
        $display("  Aspects exercised:");
        $display("   Literals  : Zones A+F   -- Huffman table (0x00 vs 0xFF)");
        $display("   ML short  : Zone  B+E   -- FSE ML symbols  3..8");
        $display("   ML long   : Zone  C+D   -- FSE ML symbols 32..64");
        $display("   Off small : Zone  E     -- FSE off-codes 1,2 (period 2)");
        $display("   Off medium: Zone  C     -- FSE off-code ~7 (offset=96)");
        $display("   Off large : Zone  D     -- FSE off-code ~6 (offset=64)");
        $display("   DP engine : all zones   -- exhaustive parse (no pruning)");
        $display("   Backtrack : all zones   -- both match and literal arcs");
        $display("   Stats+Huf : all zones   -- Huffman + FSE table build");
        $display("   Entropy   : all zones   -- full bitstream encoding");
        $display("=============================================================");
        $display("");
        $display("[%0t] Starting compression...", $time);
        csr_start <= 1'b1;
        @(posedge clk);
        csr_start <= 1'b0;

        @(posedge csr_done);

        $display("");
        $display("=============================================================");
        $display("  RESULTS");
        $display("=============================================================");
        $display("  Source bytes   : %0d",   csr_src_len);
        $display("  Compressed     : %0d bytes", csr_comp_len);
        $display("  Ratio          : %0d.%02d : 1", csr_ratio_x100 / 100, csr_ratio_x100 % 100);
        $display("  Space saved    : %0d bytes (%0d%%)", csr_src_len - csr_comp_len, ((csr_src_len - csr_comp_len) * 100) / csr_src_len);
        $display("-------------------------------------------------------------");

        if (csr_comp_len < csr_src_len)
            $display("  PASS: compressed < source");
        else
            $display("  WARN: compressed >= source (no gain)");
        if (csr_ratio_x100 >= 300)
            $display("  PASS: ratio >= 3:1 (strong LZ matching confirmed)");
        else if (csr_ratio_x100 >= 150)
            $display("  INFO: ratio >= 1.5:1 (some LZ matching active)");
        else
            $display("  WARN: ratio < 1.5:1 -- check LZ pipeline");
        $display("=============================================================");
        $display("");

        repeat(20) @(posedge clk);
        $finish;
    end

    initial begin
        #TIMEOUT_NS;
        $display("");
        $display("=============================================");
        $display("!!! TIMEOUT at %0t ns !!!", $time);
        $display("=============================================");
        $display("  top_state   = %0d", dut.top_state);
        $display("  in FSM      = %0d", dut.u_input.state);
        $display("  out FSM     = %0d", dut.u_output.state);
        $display("  in fifo E/F = %0b/%0b", dut.u_input.fifo_empty, dut.u_input.fifo_full);
        $display("  AXI-R v/r   = %0b/%0b", m_axi_r_rvalid, m_axi_r_rready);
        $display("  AXI-W v/r   = %0b/%0b", m_axi_w_wvalid, m_axi_w_wready);
        $display("  bt_start    = %0b", dut.bt_start_sig);
        $display("  bt_done     = %0b", dut.bt_done);
        $display("  enc_done    = %0b", dut.enc_done_sig);
        $display("  stats_done  = %0b", dut.stats_pass2_done);
        $display("=============================================");
        $finish;
    end

endmodule
`default_nettype wire
