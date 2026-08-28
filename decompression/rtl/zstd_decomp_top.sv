
module zstd_decomp_top #(

    parameter int TILE_SIZE_BYTES   = 4096,
    parameter int NUM_TILES         = 64,
    parameter int MAX_COMP_RATIO_X  = 8,

    parameter int NUM_DOUBLE_BUFS   = 2,

    parameter int AXI_DATA_WIDTH    = 512,
    parameter int AXI_ADDR_WIDTH    = 40,
    parameter int AXI_ID_WIDTH      = 6,

    parameter int NUM_DICTS         = 3,
    parameter int DICT_DEPTH_BYTES  = 32768,
    parameter int DICT_SEL_WIDTH    = $clog2(NUM_DICTS),

    parameter bit ENABLE_DESPARSE   = 1,
    parameter int QUANT_MODE_WIDTH  = 2,
    parameter int OUT_DATA_WIDTH    = 256,

    parameter int TILE_ADDR_WIDTH   = $clog2(TILE_SIZE_BYTES),
    parameter int COMP_FIFO_DEPTH   = TILE_SIZE_BYTES

) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        start,
    input  logic [AXI_ADDR_WIDTH-1:0]   src_base_addr,
    input  logic [AXI_ADDR_WIDTH-1:0]   dst_base_addr,
    input  logic [$clog2(NUM_TILES+1)-1:0] num_tiles_this_run,
    input  logic [DICT_SEL_WIDTH-1:0]   dict_sel,
    input  logic [QUANT_MODE_WIDTH-1:0] quant_mode,
    input  logic                        desparse_en,

    output logic                        busy,
    output logic                        done,
    output logic [31:0]                 tiles_completed,
    output logic                        error,
    output logic [3:0]                  error_code,

    output logic [AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
    output logic [7:0]                  m_axi_arlen,
    output logic [2:0]                  m_axi_arsize,
    output logic [AXI_ID_WIDTH-1:0]     m_axi_arid,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,

    input  logic [AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  logic                        m_axi_rvalid,
    input  logic                        m_axi_rlast,
    output logic                        m_axi_rready,

    output logic [OUT_DATA_WIDTH-1:0]   out_data,
    output logic                        out_valid,
    output logic [TILE_ADDR_WIDTH-1:0]  out_tile_offset,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,
    output logic                        out_tile_last,
    input  logic                        out_ready,

    input  logic                        dict_wr_en,
    input  logic [DICT_SEL_WIDTH-1:0]   dict_wr_sel,
    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_wr_addr,
    input  logic [7:0]                  dict_wr_data,

    input  logic                         table_wr_en,
    input  logic [11:0]                  table_wr_addr,
    input  logic [8:0]                   table_wr_symbol,
    input  logic [4:0]                   table_wr_nbbits,
    input  logic [11:0]                  table_wr_newstate_base,

    input  logic [11:0]                  init_state,
    input  logic [15:0]                  num_symbols_this_tile
);

    logic [7:0]  comp_byte;
    logic        comp_valid, comp_ready;
    logic        comp_tile_last;
    logic [$clog2(NUM_TILES)-1:0] comp_tile_id;

    logic [8:0]  ent_symbol;
    logic        ent_valid, ent_ready;
    logic        ent_tile_last;
    logic [$clog2(NUM_TILES)-1:0] ent_tile_id;

    logic [7:0]  lz_data;
    logic        lz_valid, lz_ready;
    logic        lz_tile_last;
    logic [$clog2(NUM_TILES)-1:0] lz_tile_id;
    logic [TILE_ADDR_WIDTH-1:0]   lz_tile_offset;

    logic [7:0]  ds_data;
    logic        ds_valid, ds_ready;
    logic        ds_tile_last;
    logic [$clog2(NUM_TILES)-1:0] ds_tile_id;
    logic [TILE_ADDR_WIDTH-1:0]   ds_tile_offset;

    logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_rd_addr;
    logic [7:0]  dict_rd_data;
    logic        dict_rd_en;

    logic [$clog2(NUM_DOUBLE_BUFS)-1:0] active_wr_buf, active_rd_buf;
    logic buf_swap_req, buf_swap_ack;

    assign buf_swap_ack = buf_swap_req;

    logic dma_start, dma_done;
    logic [AXI_ADDR_WIDTH-1:0] dma_src_addr;
    logic [$clog2(NUM_TILES)-1:0] dma_tile_id;

    tile_scheduler #(
        .NUM_TILES       (NUM_TILES),
        .NUM_DOUBLE_BUFS (NUM_DOUBLE_BUFS),
        .AXI_ADDR_WIDTH  (AXI_ADDR_WIDTH),
        .TILE_SIZE_BYTES (TILE_SIZE_BYTES)
    ) u_sched (
        .clk                 (clk),
        .rst_n               (rst_n),
        .start               (start),
        .src_base_addr       (src_base_addr),
        .dst_base_addr       (dst_base_addr),
        .num_tiles_this_run  (num_tiles_this_run),
        .busy                (busy),
        .done                (done),
        .tiles_completed     (tiles_completed),
        .error               (error),
        .error_code          (error_code),

        .dma_start           (dma_start),
        .dma_src_addr        (dma_src_addr),
        .dma_tile_id         (dma_tile_id),
        .dma_done            (dma_done),
        .pipe_tile_done      (out_valid && out_ready && out_tile_last),

        .active_wr_buf       (active_wr_buf),
        .active_rd_buf       (active_rd_buf),
        .buf_swap_req        (buf_swap_req),
        .buf_swap_ack        (buf_swap_ack)
    );

    axi_dma_if #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .FIFO_DEPTH     (COMP_FIFO_DEPTH),
        .NUM_TILES      (NUM_TILES)
    ) u_dma (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (dma_start),
        .src_addr       (dma_src_addr),
        .tile_id        (dma_tile_id),
        .done           (dma_done),

        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arid     (m_axi_arid),
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rlast    (m_axi_rlast),
        .m_axi_rready   (m_axi_rready),

        .out_byte       (comp_byte),
        .out_valid      (comp_valid),
        .out_ready      (comp_ready),
        .out_tile_last  (comp_tile_last),
        .out_tile_id    (comp_tile_id)
    );

    tans_decoder #(
        .NUM_TILES  (NUM_TILES),

        .STATE_BITS (4)
    ) u_tans (
        .clk             (clk),
        .rst_n           (rst_n),
        .in_byte         (comp_byte),
        .in_valid        (comp_valid),
        .in_ready        (comp_ready),
        .in_tile_id      (comp_tile_id),

        .tile_start             (dma_start),

        .init_state             (init_state),

        .num_symbols_this_tile  (num_symbols_this_tile),

        .out_symbol      (ent_symbol),
        .out_valid       (ent_valid),
        .out_ready       (ent_ready),
        .out_tile_last   (ent_tile_last),
        .out_tile_id     (ent_tile_id),

        .table_wr_en             (table_wr_en),
        .table_wr_addr           (table_wr_addr),
        .table_wr_symbol         (table_wr_symbol),
        .table_wr_nbbits         (table_wr_nbbits),
        .table_wr_newstate_base  (table_wr_newstate_base)
    );

    lz_reconstruct #(
        .TILE_SIZE_BYTES (TILE_SIZE_BYTES),
        .NUM_TILES       (NUM_TILES),
        .DICT_DEPTH_BYTES(DICT_DEPTH_BYTES)
    ) u_lz (
        .clk              (clk),
        .rst_n            (rst_n),
        .in_symbol        (ent_symbol),
        .in_valid         (ent_valid),
        .in_ready         (ent_ready),
        .in_tile_last     (ent_tile_last),
        .in_tile_id       (ent_tile_id),

        .dict_rd_addr     (dict_rd_addr),
        .dict_rd_data     (dict_rd_data),
        .dict_rd_en       (dict_rd_en),

        .out_data         (lz_data),
        .out_valid        (lz_valid),
        .out_ready        (lz_ready),
        .out_tile_last    (lz_tile_last),
        .out_tile_id      (lz_tile_id),
        .out_tile_offset  (lz_tile_offset)
    );

    desparse_unit #(
        .TILE_SIZE_BYTES (TILE_SIZE_BYTES),
        .NUM_TILES       (NUM_TILES),
        .ENABLE          (ENABLE_DESPARSE)
    ) u_desparse (
        .clk             (clk),
        .rst_n           (rst_n),
        .bypass          (~desparse_en),

        .in_data         (lz_data),
        .in_valid        (lz_valid),
        .in_ready        (lz_ready),
        .in_tile_last    (lz_tile_last),
        .in_tile_id      (lz_tile_id),
        .in_tile_offset  (lz_tile_offset),

        .out_data        (ds_data),
        .out_valid       (ds_valid),
        .out_ready       (ds_ready),
        .out_tile_last   (ds_tile_last),
        .out_tile_id     (ds_tile_id),
        .out_tile_offset (ds_tile_offset)
    );

    dequant_unit #(
        .TILE_SIZE_BYTES  (TILE_SIZE_BYTES),
        .NUM_TILES        (NUM_TILES),
        .OUT_DATA_WIDTH   (OUT_DATA_WIDTH),
        .QUANT_MODE_WIDTH (QUANT_MODE_WIDTH)
    ) u_dequant (
        .clk             (clk),
        .rst_n           (rst_n),
        .quant_mode      (quant_mode),

        .in_data         (ds_data),
        .in_valid        (ds_valid),
        .in_ready        (ds_ready),
        .in_tile_last    (ds_tile_last),
        .in_tile_id      (ds_tile_id),
        .in_tile_offset  (ds_tile_offset),

        .out_data        (out_data),
        .out_valid       (out_valid),
        .out_ready       (out_ready),
        .out_tile_offset (out_tile_offset),
        .out_tile_id     (out_tile_id),
        .out_tile_last   (out_tile_last)
    );

    dict_mem #(
        .NUM_DICTS       (NUM_DICTS),
        .DICT_DEPTH_BYTES(DICT_DEPTH_BYTES),
        .DICT_SEL_WIDTH  (DICT_SEL_WIDTH)
    ) u_dict (
        .clk         (clk),
        .rst_n       (rst_n),

        .wr_en       (dict_wr_en),
        .wr_sel      (dict_wr_sel),
        .wr_addr     (dict_wr_addr),
        .wr_data     (dict_wr_data),

        .rd_sel      (dict_sel),
        .rd_addr     (dict_rd_addr),
        .rd_en       (dict_rd_en),
        .rd_data     (dict_rd_data)
    );

endmodule
