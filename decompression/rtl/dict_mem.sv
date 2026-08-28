// =============================================================================
// dict_mem.sv
// Holds NUM_DICTS role-specific dictionaries (default 3: weights / KV / FFN),
// each DICT_DEPTH_BYTES deep. Host writes dictionaries once at init (or on
// dictionary refresh); LZ reconstruct stage reads whichever bank is active
// for the current tile via rd_sel.
//
// Implemented as NUM_DICTS separate single-port BRAMs (simplest to infer
// cleanly in synthesis) rather than one bank-selected wide memory -- avoids
// a mux on the write path and lets all 3 dictionaries be reloaded
// independently/concurrently if you later add multiple write ports.
// =============================================================================

module dict_mem #(
    parameter int NUM_DICTS        = 3,
    parameter int DICT_DEPTH_BYTES = 32768,
    parameter int DICT_SEL_WIDTH   = $clog2(NUM_DICTS)
) (
    input  logic clk,
    input  logic rst_n,

    // ---------------- Write (host-programmed) ----------------
    input  logic                              wr_en,
    input  logic [DICT_SEL_WIDTH-1:0]         wr_sel,
    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] wr_addr,
    input  logic [7:0]                        wr_data,

    // ---------------- Read (LZ reconstruct stage) ----------------
    input  logic [DICT_SEL_WIDTH-1:0]         rd_sel,
    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] rd_addr,
    input  logic                              rd_en,
    output logic [7:0]                        rd_data
);

    logic [7:0] banks [0:NUM_DICTS-1][0:DICT_DEPTH_BYTES-1];

    genvar g;
    generate
        for (g = 0; g < NUM_DICTS; g++) begin : g_bank_write
            always_ff @(posedge clk) begin
                if (wr_en && wr_sel == g) begin
                    banks[g][wr_addr] <= wr_data;
                end
            end
        end
    endgenerate

    // Registered read (1-cycle latency, matches typical BRAM inference)
    logic [7:0] rd_data_q;
    always_ff @(posedge clk) begin
        if (rd_en) begin
            rd_data_q <= banks[rd_sel][rd_addr];
        end
    end
    assign rd_data = rd_data_q;

    // Named aliases for readability / waveform debug (dict roles per your
    // design doc: 0=weights, 1=KV cache, 2=FFN)
    // synthesis translate_off
    initial begin
        if (NUM_DICTS != 3)
            $display("dict_mem: NUM_DICTS != 3, weights/KV/FFN aliasing in comments no longer applies");
    end
    // synthesis translate_on

endmodule
