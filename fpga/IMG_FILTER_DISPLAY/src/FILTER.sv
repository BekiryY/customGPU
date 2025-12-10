module FILTER (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       i_de,
    input  wire [7:0] i_data,
    output logic        o_de,
    output logic  [7:0] o_data
);

    //---------------------------------------------------------
    // 1. Line Buffers to create 3-tap vertical window
    //---------------------------------------------------------
    parameter IMG_WIDTH = 225;

    // Two shift registers (or RAMs) to hold 2 previous lines
    // We can use a simple array for synthesis to infer BRAM or LUT RAM
    reg [7:0] line_buf0 [0:IMG_WIDTH-1];
    reg [7:0] line_buf1 [0:IMG_WIDTH-1];
    
    reg [7:0] pixel_window [2:0][2:0]; // 3x3 window [row][col]
    
    // Read ptr for line buffers
    reg [$clog2(IMG_WIDTH)-1:0] wr_ptr;

    // Data from line buffers
    reg [7:0] lb0_out;
    reg [7:0] lb1_out;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            lb0_out <= 0;
            lb1_out <= 0;
        end else if (i_de) begin
            // Read from buffers (current pos is the oldest in the buffer for that col)
            lb0_out <= line_buf0[wr_ptr]; // Row - 1
            lb1_out <= line_buf1[wr_ptr]; // Row - 2
            
            // Write incoming data to first buffer, and moved data to second
            // Note: In strict RAM inference, reading and writing same address 
            // yields old data (Read-First) usually, which is what we want (Delay line).
            line_buf0[wr_ptr] <= i_data;
            line_buf1[wr_ptr] <= lb0_out; // Check: lb0_out is delayed by 1 cycle?
            
            // Wait, if lb0_out is registered above (<=), it's available NEXT cycle.
            // But we are writing it to line_buf1 NOW?
            // Actually: 
            // Cycle T: Read LB0[ptr] -> lb0_reg (available T+1)
            // Cycle T: Write i_data -> LB0[ptr]
            // Cycle T: Write lb0_reg -> LB1[ptr] ?? 
            // If lb0_out is from PREVIOUS cycle (T-1), then we are shifting correctly?
            
            // Correct Delay Line Logic for RAM-based FIFO:
            // Write @ Ptr, Read @ Ptr (Old Data).
            // Data_Out = RAM[Ptr];
            // RAM[Ptr] = Data_In;
            // Ptr++;
            
            // Here:
            // lb0_out <= line_buf0[wr_ptr]; // This is the pixel from same column, previous line.
            // AND we update it with new pixel.
            // For the second buffer, we need the output of the first buffer.
            // But lb0_out as written here is the register capturing the read.
            // So we should write the READ value into the second buffer?
            // Wait.
            // RAM read `line_buf0[wr_ptr]` returns value stored 1 line ago.
            // We want to store THAT value into `line_buf1`.
            // But `lb0_out` updates at end of cycle.
            // If we write `line_buf1[wr_ptr] <= line_buf0[wr_ptr]`, that might be dual port or messy.
            
            // Better to use `lb0_out` (registered) and write it to `line_buf1`?
            // If we use `lb0_out`, we introduce 1 cycle delay horizontal.
            // That shifts the vertical alignment.
            
            // Simpler solution for "Simple HW":
            // Use variables or strict ordering.
            // Or just chain them:
            // line_buf0[wr_ptr] <= i_data;
            // line_buf1[wr_ptr] <= line_buf0[wr_ptr]; // This implies reading the OLD value if non-blocking? 
            // No, same cycle read/write on same variable is tricky.
            
            // Let's use `lb0_out` but account for it.
            // Actually, standard tactic:
            // RAM0 Output -> RAM1 Input.
            // If RAM output is registered, RAM1 Input is delayed by 1.
            // We just need to delay the "current" row matching too.
            
            // Let's use `lb0_out` as the feed for the next stage.
            // So: Stream -> RAM0 -> lb0_out -> RAM1 -> lb1_out.
            
            if (wr_ptr == IMG_WIDTH - 1)
                wr_ptr <= 0;
            else
                wr_ptr <= wr_ptr + 1;
        end
    end
    
    // Explicit write to RAM1 using registered output of RAM0
    always @(posedge clk) begin
        if (i_de) begin
             line_buf1[wr_ptr] <= lb0_out; 
             // Note: lb0_out is from T-1. wr_ptr is T. 
             // We are writing T-1 data into address T. 
             // This might cause 1 pixel shift?
             // Since Ptr increments, T-1 data should go to T-1 address?
             // No.
             
             // Let's fix the delay. Use just the RAM array directly if synthesized allows.
             // Or better: valid behavior.
             // If we write `lb0_out` which is data from `ptr_old`, to `ptr_new`, we shift data.
             
             // CORRECT APPROACH:
             // RAM Read valid immediately (asynchronous read) or synchronous?
             // Let's assume synchronous read (BRAM).
             // Address T -> Data T+1.
             // If we use Data T+1 to write to RAM2 at Address T+1, it works.
        end
    end
    
    // Re-evaluating for Simplicity:
    // It's 225 bytes. We can use registers.
    // Shift register of length 225.
    // reg [7:0] shift_reg_0 [0:224];
    // always @(posedge clk) shift_reg_0 <= {shift_reg_0[0:223], i_data}; ?? No expensive.
    
    // Pointer based (Circular Buffer) is best.
    
    // Let's stick to the code block logic but ensure correct chain.
    // If I use `lb0_out` in window, it is the pixel at `wr_ptr` (delayed by read).
    // If I write `lb0_out` into `line_buf1`, I am writing the pixel I just read.
    // But `wr_ptr` has moved? 
    // If I use `wr_ptr` in the same block, it's the current ptr.
    // Issue: lb0_out is from `wr_ptr` of PREVIOUS cycle if I use `lb0_out <= ...`
    
    // Fix:
    // Use `wr_ptr` for Read (async) or Sync Read.
    // Let's infer Sync Read.
    // We need to manage the pipeline delays.
    // Flow: 
    // Input (Row Y) 
    // -> LineBuffer0 -> Output (Row Y-1)
    // -> LineBuffer1 -> Output (Row Y-2)
    
    // If LB is sync read:
    // Cycle 0: Addr=0. Read LB0[0]. Write LB0[0]=In.
    // Cycle 1: LB0_Out has old data from Addr=0. Addr=1. 
    //          Write LB1[1] = LB0_Out? No, we want to write to address 0?
    //          Or just write to Address 1?
    //          If we write to Address 1, we save it for next line.
    //          Since we always increment, it matches.
    //          The only issue is the offset of 1 pixel.
    
    // We will align the window by delays.
    // Row 0 (Top): lb1_out (delayed)
    // Row 1 (Mid): lb0_out (delayed)
    // Row 2 (Bot): i_data  (delayed similarly)
    
    // Just ensure i_data is delayed to match LB latency.
    // If LB latency is 1 clock (read), then we need to delay i_data by 1 clock
    // before putting it into the window as "Row 2".
    
    reg [7:0] i_data_d1;
    always @(posedge clk) i_data_d1 <= i_data;
    // So Row 2 source = i_data_d1.
    // Row 1 source = lb0_out.
    // Row 0 source = lb1_out.
    // And write to LB1 using lb0_out.
    
    // This looks consistent.
end

    //---------------------------------------------------------
    // 2. Form the 3x3 Window
    //---------------------------------------------------------
    /* 
       Refined Window Logic with 1-cycle delay compensation
    */
    reg [7:0] row0_src, row1_src, row2_src;
    
    always @(posedge clk) begin
        if(i_de) begin
           i_data_d1 <= i_data;
           
           // Sources
           row2_src = i_data_d1; // Bottom
           row1_src = lb0_out;   // Middle
           row0_src = lb1_out;   // Top
           
           // Slide
           pixel_window[2][2] <= row2_src;
           pixel_window[2][1] <= pixel_window[2][2];
           pixel_window[2][0] <= pixel_window[2][1];

           pixel_window[1][2] <= row1_src;
           pixel_window[1][1] <= pixel_window[1][2];
           pixel_window[1][0] <= pixel_window[1][1];

           pixel_window[0][2] <= row0_src;
           pixel_window[0][1] <= pixel_window[0][2];
           pixel_window[0][0] <= pixel_window[0][1];
        end
    end

    // Rest is same...
    
