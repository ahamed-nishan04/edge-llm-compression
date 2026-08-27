`default_nettype none
`timescale 1ns/1ps

module bloom_filter #(
    parameter HASH_W  = 16,
    parameter POS_W   = 18,
    parameter N_HASH  = 8
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [HASH_W-1:0] hash_in [0:N_HASH-1],
    input  wire [POS_W-1:0]  hash_pos,
    input  wire              hash_valid,
    output reg  [POS_W-1:0]  out_pos,
    output reg               out_maybe_match,
    output reg               out_valid,
    input  wire              wr_en,
    input  wire [HASH_W-1:0] wr_hash [0:N_HASH-1]
);
    reg l1_mem [0:16383];
    reg l2_mem [0:65535];
    reg l3_mem [0:262143];

    integer mem_idx;
    initial begin
        for (mem_idx = 0; mem_idx < 16384; mem_idx = mem_idx + 1) l1_mem[mem_idx] = 1'b0;
        for (mem_idx = 0; mem_idx < 65536; mem_idx = mem_idx + 1) l2_mem[mem_idx] = 1'b0;
        for (mem_idx = 0; mem_idx < 262144; mem_idx = mem_idx + 1) l3_mem[mem_idx] = 1'b0;
    end

    wire [13:0] l1_addr [0:3];
    wire [15:0] l2_addr [0:5];
    wire [17:0] l3_addr [0:3];

    genvar g;
    generate
        for (g = 0; g < 4; g = g+1)
            assign l1_addr[g] = hash_in[g][13:0];
        for (g = 0; g < 6; g = g+1)
            assign l2_addr[g] = hash_in[g][15:0];
        for (g = 0; g < 4; g = g+1)
            assign l3_addr[g] = {hash_in[g*2][15:0], hash_in[g*2+1][1:0]};
    endgenerate

    always @(posedge clk) begin
        if (wr_en) begin
            l1_mem[wr_hash[0][13:0]] <= 1'b1;
            l1_mem[wr_hash[1][13:0]] <= 1'b1;
            l1_mem[wr_hash[2][13:0]] <= 1'b1;
            l1_mem[wr_hash[3][13:0]] <= 1'b1;

            l2_mem[wr_hash[0][15:0]] <= 1'b1;
            l2_mem[wr_hash[1][15:0]] <= 1'b1;
            l2_mem[wr_hash[2][15:0]] <= 1'b1;
            l2_mem[wr_hash[3][15:0]] <= 1'b1;
            l2_mem[wr_hash[4][15:0]] <= 1'b1;
            l2_mem[wr_hash[5][15:0]] <= 1'b1;

            l3_mem[{wr_hash[0][15:0], wr_hash[1][1:0]}] <= 1'b1;
            l3_mem[{wr_hash[2][15:0], wr_hash[3][1:0]}] <= 1'b1;
            l3_mem[{wr_hash[4][15:0], wr_hash[5][1:0]}] <= 1'b1;
            l3_mem[{wr_hash[6][15:0], wr_hash[7][1:0]}] <= 1'b1;
        end
    end

    reg               s1_valid;
    reg [POS_W-1:0]   s1_pos;
    reg               s1_l1_hit;
    reg [HASH_W-1:0]  s1_hash [0:N_HASH-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid  <= 1'b0;
            s1_l1_hit <= 1'b0;
            s1_pos    <= '0;
            for (i = 0; i < N_HASH; i = i+1)
                s1_hash[i] <= '0;
        end else begin
            s1_valid <= hash_valid;
            s1_pos   <= hash_pos;
            s1_l1_hit <= l1_mem[l1_addr[0]] &
                         l1_mem[l1_addr[1]] &
                         l1_mem[l1_addr[2]] &
                         l1_mem[l1_addr[3]];
            for (i = 0; i < N_HASH; i = i+1)
                s1_hash[i] <= hash_in[i];
        end
    end

    reg               s2_valid;
    reg [POS_W-1:0]   s2_pos;
    reg               s2_l2_hit;
    reg [HASH_W-1:0]  s2_hash [0:N_HASH-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid  <= 1'b0;
            s2_l2_hit <= 1'b0;
            s2_pos    <= '0;
            for (i = 0; i < N_HASH; i = i+1)
                s2_hash[i] <= '0;
        end else begin
            s2_valid  <= s1_valid;
            s2_pos    <= s1_pos;
            s2_l2_hit <= s1_l1_hit &
                         l2_mem[s1_hash[0][15:0]] &
                         l2_mem[s1_hash[1][15:0]] &
                         l2_mem[s1_hash[2][15:0]] &
                         l2_mem[s1_hash[3][15:0]] &
                         l2_mem[s1_hash[4][15:0]] &
                         l2_mem[s1_hash[5][15:0]];
            for (i = 0; i < N_HASH; i = i+1)
                s2_hash[i] <= s1_hash[i];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid       <= 1'b0;
            out_maybe_match <= 1'b0;
            out_pos         <= '0;
        end else begin
            out_valid       <= s2_valid;
            out_pos         <= s2_pos;
            out_maybe_match <= s2_l2_hit &
                               l3_mem[{s2_hash[0][15:0], s2_hash[1][1:0]}] &
                               l3_mem[{s2_hash[2][15:0], s2_hash[3][1:0]}] &
                               l3_mem[{s2_hash[4][15:0], s2_hash[5][1:0]}] &
                               l3_mem[{s2_hash[6][15:0], s2_hash[7][1:0]}];
        end
    end

endmodule
`default_nettype wire
