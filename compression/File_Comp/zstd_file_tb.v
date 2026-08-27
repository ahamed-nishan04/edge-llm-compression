`default_nettype none
`timescale 1ns/1ps

module zstd_file_tb;

    localparam AXI_ADDR_W  = 64;
    localparam AXI_DATA_W  = 512;
    localparam AXI_ID_W    = 4;
    localparam CLK_HALF    = 2;
    localparam TIMEOUT_NS  = CLK_HALF * 2 * 5000_000;
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;
    
    initial begin #(CLK_HALF*10);
    rst_n = 1'b1; end

    reg                    csr_start    = 1'b0;
    reg  [AXI_ADDR_W-1:0]  csr_src_addr = 64'h0000_1000;
    reg  [AXI_ADDR_W-1:0]  csr_dst_addr = 64'h0200_0000;
    reg  [31:0]            csr_src_len  = 0;
    wire csr_done, csr_busy;
    wire [31:0] csr_comp_len, csr_ratio_x100;

    wire [AXI_ID_W-1:0]   m_axi_r_arid;
    wire [AXI_ADDR_W-1:0] m_axi_r_araddr;
    wire [7:0]            m_axi_r_arlen;
    wire [2:0]            m_axi_r_arsize;
    wire [1:0]            m_axi_r_arburst;
    wire                  m_axi_r_arvalid;
    wire                  m_axi_r_rready;
    reg                   m_axi_r_arready = 1'b0;
    reg  [AXI_ID_W-1:0]   m_axi_r_rid     = '0;
    reg  [AXI_DATA_W-1:0] m_axi_r_rdata   = '0;
    reg  [1:0]            m_axi_r_rresp   = 2'b00;
    reg                   m_axi_r_rlast   = 1'b0;
    reg                   m_axi_r_rvalid  = 1'b0;
    wire [AXI_ID_W-1:0]     m_axi_w_awid;
    wire [AXI_ADDR_W-1:0]   m_axi_w_awaddr;
    wire [7:0]              m_axi_w_awlen;
    wire [2:0]              m_axi_w_awsize;
    wire [1:0]              m_axi_w_awburst;
    wire                    m_axi_w_awvalid;
    wire [AXI_DATA_W-1:0]   m_axi_w_wdata;
    wire [AXI_DATA_W/8-1:0] m_axi_w_wstrb;
    wire                    m_axi_w_wlast;
    wire                    m_axi_w_wvalid;
    wire                    m_axi_w_bready;
    reg                   m_axi_w_awready = 1'b0;
    reg                   m_axi_w_wready  = 1'b0;
    reg  [AXI_ID_W-1:0]   m_axi_w_bid     = '0;
    reg  [1:0]            m_axi_w_bresp   = 2'b00;
    reg                   m_axi_w_bvalid  = 1'b0;
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
        .clk(clk), .rst_n(rst_n),
        .csr_start(csr_start), .csr_src_addr(csr_src_addr), .csr_dst_addr(csr_dst_addr),
        .csr_src_len(csr_src_len), .csr_done(csr_done), .csr_busy(csr_busy),
        .csr_comp_len(csr_comp_len), .csr_ratio_x100(csr_ratio_x100),
        
        .m_axi_r_arid(m_axi_r_arid), .m_axi_r_araddr(m_axi_r_araddr), .m_axi_r_arlen(m_axi_r_arlen),
        .m_axi_r_arsize(m_axi_r_arsize), .m_axi_r_arburst(m_axi_r_arburst), .m_axi_r_arvalid(m_axi_r_arvalid),
        
        .m_axi_r_arready(m_axi_r_arready), .m_axi_r_rid(m_axi_r_rid), .m_axi_r_rdata(m_axi_r_rdata),
        .m_axi_r_rresp(m_axi_r_rresp), .m_axi_r_rlast(m_axi_r_rlast), .m_axi_r_rvalid(m_axi_r_rvalid),
        .m_axi_r_rready(m_axi_r_rready),
        
        .m_axi_w_awid(m_axi_w_awid), .m_axi_w_awaddr(m_axi_w_awaddr), .m_axi_w_awlen(m_axi_w_awlen),
        .m_axi_w_awsize(m_axi_w_awsize), .m_axi_w_awburst(m_axi_w_awburst), .m_axi_w_awvalid(m_axi_w_awvalid),
        .m_axi_w_awready(m_axi_w_awready), .m_axi_w_wdata(m_axi_w_wdata), .m_axi_w_wstrb(m_axi_w_wstrb),
        .m_axi_w_wlast(m_axi_w_wlast), .m_axi_w_wvalid(m_axi_w_wvalid), .m_axi_w_wready(m_axi_w_wready),
        .m_axi_w_bid(m_axi_w_bid), .m_axi_w_bresp(m_axi_w_bresp), .m_axi_w_bvalid(m_axi_w_bvalid),
        .m_axi_w_bready(m_axi_w_bready)
    );
    reg [7:0] src_mem [0:16777215]; 
    integer fd, file_size;
    reg [1023:0] filename;
    initial begin
        if (!$value$plusargs("SRC_FILE=%s", filename)) begin
            $display("ERROR: You must specify a file using +SRC_FILE=filename.bin");
            $finish;
        end
        fd = $fopen(filename, "rb");
        file_size = $fread(src_mem, fd);
        $fclose(fd);
        csr_src_len = file_size;
    end

    function [AXI_DATA_W-1:0] read_beat;
        input [AXI_ADDR_W-1:0] beat_addr;
        integer bi;
        reg [AXI_ADDR_W-1:0] off;
        begin
            for (bi = 0; bi < AXI_DATA_W/8; bi = bi + 1) begin
                off = (beat_addr - csr_src_addr) + bi;
                read_beat[bi*8 +: 8] = (off < csr_src_len) ? src_mem[off] : 8'h00;
            end
        end
    endfunction

    reg [7:0] ar_beats_rem;
    reg [AXI_ADDR_W-1:0] ar_addr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_r_arready <= 1'b1;
            m_axi_r_rvalid  <= 1'b0;
            m_axi_r_rlast   <= 1'b0;
        end else begin
            if (m_axi_r_arready && m_axi_r_arvalid) begin
                m_axi_r_arready <= 1'b0;
                ar_addr_r       <= m_axi_r_araddr;
                ar_beats_rem    <= m_axi_r_arlen;
                m_axi_r_rid     <= m_axi_r_arid;
                m_axi_r_rdata   <= read_beat(m_axi_r_araddr);
                m_axi_r_rlast   <= (m_axi_r_arlen == 8'd0);
                m_axi_r_rvalid  <= 1'b1;
            end else if (m_axi_r_rvalid && m_axi_r_rready) begin
                if (m_axi_r_rlast) begin
                    m_axi_r_rvalid  <= 1'b0;
                    m_axi_r_rlast   <= 1'b0;
                    m_axi_r_arready <= 1'b1;
                end else begin
                    ar_beats_rem   <= ar_beats_rem - 1'b1;
                    ar_addr_r      <= ar_addr_r + (AXI_DATA_W/8);
                    m_axi_r_rdata  <= read_beat(ar_addr_r + (AXI_DATA_W/8));
                    m_axi_r_rlast  <= (ar_beats_rem == 8'd1);
                end
            end
        end
    end

    reg aw_latched;
    reg w_latched;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_w_awready <= 1'b1;
            m_axi_w_wready  <= 1'b1;
            m_axi_w_bvalid  <= 1'b0;
            aw_latched      <= 1'b0;
            w_latched       <= 1'b0;
        end else begin
            if (m_axi_w_bvalid && m_axi_w_bready) begin
                m_axi_w_bvalid  <= 1'b0;
                m_axi_w_awready <= 1'b1;
                m_axi_w_wready  <= 1'b1;
                aw_latched      <= 1'b0;
                w_latched       <= 1'b0;
            end else if (!m_axi_w_bvalid) begin
                if (m_axi_w_awready && m_axi_w_awvalid) begin
                    m_axi_w_awready <= 1'b0;
                    m_axi_w_bid     <= m_axi_w_awid;
                    aw_latched      <= 1'b1;
                end
                
                if (m_axi_w_wready && m_axi_w_wvalid) begin
                    if (m_axi_w_wlast) begin
                        m_axi_w_wready <= 1'b0;
                        w_latched      <= 1'b1;
                    end
                end
                
                if ((aw_latched || (m_axi_w_awready && m_axi_w_awvalid)) &&
                    (w_latched  || (m_axi_w_wready  && m_axi_w_wvalid && m_axi_w_wlast))) begin
                    m_axi_w_bvalid <= 1'b1;
                end
            end
        end
    end

    integer cycle_count = 0;
    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (cycle_count % 5000 == 0) begin
            $display("[%0t ns] Heartbeat: cycle %0d, FSM State = %0d (1=INIT, 2=COMPRESS, 3=BT, 4=STATS, 5=ENCODE, 6=FLUSH, 7=OUT)", 
                     $time, cycle_count, dut.top_state);
            $fflush();
        end
    end

    integer hw_start_ns;
    integer hw_cycles;

    initial begin
        @(posedge rst_n);
        repeat(10) @(posedge clk);
        $display("[%0t ns] Starting compression...", $time);
        hw_start_ns = $time;
        
        csr_start <= 1'b1;
        @(posedge clk);
        csr_start <= 1'b0;

        @(posedge csr_done);
        hw_cycles = ($time - hw_start_ns) / (2 * CLK_HALF);

        $display("\n=================================================================");
        $display("  RESULTS");
        $display("=================================================================");
        $display("  Source bytes   : %0d", csr_src_len);
        $display("  Compressed     : %0d", csr_comp_len);
        $display("  HW cycles used : %0d", hw_cycles);
        $display("=================================================================\n");
        $finish;
    end

    initial begin
        #TIMEOUT_NS;
        $display("\n!!! WATCHDOG TIMEOUT: RTL Deadlock Detected !!!");
        $display("  FSM is stuck in state: %0d", dut.top_state);
        $fflush();
        $finish;
    end
endmodule
`default_nettype wire
