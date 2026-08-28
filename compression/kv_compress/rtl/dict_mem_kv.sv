// =============================================================================
// dict_mem_kv.sv
// Single-bank dictionary memory holding D_KV only (this compressor is KV-
// path-only, unlike the decompressor which selects among D_W/D_F/D_KV).
// Structurally identical to decompression's dict_mem.sv with NUM_DICTS=1
// hardcoded away -- kept as a separate small file rather than importing
// the decompression project's dict_mem.sv directly so this project stays
// self-contained; if you'd rather share one file across both projects,
// dict_mem.sv with NUM_DICTS=1 works as a drop-in replacement for this.
// =============================================================================

module dict_mem_kv #(
    parameter int DICT_DEPTH_BYTES = 32768
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                                wr_en,
    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] wr_addr,
    input  logic [7:0]                          wr_data,

    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] rd_addr,
    input  logic                                rd_en,
    output logic [7:0]                          rd_data
);

    logic [7:0] mem [0:DICT_DEPTH_BYTES-1];

    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    logic [7:0] rd_data_q;
    always_ff @(posedge clk) begin
        if (rd_en) rd_data_q <= mem[rd_addr];
    end
    assign rd_data = rd_data_q;

endmodule
