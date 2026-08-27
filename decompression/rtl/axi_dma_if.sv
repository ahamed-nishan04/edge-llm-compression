module axi_dma_if #(
    parameter int AXI_DATA_WIDTH = 512,
    parameter int AXI_ADDR_WIDTH = 40,
    parameter int AXI_ID_WIDTH   = 6,
    parameter int FIFO_DEPTH     = 4096,
    parameter int NUM_TILES      = 64
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                          start,
    input  logic [AXI_ADDR_WIDTH-1:0]     src_addr,
    input  logic [$clog2(NUM_TILES)-1:0]  tile_id,
    output logic                          done,

    input  logic [$clog2(FIFO_DEPTH)-1:0] comp_len_bytes = '1,

    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                    m_axi_arlen,
    output logic [2:0]                    m_axi_arsize,
    output logic [AXI_ID_WIDTH-1:0]       m_axi_arid,
    output logic                          m_axi_arvalid,
    input  logic                          m_axi_arready,

    input  logic [AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input  logic                          m_axi_rvalid,
    input  logic                          m_axi_rlast,
    output logic                          m_axi_rready,

    output logic [7:0]                    out_byte,
    output logic                          out_valid,
    input  logic                          out_ready,
    output logic                          out_tile_last,
    output logic [$clog2(NUM_TILES)-1:0]  out_tile_id
);

    localparam int BEAT_BYTES  = AXI_DATA_WIDTH / 8;
    localparam int BURST_LEN   = (FIFO_DEPTH + BEAT_BYTES - 1) / BEAT_BYTES; 
    localparam int PTR_W       = $clog2(FIFO_DEPTH) + 1; 

    typedef enum logic [1:0] {IDLE, ADDR, DATA, DRAIN} state_e;
    state_e state, state_n;

    logic [7:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [$clog2(FIFO_DEPTH)-1:0] wr_idx, rd_idx;      
    logic [PTR_W-1:0]              occupancy;            
    logic fifo_empty, fifo_full;

    assign fifo_empty = (occupancy == 0);
    assign fifo_full  = (occupancy == FIFO_DEPTH);

    logic [$clog2(NUM_TILES)-1:0] tile_id_q;
    logic [BEAT_BYTES-1:0][7:0]   rdata_bytes;
    assign rdata_bytes = m_axi_rdata;

    logic [PTR_W-1:0] bytes_delivered;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= state_n;
    end

    always_comb begin
        state_n = state;
        unique case (state)
            IDLE : if (start) state_n = ADDR;
            ADDR : if (m_axi_arvalid && m_axi_arready) state_n = DATA;
            DATA : if (m_axi_rvalid && m_axi_rlast && m_axi_rready) state_n = DRAIN;
            DRAIN: if (bytes_delivered == FIFO_DEPTH) state_n = IDLE;
            default: state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= '0;
            tile_id_q     <= '0;
        end else if (state == IDLE && start) begin
            m_axi_araddr  <= src_addr;
            m_axi_arvalid <= 1'b1;
            tile_id_q     <= tile_id;
        end else if (state == ADDR && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
        end
    end

    assign m_axi_arlen  = BURST_LEN - 1;      
    assign m_axi_arsize = $clog2(BEAT_BYTES); 
    assign m_axi_arid   = '0;
    assign m_axi_rready = (state == DATA) && !fifo_full;

    logic wr_fire;
    assign wr_fire = m_axi_rvalid && m_axi_rready;

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_idx <= '0;
        end else if (wr_fire) begin
            for (i = 0; i < BEAT_BYTES; i++) begin
                fifo_mem[(wr_idx + i[$clog2(FIFO_DEPTH)-1:0]) % FIFO_DEPTH] <= rdata_bytes[i];
            end
            wr_idx <= (wr_idx + BEAT_BYTES[$clog2(FIFO_DEPTH)-1:0]) % FIFO_DEPTH;
        end
    end

    logic pop;
    assign out_byte  = fifo_mem[rd_idx];
    assign out_valid = !fifo_empty;
    assign pop       = out_valid && out_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_idx <= '0;
        end else if (pop) begin
            rd_idx <= (rd_idx == FIFO_DEPTH-1) ? '0 : rd_idx + 1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occupancy <= '0;
        end else begin
            case ({wr_fire, pop})
                2'b10: occupancy <= occupancy + BEAT_BYTES;
                2'b01: occupancy <= occupancy - 1;
                2'b11: occupancy <= occupancy + BEAT_BYTES - 1;
                default: occupancy <= occupancy;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bytes_delivered <= '0;
            done            <= 1'b0;
        end else begin
            done <= 1'b0;
            if (state == IDLE && start) begin
                bytes_delivered <= '0;
            end else if (pop) begin
                bytes_delivered <= bytes_delivered + 1;
                if (bytes_delivered + 1 == FIFO_DEPTH) done <= 1'b1;
            end
        end
    end

    assign out_tile_id   = tile_id_q;
    assign out_tile_last = pop && (bytes_delivered + 1 == FIFO_DEPTH);

endmodule
