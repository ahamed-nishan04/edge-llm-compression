// =============================================================================
// kv_compress_top.sv
// Real-time KV-cache tile compressor. Used exclusively for the DYNAMIC
// KV_{l,t} -> Tile -> Zstd_{D_KV} -> C_KV path (see paper Section III-F):
// weight/FFN tiles are compressed OFFLINE (software), so they don't need
// a hardware encoder at all -- only freshly generated KV tiles, written
// during autoregressive generation, need to be compressed in real time
// before being retained in the memory hierarchy.
//
// Pipeline (mirrors decompression's stage order, reversed):
//   quant_pack -> LZ77 match finder -> tANS batch encoder -> AXI write
//
// BATCH DESIGN (see model/kv_encoder.c header for the full derivation):
// tANS encoding is a backward pass over the tile's token sequence, so a
// tile must be FULLY buffered (both raw K/V values arriving and the LZ
// token stream they produce) before entropy encoding can start. This is
// not a real-time-breaking constraint for KV cache specifically: the
// attention operation that will eventually read this tile back also
// needs the whole tile written first, so buffering one tile's worth of
// data is already implicit in the KV-cache write path. The added latency
// is one backward pass over the token stream (~TILE_SIZE_BYTES cycles,
// same cost class as the decoder's forward pass) plus match-finding time.
//
// Only ONE dictionary bank (D_KV) is instantiated here -- unlike the
// decompressor (which selects among D_W/D_F/D_KV per tile), this module
// exists ONLY for the KV path, so there's nothing to select.
// =============================================================================

module kv_compress_top #(
    parameter int TILE_SIZE_BYTES   = 4096,
    parameter int NUM_TILES         = 64,
    parameter int MAX_TOKENS_PER_TILE = TILE_SIZE_BYTES * 4, // literal-only
                                                                // worst case;
                                                                // every match
                                                                // token also
                                                                // costs 4
                                                                // symbols for
                                                                // >=4 bytes,
                                                                // so this is
                                                                // a safe
                                                                // upper bound
    parameter int AXI_DATA_WIDTH    = 512,
    parameter int AXI_ADDR_WIDTH    = 40,
    parameter int AXI_ID_WIDTH      = 6,

    parameter int DICT_DEPTH_BYTES  = 32768,
    parameter int MIN_MATCH_LEN     = 4,
    parameter int HASH_BITS         = 10,       // 1024-entry match-finder hash

    parameter int STATE_BITS        = 12,
    parameter int MAX_SYM_BITS      = 9,
    parameter int MAX_NB_BITS       = 16,

    parameter int QUANT_MODE_WIDTH  = 2,

    parameter int TILE_ADDR_WIDTH   = $clog2(TILE_SIZE_BYTES)
) (
    input  logic clk,
    input  logic rst_n,

    // ---------------- Control ----------------
    input  logic                        start,
    input  logic [AXI_ADDR_WIDTH-1:0]   dst_base_addr,      // where to write compressed bytes
    input  logic [$clog2(NUM_TILES)-1:0] tile_id,
    input  logic [QUANT_MODE_WIDTH-1:0] quant_mode,
    input  logic signed [15:0]          quant_scale,
    input  logic signed [7:0]           quant_zero,

    output logic                        busy,
    output logic                        done,
    output logic [31:0]                 compressed_bytes,   // for KV-cache
                                                              // tile-index
                                                              // metadata
    output logic [STATE_BITS-1:0]       out_init_state,      // transmit
                                                              // alongside
                                                              // compressed
                                                              // bytes, same
                                                              // as decoder's
                                                              // init_state
                                                              // input
    output logic                        error,

    // ---------------- Raw K/V input (one element per cycle, e.g. from the
    // attention output register file) ----------------------------------
    input  logic [31:0]                 kv_data_in,   // fp32 raw value
    input  logic                        kv_data_valid,
    output logic                        kv_data_ready,
    input  logic                        kv_data_last,       // last element of this tile

    // ---------------- AXI-512 write master (compressed tile out) -------
    output logic [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]                  m_axi_awlen,
    output logic [2:0]                  m_axi_awsize,
    output logic [AXI_ID_WIDTH-1:0]     m_axi_awid,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awready,
    output logic [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output logic                        m_axi_wlast,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wready,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_bready,

    // ---------------- D_KV dictionary (read-only here; loaded/maintained
    // by the same dict_mem instance the decompressor reads) -------------
    output logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_rd_addr,
    input  logic [7:0]                          dict_rd_data,
    output logic                                dict_rd_en
);

    // =========================================================================
    // Stage 1: quantize raw fp32 K/V values to INT8, buffer into tile SRAM
    // =========================================================================
    logic [7:0]  quant_byte;
    logic        quant_valid, quant_ready, quant_last;
    logic [TILE_ADDR_WIDTH-1:0] quant_offset;

    quant_pack #(
        .TILE_ADDR_WIDTH (TILE_ADDR_WIDTH)
    ) u_quant (
        .clk           (clk),
        .rst_n         (rst_n),
        .quant_mode    (quant_mode),
        .scale         (quant_scale),
        .zero          (quant_zero),

        .in_data       (kv_data_in),
        .in_valid      (kv_data_valid),
        .in_ready      (kv_data_ready),
        .in_last       (kv_data_last),

        .out_byte      (quant_byte),
        .out_valid     (quant_valid),
        .out_ready     (quant_ready),
        .out_last      (quant_last),
        .out_offset    (quant_offset)
    );

    // =========================================================================
    // Stage 2: LZ77 match finder (hash-based, single forward pass, real-time)
    // =========================================================================
    logic [8:0]  tok_symbol;      // 0-255 literal, 256 = ESCAPE
    logic        tok_valid, tok_ready, tok_last;
    logic [$clog2(MAX_TOKENS_PER_TILE)-1:0] tok_count;

    lz_match_finder #(
        .TILE_SIZE_BYTES    (TILE_SIZE_BYTES),
        .DICT_DEPTH_BYTES   (DICT_DEPTH_BYTES),
        .MIN_MATCH_LEN      (MIN_MATCH_LEN),
        .HASH_BITS          (HASH_BITS),
        .MAX_TOKENS_PER_TILE(MAX_TOKENS_PER_TILE)
    ) u_lz (
        .clk            (clk),
        .rst_n          (rst_n),

        .in_byte        (quant_byte),
        .in_valid       (quant_valid),
        .in_ready       (quant_ready),
        .in_last        (quant_last),
        .in_offset      (quant_offset),

        .dict_rd_addr   (dict_rd_addr),
        .dict_rd_data   (dict_rd_data),
        .dict_rd_en     (dict_rd_en),

        .out_symbol     (tok_symbol),
        .out_valid      (tok_valid),
        .out_ready      (tok_ready),
        .out_last       (tok_last),
        .out_tok_count  (tok_count)
    );

    // =========================================================================
    // Stage 3: tANS batch encoder (buffers tokens, builds freq table, runs
    // backward encode pass, streams compressed bytes out)
    // =========================================================================
    logic [7:0]  comp_byte;
    logic        comp_valid, comp_ready, comp_last;

    tans_encoder #(
        .MAX_TOKENS_PER_TILE (MAX_TOKENS_PER_TILE),
        .STATE_BITS          (STATE_BITS),
        .MAX_SYM_BITS        (MAX_SYM_BITS),
        .MAX_NB_BITS         (MAX_NB_BITS)
    ) u_tans_enc (
        .clk             (clk),
        .rst_n           (rst_n),

        .in_symbol       (tok_symbol),
        .in_valid        (tok_valid),
        .in_ready        (tok_ready),
        .in_last         (tok_last),
        .in_tok_count    (tok_count),

        .out_byte        (comp_byte),
        .out_valid       (comp_valid),
        .out_ready       (comp_ready),
        .out_last        (comp_last),
        .out_init_state  (out_init_state),
        .out_total_bytes (compressed_bytes)
    );

    // =========================================================================
    // Stage 4: AXI write master
    // =========================================================================
    axi_dma_if_wr #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH)
    ) u_dma_wr (
        .clk            (clk),
        .rst_n          (rst_n),
        .dst_addr       (dst_base_addr),

        .in_byte        (comp_byte),
        .in_valid       (comp_valid),
        .in_ready       (comp_ready),
        .in_last        (comp_last),

        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awid     (m_axi_awid),
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wlast    (m_axi_wlast),
        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),

        .busy           (busy),
        .done           (done),
        .error          (error)
    );

endmodule
