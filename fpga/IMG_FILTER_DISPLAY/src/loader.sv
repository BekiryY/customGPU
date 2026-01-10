module loader #(
    parameter DATA_WIDTH = 8,
    parameter FILTER_SIZE = 3
) 
(
    // System Inputs
    input  wire        clk,
    input  wire        rst_n,      // Active low system reset
    input  wire        i_vsync,    // Active low Vertical Sync (Frame Reset)
    
    // User interface
    input  wire        i_next,     // Request next data (read enable)
    output wire [7:0]  o_data,     // Data output (8-bit grayscale)
    output wire        o_valid     // Data is valid (FIFO not empty)
);

    //-----------------------------------------------------
    // Parameters
    //-----------------------------------------------------
    localparam MAX_ADDR       = 16'hFFFF;        // 16-bit address depth (65536)
    localparam START_ADDR     = 16'd14;          // Skip first 10 pixels due to bootrom latency
    localparam IMG_W          = 225;

    //-----------------------------------------------------
    // Internal Signals
    //-----------------------------------------------------
    // PROM Signals
    wire [7:0]  prom_dout;
    reg  [15:0] prom_addr;
    wire        prom_ce;
    reg         prom_valid_q; 
    reg         prom_valid_q2;
    
    // Filter Mode Signals
    logic [DATA_WIDTH-1:0] line_buffs [FILTER_SIZE-1][IMG_W]; // Line Buffers (K-1 lines)
    logic [DATA_WIDTH-1:0] window [FILTER_SIZE][FILTER_SIZE]; // KxK Window
    logic [7:0] lb_wr_ptr;    // Line Buffer Write Pointer
    
    reg   [7:0] filter_row_cnt;
    logic       filter_priming_done;
    
    //-----------------------------------------------------
    // 1. PROM Control Logic (Filter Mode Only)
    //-----------------------------------------------------
    
    // Read if we need to prime (fill buffers) OR if Display Requests (i_next).
    // Stops reading if we reach the end of the image.
    assign prom_ce = (!filter_priming_done || i_next) && (prom_addr < 16'd50624);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prom_addr      <= START_ADDR;
            prom_valid_q   <= 1'b0;
            prom_valid_q2  <= 1'b0;
        end else begin
            if (!i_vsync) begin
                // Frame Sync Reset
                prom_addr      <= START_ADDR;
                prom_valid_q   <= 1'b0;
                prom_valid_q2  <= 1'b0;
            end 
            else if (prom_ce) begin
                prom_valid_q <= 1'b1;

                // --- Linear Addressing ---
                if (prom_addr == 16'd50624) // End of Image
                     prom_addr <= START_ADDR;
                else
                     prom_addr <= prom_addr + 1'b1;

            end else begin
                prom_valid_q <= 1'b0;
            end
            
            // Delays valid signal to match Data arrival time
            prom_valid_q2 <= prom_valid_q;
        end
    end

    //-----------------------------------------------------
    // 2. Instantiate PROM
    //-----------------------------------------------------
    Gowin_pROM u_prom (
        .dout  (prom_dout),   
        .clk   (clk),         
        .oce   (1'b1),        
        .ce    (prom_ce),     
        .reset (~rst_n),
        .ad    (prom_addr)    
    );

    //-----------------------------------------------------
    // 3. Line Buffer & Window Logic (Filter Pipeline)
    //-----------------------------------------------------
    
    // Line Buffer Management
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lb_wr_ptr <= 0;
            filter_row_cnt <= 0;
            filter_priming_done <= 0;
        end else begin
            if (!i_vsync) begin
                lb_wr_ptr <= 0;
                filter_row_cnt <= 0;
                filter_priming_done <= 0; // Trigger priming on new frame
            end else if (prom_valid_q2) begin
                // Update Line Buffers with NEWEST pixel (Row 0)
                
                // Column Management
                if (lb_wr_ptr == IMG_W - 1) begin
                    lb_wr_ptr <= 0;
                    // Count full rows filled
                    if (filter_row_cnt < FILTER_SIZE)
                        filter_row_cnt <= filter_row_cnt + 1'b1;
                    else
                        filter_priming_done <= 1'b1; // Done enough priming
                end else begin
                    lb_wr_ptr <= lb_wr_ptr + 1'b1;
                end
                
                // Push data to LineBuffers: Shift Up
                // Buffer[0] gets new pixel (Row 0)
                // Buffer[1] gets old Buffer[0] (Row 1) -> but shifted in memory not signal
                // Actually, line_buffs[0] is Row 1 because Row 0 is directly from PROM?
                // Wait. 
                // Let's standardise:
                // Row 0: Newest Pixel (from PROM)
                // Row 1: Line Buffer 0
                // Row 2: Line Buffer 1
                
                // So we write PROM -> Line Buffer 0.
                // And Line Buffer 0 -> Line Buffer 1...
                
                line_buffs[0][lb_wr_ptr] <= prom_dout;
                for (int k = 1; k < FILTER_SIZE - 1; k++) begin
                    line_buffs[k][lb_wr_ptr] <= line_buffs[k-1][lb_wr_ptr];
                end
            end
        end
    end

    // Window Construction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
             for(int r=0; r<FILTER_SIZE; r++)
                for(int c=0; c<FILTER_SIZE; c++)
                    window[r][c] <= 0;
        end else begin
            if (prom_valid_q2) begin
                // Shift Window Left
                for(int r=0; r<FILTER_SIZE; r++) begin
                    for(int c=FILTER_SIZE-1; c>0; c--) begin
                        window[r][c] <= window[r][c-1];
                    end
                end
                
                // Load New Column at Col 0
                // Row 0 is from PROM
                window[0][0] <= prom_dout;
                
                // Other Rows from Line Buffers (current pointer position)
                // Since we write to the buffer at the same cycle, we are reading OLD value (Non-blocking <=)
                // This is correct: We want what was there BEFORE we overwrote it with new pixel.
                for (int k = 0; k < FILTER_SIZE - 1; k++) begin
                    window[k+1][0] <= line_buffs[k][lb_wr_ptr];
                end
            end
        end
    end
    
    // Filter Instantiation
    GAUS_BLUR_FILTER #(
        .K(FILTER_SIZE),
        .DATA_W(DATA_WIDTH)
    ) u_gaus_blur_filter (
        .clk(clk),
        .rst_n(rst_n),
        // Only valid if we had valid PROM data AND we have finished priming buffers
        .i_valid(prom_valid_q2 && filter_priming_done), 
        .window(window),
        .o_valid(o_valid),
        .pixel_out(o_data)
    );
    
    // NOTE: GAUS_BLUR_FILTER output port name check:
    // User file: output logic [DATA_W-1:0] pixel_out
    // I should check if I need to change o_data port mapping.
    // Wait, let me check the GAUS_BLUR_FILTER definition in my context.
    
endmodule
