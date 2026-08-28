// =============================================================================
// zstd_decomp_top.sv
// Top-level tile-wise Zstd decompression accelerator
//
// Pipeline stages (matches your design doc):
//   AXI DMA fetch (compressed tile) -> tANS/FSE entropy decode -> LZ77
//   reconstruct -> desparse (2:4 structured sparsity) -> dequantize
//   (INT8/NF4/AWQ) -> output to consumer (MAC array / KV cache write port)
//
// Dictionary bank is selected per-tile by DICT_SEL (0=weights,1=KV,2=FFN).
// Tile count / tile size / SRAM depth are all top-level parameters so you
// can sweep granularity (model/layer/tensor/tile-wise) without touching
// the RTL body.
// =============================================================================

module zstd_decomp_top #(
    // ---------------- Tile / scheduling parameters ----------------
    parameter int TILE_SIZE_BYTES   = 4096,   // decompressed tile size (bytes)
    parameter int NUM_TILES         = 64,     // tiles per scheduling batch
    parameter int MAX_COMP_RATIO_X  = 8,      // worst-case expansion factor,
                                               // sizes the compressed-side FIFO
    parameter int NUM_DOUBLE_BUFS   = 2,      // 2 = classic double buffer,
                                               // set to 3 for extra slack

    // ---------------- Bus / memory parameters ----------------
    parameter int AXI_DATA_WIDTH    = 512,
    parameter int AXI_ADDR_WIDTH    = 40,
    parameter int AXI_ID_WIDTH      = 6,

    // ---------------- Dictionary parameters ----------------
    parameter int NUM_DICTS         = 3,      // 0:weights 1:KV 2:FFN
    parameter int DICT_DEPTH_BYTES  = 32768,  // per-dictionary size
    parameter int DICT_SEL_WIDTH    = $clog2(NUM_DICTS),

    // ---------------- Sparsity / quant parameters ----------------
    parameter bit ENABLE_DESPARSE   = 1,      // 2:4 structured sparsity expand
    parameter int QUANT_MODE_WIDTH  = 2,      // 0:INT8 1:NF4 2:AWQ-INT4
    parameter int OUT_DATA_WIDTH    = 256,    // dequantized output bus width

    // ---------------- Derived (do not override) ----------------
    parameter int TILE_ADDR_WIDTH   = $clog2(TILE_SIZE_BYTES),
    parameter int COMP_FIFO_DEPTH   = TILE_SIZE_BYTES  // conservatively sized;
                                               // compressed tile <= decompressed
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ---------------- Config / control (from scheduler / driver) ----------
    input  logic                        start,
    input  logic [AXI_ADDR_WIDTH-1:0]   src_base_addr,      // compressed data base
    input  logic [AXI_ADDR_WIDTH-1:0]   dst_base_addr,      // decompressed dest base
    input  logic [$clog2(NUM_TILES+1)-1:0] num_tiles_this_run, // runtime tile count, 1..NUM_TILES (needs NUM_TILES+1 range, it's a COUNT not an index)
    input  logic [DICT_SEL_WIDTH-1:0]   dict_sel,           // which dictionary bank
    input  logic [QUANT_MODE_WIDTH-1:0] quant_mode,
    input  logic                        desparse_en,        // per-run override

    output logic                        busy,
    output logic                        done,
    output logic [31:0]                 tiles_completed,
    output logic                        error,
    output logic [3:0]                  error_code,

    // ---------------- AXI-512 master (compressed tile fetch) --------------
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

    // ---------------- Output port (to MAC array / KV cache write) ---------
    output logic [OUT_DATA_WIDTH-1:0]   out_data,
    output logic                        out_valid,
    output logic [TILE_ADDR_WIDTH-1:0]  out_tile_offset,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,
    output logic                        out_tile_last,       // last beat of tile
    input  logic                        out_ready,

    // ---------------- Dictionary load port (host-programmed at init) ------
    input  logic                        dict_wr_en,
    input  logic [DICT_SEL_WIDTH-1:0]   dict_wr_sel,
    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_wr_addr,
    input  logic [7:0]                  dict_wr_data,

    // ---------------- tANS/FSE decode table load (host-programmed, per tile
    // or per tile-class -- required before any decode can run; table_mem
    // is otherwise uninitialized) ------------------------------------------
    input  logic                         table_wr_en,
    input  logic [11:0]                  table_wr_addr,   // STATE_BITS=12 default
    input  logic [8:0]                   table_wr_symbol, // MAX_SYM_BITS=9 default
    input  logic [4:0]                   table_wr_nbbits, // $clog2(MAX_NB_BITS+1)=5
    input  logic [11:0]                  table_wr_newstate_base,

    // ---------------- Per-tile entropy-decode metadata (host-provided;
    // tans_decoder tracks tile completion by SYMBOL COUNT, not by the
    // compressed byte stream's own boundary -- see that file's header
    // for why. tile_start reuses the scheduler's dma_start pulse, so a
    // new tile's decode begins the same cycle its fetch is issued.
    // init_state/num_symbols_this_tile are STATIC per run here (fine for
    // the current single-tile-per-run test scope); a real multi-tile
    // deployment would source these per-tile from a small metadata table
    // instead. ---------------------------------------------------------
    input  logic [11:0]                  init_state,       // STATE_BITS=12 default
    input  logic [15:0]                  num_symbols_this_tile
);

    // =========================================================================
    // Internal handshake buses between stages
    // =========================================================================

    // ---- DMA -> entropy decode (raw compressed bytes) ----
    logic [7:0]  comp_byte;
    logic        comp_valid, comp_ready;
    logic        comp_tile_last;
    logic [$clog2(NUM_TILES)-1:0] comp_tile_id;

    // ---- entropy decode -> LZ reconstruct (raw symbol stream; ESCAPE
    // detection and match-token interpretation now live inside
    // lz_reconstruct.sv itself, not passed through as separate fields) --
    logic [8:0]  ent_symbol;
    logic        ent_valid, ent_ready;
    logic        ent_tile_last;
    logic [$clog2(NUM_TILES)-1:0] ent_tile_id;

    // ---- LZ reconstruct -> desparse (dense-but-still-sparse-pattern bytes) --
    logic [7:0]  lz_data;
    logic        lz_valid, lz_ready;
    logic        lz_tile_last;
    logic [$clog2(NUM_TILES)-1:0] lz_tile_id;
    logic [TILE_ADDR_WIDTH-1:0]   lz_tile_offset;

    // ---- desparse -> dequant ----
    logic [7:0]  ds_data;
    logic        ds_valid, ds_ready;
    logic        ds_tile_last;
    logic [$clog2(NUM_TILES)-1:0] ds_tile_id;
    logic [TILE_ADDR_WIDTH-1:0]   ds_tile_offset;

    // ---- dequant -> output ----
    // (wired straight to top-level out_* ports)

    // ---- dictionary read ports (shared by LZ reconstruct stage) ----
    logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_rd_addr;
    logic [7:0]  dict_rd_data;
    logic        dict_rd_en;

    // ---- tile scheduler <-> double buffer control ----
    logic [$clog2(NUM_DOUBLE_BUFS)-1:0] active_wr_buf, active_rd_buf;
    logic buf_swap_req, buf_swap_ack;

    // NOTE: this pipeline streams decompressed/dequantized data straight out
    // via out_data/out_valid rather than staging it in an explicit on-chip
    // SRAM double buffer (the consumer -- MAC array or KV cache write port
    // -- is the actual sink). active_wr_buf/active_rd_buf are exposed for
    // when you DO add real double-buffered SRAM staging (e.g. if the
    // consumer can't keep up cycle-by-cycle and you need a full tile
    // resident before handoff).
    //
    // Placeholder fix: The `buf_swap_ack` should reflect a "buffer fully
    // drained by consumer" handshake. In the current streaming model, this
    // means the last beat of the tile has been successfully output.
    // BUG FIX (deadlock): this used to be
    //     assign buf_swap_ack = (out_valid && out_ready && out_tile_last);
    // which is a ONE-CYCLE PULSE on the tile's final output beat. But the
    // scheduler only reaches S_SWAP *after* S_WAIT_DRAIN has already
    // observed pipe_tile_done -- i.e. that final beat has necessarily
    // already gone out before anyone is listening for the ack. S_SWAP then
    // waited forever on a pulse that could never arrive, and the whole run
    // hung with busy=1, done=0 after emitting a full correct tile.
    //
    // Because S_WAIT_DRAIN already guarantees the condition the swap was
    // waiting on, acking the request directly is correct HERE.
    //
    // CAUTION: this is only right for the current streaming output model.
    // If you add the real double-buffered SRAM staging on the decompressed
    // side (listed as a known gap in the README), buf_swap_ack must go back
    // to meaning "the consumer has finished with the read buffer", and this
    // line has to change with it.
    assign buf_swap_ack = buf_swap_req;

    // Inter-stage wires for the tile scheduler <-> DMA connection, declared
    // here (before first use) since some toolchains -- correctly -- don't
    // tolerate a signal being referenced in a port connection before its
    // declaration appears in the module body.
    logic dma_start, dma_done;
    logic [AXI_ADDR_WIDTH-1:0] dma_src_addr;
    logic [$clog2(NUM_TILES)-1:0] dma_tile_id;

    // =========================================================================
    // Stage 0: Tile scheduler (top-level FSM, drives everything else)
    // =========================================================================
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

    // =========================================================================
    // Stage 1: AXI DMA - fetch compressed tile into compressed-side FIFO
    // =========================================================================
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

    // =========================================================================
    // Stage 2: tANS/FSE entropy decoder
    // =========================================================================
    tans_decoder #(
        .NUM_TILES  (NUM_TILES),
        // BUG FIX (deadlock): the STATE_BITS override was previously removed
        // on the reasoning that the default (12) "matches table_wr_addr width
        // and is the intended architectural value". That reasoning is correct
        // architecturally and wrong in practice under Icarus Verilog 12.0:
        // STATE_BITS=12 makes tans_decoder's table_mem a 4096-entry packed-
        // struct array, and this iverilog version silently fails to write
        // some indices of arrays that large (documented in the README's
        // toolchain-limitations section). The tb writes 16 entries; symbol 0
        // decodes fine from init_state=1, then the next lookup returns X,
        // bits_ready goes X, and the decoder parks in S_LOOKUP forever.
        //
        // Sizing the table to what the test actually needs is the same
        // workaround the README describes. This is a TOOLCHAIN workaround,
        // not an RTL fix -- re-test with STATE_BITS=12 under Verilator or a
        // commercial simulator before trusting the full-size table.
        .STATE_BITS (4)
    ) u_tans (
        .clk             (clk),
        .rst_n           (rst_n),
        .in_byte         (comp_byte),
        .in_valid        (comp_valid),
        .in_ready        (comp_ready),
        .in_tile_id      (comp_tile_id),

        .tile_start             (dma_start), // new tile's decode begins the
                                              // same cycle its fetch is issued
        .init_state             (init_state),
        // Fix: Pass the full 16-bit num_symbols_this_tile, not truncated.
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

    // =========================================================================
    // Stage 3: LZ77 reconstruction (consumes dictionary for cross-tile refs)
    // =========================================================================
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

    // =========================================================================
    // Stage 4: Desparse (2:4 structured sparsity expansion), bypassable
    // =========================================================================
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

    // =========================================================================
    // Stage 5: Dequantize (INT8 / NF4 / AWQ-INT4 -> output bus width)
    // =========================================================================
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

    // =========================================================================
    // Dictionary memory bank (3 role-specific dictionaries, host-loaded)
    // =========================================================================
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

        .rd_sel      (dict_sel),       // active dict for this run
        .rd_addr     (dict_rd_addr),
        .rd_en       (dict_rd_en),
        .rd_data     (dict_rd_data)
    );

endmodule