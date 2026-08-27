`default_nettype none
`timescale 1ns/1ps

module cam_array #(
    parameter N_BANKS      = 32,
    parameter ENTRIES_LOG  = 12,
    parameter KEY_W        = 32,
    parameter OFFSET_W     = 23,
    parameter POS_W        = 18,
    parameter HASH_W       = 16,
    parameter N_HASHES     = 8,
    parameter MAX_MATCHES  = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [POS_W-1:0]        query_pos,
    input  wire [KEY_W-1:0]        query_key,
    input  wire [HASH_W-1:0]       query_hash [0:N_HASHES-1],
    input  wire                    query_valid,
    output reg  [POS_W-1:0]        match_pos,
    output reg  [OFFSET_W-1:0]     match_offsets [0:MAX_MATCHES-1],
    output reg  [MAX_MATCHES-1:0]  match_valid_vec,
    output reg  [5:0]              match_count,
    output reg                     result_valid,
    input  wire                    insert_en,
    input  wire [POS_W-1:0]        insert_pos,
    input  wire [KEY_W-1:0]        insert_key,
    input  wire [HASH_W-1:0]       insert_hash [0:N_HASHES-1]
);
    reg [KEY_W-1:0]    bank_key   [0:N_BANKS-1][0:(1<<ENTRIES_LOG)-1];
    reg [OFFSET_W-1:0] bank_pos   [0:N_BANKS-1][0:(1<<ENTRIES_LOG)-1];
    reg                bank_valid [0:N_BANKS-1][0:(1<<ENTRIES_LOG)-1];
    integer b_idx, e_idx;
    initial begin
        for (b_idx = 0; b_idx < N_BANKS; b_idx = b_idx + 1) begin
            for (e_idx = 0; e_idx < (1<<ENTRIES_LOG); e_idx = e_idx + 1) begin
                bank_valid[b_idx][e_idx] = 1'b0;
            end
        end
    end

    wire [ENTRIES_LOG-1:0] rd_idx [0:N_BANKS-1];
    genvar g;
    generate
        for (g = 0; g < N_BANKS; g = g+1)
            assign rd_idx[g] = query_hash[g % N_HASHES][ENTRIES_LOG-1:0];
    endgenerate

    reg [$clog2(N_BANKS)-1:0] wr_bank_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank_sel <= '0;
        end else if (insert_en) begin
            bank_key  [wr_bank_sel][insert_hash[wr_bank_sel % N_HASHES][ENTRIES_LOG-1:0]]
                <= insert_key;
            bank_pos  [wr_bank_sel][insert_hash[wr_bank_sel % N_HASHES][ENTRIES_LOG-1:0]]
                <= insert_pos[OFFSET_W-1:0];
            bank_valid[wr_bank_sel][insert_hash[wr_bank_sel % N_HASHES][ENTRIES_LOG-1:0]]
                <= 1'b1;
            wr_bank_sel <= wr_bank_sel + 1;
        end
    end

    reg [KEY_W-1:0]    s1_key    [0:N_BANKS-1];
    reg [OFFSET_W-1:0] s1_pos_r  [0:N_BANKS-1];
    reg                s1_valid_r[0:N_BANKS-1];
    reg [POS_W-1:0]    s1_qpos;
    reg [KEY_W-1:0]    s1_qkey;
    reg                s1_qvalid;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_qvalid <= 1'b0;
            s1_qpos   <= '0;
            s1_qkey   <= '0;
            for (i = 0; i < N_BANKS; i = i+1) begin
                s1_key[i]     <= '0;
                s1_pos_r[i]   <= '0;
                s1_valid_r[i] <= 1'b0;
            end
        end else begin
            s1_qvalid <= query_valid;
            s1_qpos   <= query_pos;
            s1_qkey   <= query_key;
            for (i = 0; i < N_BANKS; i = i+1) begin
                s1_key[i]     <= bank_key  [i][rd_idx[i]];
                s1_pos_r[i]   <= bank_pos  [i][rd_idx[i]];
                s1_valid_r[i] <= bank_valid[i][rd_idx[i]];
            end
        end
    end

    reg [N_BANKS-1:0]  s2_hit_mask;
    reg [OFFSET_W-1:0] s2_offsets [0:N_BANKS-1];
    reg [POS_W-1:0]    s2_qpos;
    reg                s2_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid    <= 1'b0;
            s2_qpos     <= '0;
            s2_hit_mask <= '0;
            for (i = 0; i < N_BANKS; i = i+1)
                s2_offsets[i] <= '0;
        end else begin
            s2_valid <= s1_qvalid;
            s2_qpos  <= s1_qpos;
            for (i = 0; i < N_BANKS; i = i+1) begin
                s2_hit_mask[i] <= s1_valid_r[i] & (s1_key[i] == s1_qkey);
                s2_offsets[i]  <= s1_pos_r[i];
            end
        end
    end

    reg [OFFSET_W-1:0]  c_offsets [0:MAX_MATCHES-1];
    reg [MAX_MATCHES-1:0] c_valid_vec;
    reg [5:0]             c_count;
    always @(*) begin
        integer j;
        reg [5:0] cnt;
        cnt        = 6'd0;
        c_valid_vec = '0;
        for (j = 0; j < MAX_MATCHES; j = j+1)
            c_offsets[j] = '0;
        for (j = 0; j < N_BANKS; j = j+1) begin
            if (s2_hit_mask[j] && (cnt < MAX_MATCHES)) begin
                c_offsets[cnt]   = s2_offsets[j];
                c_valid_vec[cnt] = 1'b1;
                cnt              = cnt + 1;
            end
        end
        c_count = cnt;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid    <= 1'b0;
            match_count     <= 6'd0;
            match_valid_vec <= '0;
            match_pos       <= '0;
            for (i = 0; i < MAX_MATCHES; i = i+1)
                match_offsets[i] <= '0;
        end else begin
            result_valid    <= s2_valid;
            match_pos       <= s2_qpos;
            match_count     <= c_count;
            match_valid_vec <= c_valid_vec;
            for (i = 0; i < MAX_MATCHES; i = i+1)
                match_offsets[i] <= c_offsets[i];
        end
    end

endmodule
`default_nettype wire
