module loader (
    input  wire        clk,
    input  wire        rst_n,      // Active low system reset
    
    // User interface (FIFO Read)
    input  wire        i_next,     // Request next data (read enable)
    output wire [7:0]  o_data,     // Data output (8-bit grayscale)
    output wire        o_valid     // Data is valid (FIFO not empty)
);

    //-----------------------------------------------------
    // Parameters
    //-----------------------------------------------------
    localparam MAX_ADDR = 16'hFFFF;  // 16-bit address depth (65536)
    localparam FIFO_DEPTH_BIT = 8;   // 256 words (Pixels) - sufficient for buffering
    localparam FIFO_DEPTH = (1 << FIFO_DEPTH_BIT);
    localparam THRESHOLD  = FIFO_DEPTH - 4; 

    //-----------------------------------------------------
    // Internal Signals
    //-----------------------------------------------------
    wire [7:0]  prom_dout;           // 8-bit data from PROM
    reg  [15:0] prom_addr;           // 16-bit address
    wire        prom_ce;
    reg         prom_valid_q; 

    wire        fifo_full;
    wire        fifo_empty;
    reg         fifo_wr;
    reg  [7:0]  fifo_din;            // Write 8-bit data
    
    reg  [FIFO_DEPTH_BIT:0] fifo_cnt; 

    //-----------------------------------------------------
    // 1. PROM Control Logic
    //-----------------------------------------------------
    
    // Read continuously if FIFO is not full
    // Read continuously if FIFO is not full
    assign prom_ce = (fifo_cnt < THRESHOLD);

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            prom_addr <= 16'd0;
            prom_valid_q <= 1'b0;
        end else begin
            if (prom_ce) begin
                if (prom_addr == 16'd50624) // 225*225 - 1
                    prom_addr <= 16'd0;
                else
                    prom_addr <= prom_addr + 1'b1;
                
                prom_valid_q <= 1'b1; // Valid data next cycle
            end else begin
                prom_valid_q <= 1'b0;
            end
        end
    end

    //-----------------------------------------------------
    // 2. Instantiate PROM (New Configuration)
    //-----------------------------------------------------
    Gowin_pROM u_prom (
        .dout(prom_dout),   // 8-bit output
        .clk (clk),         
        .oce (1'b1),        
        .ce  (prom_ce),     
        .reset(~rst_n),
        .ad  (prom_addr)    // 16-bit address
    );

    //-----------------------------------------------------
    // 3. FIFO Write Logic
    //-----------------------------------------------------
    // Directly passing byte from PROM to FIFO
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr <= 1'b0;
            fifo_din <= 0;
        end else begin
            fifo_wr <= 1'b0; // Default

            if (prom_valid_q) begin
                fifo_din <= prom_dout;
                fifo_wr  <= 1'b1;
            end
        end
    end

    //-----------------------------------------------------
    // 4. FIFO Logic (8-bit width)
    //-----------------------------------------------------
    reg [7:0] mem [0:FIFO_DEPTH-1];
    reg [FIFO_DEPTH_BIT-1:0] wr_ptr;
    reg [FIFO_DEPTH_BIT-1:0] rd_ptr;
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            wr_ptr <= 0;
        end else if(fifo_wr) begin
            mem[wr_ptr] <= fifo_din;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    //-----------------------------------------------------
    // 5. Output Logic
    //-----------------------------------------------------
    // Standard FIFO Read
    assign fifo_empty = (wr_ptr == rd_ptr);
    assign o_valid    = !fifo_empty;
    assign o_data     = mem[rd_ptr];

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rd_ptr <= 0;
        end else if(i_next && !fifo_empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    //-----------------------------------------------------
    // 6. FIFO Count Tracking
    //-----------------------------------------------------
    wire read_event = (i_next && !fifo_empty);
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fifo_cnt <= 0;
        end else begin
            case ({fifo_wr, read_event})
                2'b10: fifo_cnt <= fifo_cnt + 1'b1; // Write, no read
                2'b01: fifo_cnt <= fifo_cnt - 1'b1; // Read, no write
                2'b11: fifo_cnt <= fifo_cnt;        // Both
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

endmodule
