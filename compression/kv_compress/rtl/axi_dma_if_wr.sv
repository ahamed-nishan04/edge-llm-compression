// =============================================================================
// axi_dma_if_wr.sv
// Minimal AXI-512 write master. Packs incoming compressed bytes into
// 512-bit beats and writes them out starting at dst_addr. Mirrors
// axi_dma_if.sv (decompression side's read master) structurally, but for
// the write direction.
// =============================================================================

module axi_dma_if_wr #(
    parameter int AXI_DATA_WIDTH = 512,
    parameter int AXI_ADDR_WIDTH = 40,
    parameter int AXI_ID_WIDTH   = 6,
    parameter int MAX_BEATS      = 64  // supports up to MAX_BEATS*64 = 4096
                                        // compressed bytes per tile
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [AXI_ADDR_WIDTH-1:0] dst_addr,

    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_last,

    output logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [AXI_ID_WIDTH-1:0]   m_axi_awid,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    output logic [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready,

    output logic busy,
    output logic done,
    output logic error
);

    localparam int BEAT_BYTES = AXI_DATA_WIDTH / 8;

    // ---------------- Byte-pack buffer: accumulate compressed bytes into
    // beat-wide words as they arrive; issue the AXI write burst once
    // in_last is seen (byte count is not known ahead of time -- unlike
    // the decompression read side, we don't know the compressed length
    // until the encoder finishes, so this buffers a whole tile's worth
    // of compressed bytes before issuing any AXI transaction). ----------
    logic [7:0] beat_buf [0:BEAT_BYTES-1];
    logic [$clog2(BEAT_BYTES+1)-1:0] byte_in_beat;
    logic [$clog2(MAX_BEATS+1)-1:0]  beat_count;
    logic [AXI_DATA_WIDTH-1:0] full_buf [0:MAX_BEATS-1];

    assign in_ready = 1'b1; // buffer is sized for the worst case; always accept

    typedef enum logic [1:0] {S_FILL, S_ADDR, S_DATA, S_RESP} state_e;
    state_e st, st_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_FILL;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_FILL : if (in_valid && in_last) st_n = S_ADDR;
            S_ADDR : if (m_axi_awvalid && m_axi_awready) st_n = S_DATA;
            S_DATA : if (m_axi_wvalid && m_axi_wready && m_axi_wlast) st_n = S_RESP;
            S_RESP : if (m_axi_bvalid) st_n = S_FILL;
            default: st_n = S_FILL;
        endcase
    end

    integer bi;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_in_beat <= '0;
            beat_count   <= '0;
        end else if (st == S_FILL && in_valid) begin
            full_buf[beat_count][byte_in_beat*8 +: 8] <= in_byte;
            if (byte_in_beat == BEAT_BYTES-1 || in_last) begin
                byte_in_beat <= '0;
                beat_count   <= beat_count + 1;
            end else begin
                byte_in_beat <= byte_in_beat + 1;
            end
        end else if (st == S_RESP && m_axi_bvalid) begin
            byte_in_beat <= '0;
            beat_count   <= '0;
        end
    end

    logic [$clog2(MAX_BEATS+1)-1:0] send_idx;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_awvalid <= 1'b0;
        end else if (st == S_FILL && st_n == S_ADDR) begin
            m_axi_awaddr  <= dst_addr;
            m_axi_awvalid <= 1'b1;
            send_idx      <= '0;
        end else if (st == S_ADDR && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
        end
    end

    assign m_axi_awlen  = beat_count == 0 ? 8'd0 : (beat_count - 1);
    assign m_axi_awsize = $clog2(BEAT_BYTES);
    assign m_axi_awid   = '0;

    assign m_axi_wdata  = full_buf[send_idx];
    assign m_axi_wvalid = (st == S_DATA);
    assign m_axi_wlast  = (send_idx == beat_count - 1);
    assign m_axi_bready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) send_idx <= '0;
        else if (st == S_DATA && m_axi_wvalid && m_axi_wready) send_idx <= send_idx + 1;
    end

    assign busy  = (st != S_FILL) || (byte_in_beat != 0);
    assign done  = (st == S_RESP) && m_axi_bvalid;
    assign error = 1'b0; // TODO: surface AXI write errors (m_axi_bresp) once
                          // that signal is wired to this module

endmodule
