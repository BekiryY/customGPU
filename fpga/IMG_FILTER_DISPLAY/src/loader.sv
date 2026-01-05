module loader (
    input  wire        clk,
    input  wire        rst_n,      // Active low system reset
    input  wire        i_vsync,    // Active low Vertical Sync (Frame Reset)
    
    // User interface (FIFO Read)
    input  wire        i_next,     // Request next data (read enable)
    output wire [7:0]  o_data,     // Data output (8-bit grayscale)
    output wire        o_valid     // Data is valid (FIFO not empty)
);

    //-----------------------------------------------------
    // Parameters
    //-----------------------------------------------------
    localparam MAX_ADDR = 16'hFFFF;  // 16-bit address depth (65536)
    localparam FIFO_DEPTH_BIT = 8;   // 256 words - sufficient for buffering
    localparam FIFO_DEPTH = (1 << FIFO_DEPTH_BIT);
    localparam THRESHOLD  = FIFO_DEPTH - 4; 
    localparam START_ADDR = 16'd10;  // Skip first 10 pixels due to bootrom latency

    //-----------------------------------------------------
    // Internal Signals
    //-----------------------------------------------------
    wire [7:0]  prom_dout;           // 8-bit data from PROM
    reg  [15:0] prom_addr;           // 16-bit address
    wire        prom_ce;
    reg         prom_valid_q; 
    reg         prom_valid_q2;       // Pipeline for 2-cycle latency

    wire        fifo_full;
    wire        fifo_empty;
    reg         fifo_wr;
    reg  [7:0]  fifo_din;            // Write 8-bit data
    
    reg  [FIFO_DEPTH_BIT:0] fifo_cnt; 

    //-----------------------------------------------------
    // 1. PROM Control Logic
    //-----------------------------------------------------
    
    reg [7:0]  col_cnt;          // Column counter (0..224)
    reg        v_line_repeat;    // Flag to repeat the current line
    reg [15:0] row_start_addr;   // Start address of the current row

    // Read continuously if FIFO is not full
    assign prom_ce = (fifo_cnt < THRESHOLD);

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            prom_addr      <= START_ADDR;
            prom_valid_q   <= 1'b0;
            prom_valid_q2  <= 1'b0;
            
            // Upscaling counters
            col_cnt        <= 0;
            v_line_repeat  <= 0;
            row_start_addr <= START_ADDR;

        end else begin
            // VSYNC Reset (Frame Sync) - High priority
            if (!i_vsync) begin
                prom_addr      <= START_ADDR;
                prom_valid_q   <= 1'b0;
                prom_valid_q2  <= 1'b0;
                
                col_cnt        <= 0;
                v_line_repeat  <= 0;
                row_start_addr <= START_ADDR;
            end 
            else if (prom_ce) begin
                // Default: Advance address
                // We need to handle the Wrap around and Line Repeat
                
                if (col_cnt == 8'd224) begin
                    // End of a line
                    col_cnt <= 0;
                    
                    if (v_line_repeat == 1'b0) begin
                        // First pass done, repeat the line
                        v_line_repeat <= 1'b1;
                        prom_addr     <= row_start_addr; 
                    end else begin
                        // Second pass done, move to next line
                        v_line_repeat  <= 1'b0;
                        prom_addr      <= prom_addr + 1'b1; 
                        row_start_addr <= prom_addr + 1'b1; // Tracking new start
                        
                        // Check for total image end (225*225)
                        if (prom_addr == 16'd50624) begin
                             // Reset for safety (though Frame Sync should handle this)
                             prom_addr      <= START_ADDR;
                             row_start_addr <= START_ADDR;
                        end
                    end
                end else begin
                    // Middle of a line
                    col_cnt   <= col_cnt + 1'b1;
                    prom_addr <= prom_addr + 1'b1;
                end
                
                prom_valid_q <= 1'b1; 
            end else begin
                prom_valid_q <= 1'b0;
            end
            
            // Delays valid signal to match Data arrival time
            prom_valid_q2 <= prom_valid_q;
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
    // Using Q2 to account for BRAM Latency
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr <= 1'b0;
            fifo_din <= 0;
        end else begin
            // Reset on VSYNC to clear old line data
            if (!i_vsync) begin
                 fifo_wr <= 1'b0;
            end
            else begin
                fifo_wr <= 1'b0; // Default

                if (prom_valid_q2) begin
                    fifo_din <= prom_dout;
                    fifo_wr  <= 1'b1;
                end
            end
        end
    end

    //-----------------------------------------------------
    // 4. FIFO Logic (8-bit width)
    //-----------------------------------------------------
    reg [7:0] mem [0:FIFO_DEPTH-1];
    reg [FIFO_DEPTH_BIT-1:0] wr_ptr;
    reg [FIFO_DEPTH_BIT-1:0] rd_ptr;
    
    // Horizontal Scaling Flag
    // 0: First read (hold ptr), 1: Second read (inc ptr)
    reg h_scale_skip; 

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            wr_ptr <= 0;
        end else begin
            if(!i_vsync) begin
                wr_ptr <= 0; // Reset write pointer on Frame start
            end else if(fifo_wr) begin
                mem[wr_ptr] <= fifo_din;
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    //-----------------------------------------------------
    // 5. Output Logic
    //-----------------------------------------------------
    // Standard FIFO Read w/ Upscaling
    assign fifo_empty = (wr_ptr == rd_ptr);
    assign o_valid    = !fifo_empty;
    assign o_data     = mem[rd_ptr];

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rd_ptr <= 0;
            h_scale_skip <= 0;
        end else begin
            if(!i_vsync) begin
                rd_ptr <= 0; // Reset read pointer on Frame start
                h_scale_skip <= 0;
            end else if(i_next && !fifo_empty) begin
                // Upscaling Logic:
                // If skip is 0: We just output data, don't inc pointer. Set skip=1.
                // If skip is 1: We output data AGAIN, and inc pointer. Set skip=0.
                if (h_scale_skip) begin
                    rd_ptr <= rd_ptr + 1'b1;
                    h_scale_skip <= 0;
                end else begin
                    h_scale_skip <= 1;
                end
            end
        end
    end

    //-----------------------------------------------------
    // 6. FIFO Count Tracking
    //-----------------------------------------------------
    // Only count a read when we actually increment the pointer
    wire real_read_event = (i_next && !fifo_empty && h_scale_skip);
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fifo_cnt <= 0;
        end else begin
            if(!i_vsync) begin
                fifo_cnt <= 0;
            end else begin
                case ({fifo_wr, real_read_event})
                    2'b10: fifo_cnt <= fifo_cnt + 1'b1; // Write, no read
                    2'b01: fifo_cnt <= fifo_cnt - 1'b1; // Read, no write
                    2'b11: fifo_cnt <= fifo_cnt;        // Both
                    default: fifo_cnt <= fifo_cnt;
                endcase
            end
        end
    end
endmodule
