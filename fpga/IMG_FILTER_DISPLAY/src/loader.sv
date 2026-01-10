module loader (
    // System Inputs
    input  wire        clk,
    input  wire        rst_n,      // Active low system reset
    input  wire        i_vsync,    // Active low Vertical Sync (Frame Reset)
    
    // User interface (FIFO Read)
    input  wire        filter_en,
    input  wire        i_next,     // Request next data (read enable)
    output wire [7:0]  o_data,     // Data output (8-bit grayscale)
    output wire        o_valid     // Data is valid (FIFO not empty)
);

    //-----------------------------------------------------
    // Parameters
    //-----------------------------------------------------
    localparam MAX_ADDR       = 16'hFFFF;        // 16-bit address depth (65536)
    localparam FIFO_DEPTH_BIT = 8;               // 256 words
    localparam FIFO_DEPTH     = (1 << FIFO_DEPTH_BIT);
    localparam THRESHOLD      = FIFO_DEPTH - 4; 
    localparam START_ADDR     = 16'd10;          // Skip first 10 pixels due to bootrom latency

    //-----------------------------------------------------
    // Internal Signals
    //-----------------------------------------------------
    // PROM Signals
    wire [7:0]  prom_dout;
    reg  [15:0] prom_addr;
    wire        prom_ce;
    reg         prom_valid_q; 
    reg         prom_valid_q2;
    
    // FIFO Signals
    wire        fifo_full;
    wire        fifo_empty;
    reg         fifo_wr;
    reg  [7:0]  fifo_din;
    reg  [FIFO_DEPTH_BIT:0] fifo_cnt; 

    // Counters / Flags
    reg  [7:0]  col_cnt;          // Column counter (0..224)
    reg         v_line_repeat;    // Flag to repeat the current line
    reg  [15:0] row_start_addr;   // Start address of the current row

    //-----------------------------------------------------
    // 1. PROM Control Logic
    //-----------------------------------------------------
    // Read continuously if FIFO is not full
    assign prom_ce = (fifo_cnt < THRESHOLD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prom_addr      <= START_ADDR;
            prom_valid_q   <= 1'b0;
            prom_valid_q2  <= 1'b0;
            col_cnt        <= 0;
            v_line_repeat  <= 0;
            row_start_addr <= START_ADDR;
        end else begin
            if (!i_vsync) begin
                // Frame Sync Reset
                prom_addr      <= START_ADDR;
                prom_valid_q   <= 1'b0;
                prom_valid_q2  <= 1'b0;
                col_cnt        <= 0;
                v_line_repeat  <= 0;
                row_start_addr <= START_ADDR;
            end else if (prom_ce) begin
                // Normal Read Operation
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
                        row_start_addr <= prom_addr + 1'b1; 
                        
                        // Check for total image end
                        if (prom_addr == 16'd50624) begin
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
    // 3. FIFO Write Logic
    //-----------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr  <= 1'b0;
            fifo_din <= 0;
        end else begin
            if (!i_vsync) begin
                 fifo_wr <= 1'b0;
            end else begin
                // Default low
                fifo_wr <= 1'b0; 
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
    reg h_scale_skip; 

    // Write Side
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else begin
            if (!i_vsync) begin
                wr_ptr <= 0;
            end else if (fifo_wr) begin
                mem[wr_ptr] <= fifo_din;
                wr_ptr      <= wr_ptr + 1'b1;
            end
        end
    end

    // Read Side (Upscaling)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr       <= 0;
            h_scale_skip <= 0;
        end else begin
            if (!i_vsync) begin
                rd_ptr       <= 0;
                h_scale_skip <= 0;
            end else if (i_next && !fifo_empty) begin
                // 0: First read (hold ptr), 1: Second read (inc ptr)
                if (h_scale_skip) begin
                    rd_ptr       <= rd_ptr + 1'b1;
                    h_scale_skip <= 0;
                end else begin
                    h_scale_skip <= 1;
                end
            end
        end
    end

    assign fifo_empty = (wr_ptr == rd_ptr);
    assign o_valid    = !fifo_empty;
    assign o_data     = mem[rd_ptr];

    //-----------------------------------------------------
    // 5. FIFO Count Tracking
    //-----------------------------------------------------
    wire real_read_event = (i_next && !fifo_empty && h_scale_skip);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_cnt <= 0;
        end else begin
            if (!i_vsync) begin
                fifo_cnt <= 0;
            end else begin
                case ({fifo_wr, real_read_event})
                    2'b10: fifo_cnt <= fifo_cnt + 1'b1; // Write, no read
                    2'b01: fifo_cnt <= fifo_cnt - 1'b1; // Read, no write
                    default: fifo_cnt <= fifo_cnt;
                endcase
            end
        end
    end

    //-----------------------------------------------------
    // 6. Filter Enable
    //-----------------------------------------------------
    GAUS_BLUR_FILTER u_gaus_blur_filter (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_valid (data_valid),
        .i_data  (data_out),
        .o_valid (data_valid),
        .o_data  (data_out)
    );

endmodule
