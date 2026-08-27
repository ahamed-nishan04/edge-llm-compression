module tile_scheduler #(
    parameter int NUM_TILES        = 64,
    parameter int NUM_DOUBLE_BUFS  = 2,
    parameter int AXI_ADDR_WIDTH   = 40,
    parameter int TILE_SIZE_BYTES  = 4096
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                          start,
    input  logic [AXI_ADDR_WIDTH-1:0]     src_base_addr,
    input  logic [AXI_ADDR_WIDTH-1:0]     dst_base_addr,
    input  logic [$clog2(NUM_TILES+1)-1:0]  num_tiles_this_run, 

    output logic                          busy,
    output logic                          done,
    output logic [31:0]                   tiles_completed,
    output logic                          error,
    output logic [3:0]                    error_code,

    output logic                          dma_start,
    output logic [AXI_ADDR_WIDTH-1:0]     dma_src_addr,
    output logic [$clog2(NUM_TILES)-1:0]  dma_tile_id,
    input  logic                          dma_done,

    input  logic                          pipe_tile_done,

    output logic [$clog2(NUM_DOUBLE_BUFS)-1:0] active_wr_buf,
    output logic [$clog2(NUM_DOUBLE_BUFS)-1:0] active_rd_buf,
    output logic                               buf_swap_req,
    input  logic                               buf_swap_ack
);

    typedef enum logic [2:0] {
        S_IDLE, S_ISSUE_FETCH, S_WAIT_FETCH, S_WAIT_DRAIN, S_SWAP, S_NEXT, S_DONE, S_ERROR
    } state_e;
    state_e st, st_n;

    logic [$clog2(NUM_TILES)-1:0] tile_ctr;
    logic [$clog2(NUM_DOUBLE_BUFS)-1:0] wr_buf_ctr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_IDLE       : if (start) begin
                                if (num_tiles_this_run == 0) st_n = S_ERROR;
                                else                          st_n = S_ISSUE_FETCH;
                            end
            S_ISSUE_FETCH: st_n = S_WAIT_FETCH;
            S_WAIT_FETCH : if (dma_done) st_n = S_WAIT_DRAIN;
            S_WAIT_DRAIN : if (pipe_tile_done) st_n = S_SWAP;
            S_SWAP       : if (buf_swap_ack) st_n = S_NEXT;
            S_NEXT       : begin
                                if (tile_ctr == num_tiles_this_run - 1) st_n = S_DONE;
                                else                                     st_n = S_ISSUE_FETCH;
                            end
            S_DONE       : st_n = S_IDLE;
            S_ERROR      : st_n = S_IDLE;
            default      : st_n = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_ctr        <= '0;
            wr_buf_ctr       <= '0;
            tiles_completed <= '0;
            dma_start       <= 1'b0;
            buf_swap_req    <= 1'b0;
            error           <= 1'b0;
            error_code      <= '0;
            done            <= 1'b0;
        end else begin
            dma_start    <= 1'b0;
            buf_swap_req <= 1'b0;
            done         <= 1'b0;
            error        <= 1'b0;

            unique case (st)
                S_IDLE: if (start) begin
                    tile_ctr        <= '0;
                    wr_buf_ctr       <= '0;
                    tiles_completed <= '0;
                end

                S_ISSUE_FETCH: begin
                    dma_start    <= 1'b1;
                    dma_src_addr <= src_base_addr + (tile_ctr * TILE_SIZE_BYTES);
                    dma_tile_id  <= tile_ctr;
                end

                S_SWAP: begin
                    buf_swap_req <= 1'b1;
                    if (buf_swap_ack) begin
                        wr_buf_ctr      <= (wr_buf_ctr == NUM_DOUBLE_BUFS-1) ? '0 : wr_buf_ctr + 1;
                        tiles_completed <= tiles_completed + 1;
                    end
                end

                S_NEXT: begin
                    if (tile_ctr != num_tiles_this_run - 1)
                        tile_ctr <= tile_ctr + 1;
                end

                S_DONE: begin
                    done <= 1'b1;
                end

                S_ERROR: begin
                    error      <= 1'b1;
                    error_code <= 4'd1; 
                end

                default: ;
            endcase
        end
    end

    assign busy          = (st != S_IDLE) && (st != S_DONE);
    assign active_wr_buf = wr_buf_ctr;
    assign active_rd_buf = (wr_buf_ctr == 0) ? NUM_DOUBLE_BUFS-1 : wr_buf_ctr - 1;

endmodule
