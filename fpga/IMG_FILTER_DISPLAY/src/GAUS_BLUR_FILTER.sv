module GAUS_BLUR_FILTER #(
    parameter int K = 5,              // Kernel Size (Must be odd: 3, 5, 7...)
    parameter int DATA_W = 8          // Pixel Bit Width
)(
    input  logic clk,
    input  logic rst_n,
    input  logic i_valid,
    // Input is a KxK array of pixels (from your line buffers)
    input  logic [DATA_W-1:0] window [K][K], 
    
    output logic o_valid,
    output logic [DATA_W-1:0] pixel_out
);

    // ============================================================
    // 1. COMPILE-TIME CALCULATOR (The "Tool" does this part)
    // ============================================================
    
    // Type definition for the kernel array
    typedef int kernel_array_t[K][K];

    // Function to calculate Factorial
    function int factorial(input int n);
        if (n <= 1) return 1;
        factorial = n * factorial(n - 1);
    endfunction

    // Function to calculate nCk (Binomial Coefficient)
    function int nCk(input int n, input int k);
        nCk = factorial(n) / (factorial(k) * factorial(n - k));
    endfunction

    // Function to generate the entire 2D Gaussian Matrix
    function kernel_array_t generate_kernel();
        int i, j;
        int pascal_row = K - 1; // The row index in Pascal's Triangle
        
        for (i = 0; i < K; i++) begin
            for (j = 0; j < K; j++) begin
                // 2D Weight = (Binomial X) * (Binomial Y)
                generate_kernel[i][j] = nCk(pascal_row, i) * nCk(pascal_row, j);
            end
        end
    endfunction

    // ============================================================
    // 2. THE HARDCODED CONSTANTS
    // ============================================================
    
    // This runs ONCE when you hit "Synthesize". 
    // The resulting array is burned into the FPGA logic.
    localparam kernel_array_t WEIGHTS = generate_kernel();
    
    // Calculate the total shift amount: 2 * (K - 1)
    localparam int SHIFT_VAL = 2 * (K - 1);

    // ============================================================
    // 3. THE RUNTIME LOGIC (The FPGA does this part)
    // ============================================================
    
    // The accumulator needs to be big. 
    // Max value approx: 255 * (2^(SHIFT_VAL)). 
    // For K=5, Shift=8. 8+8=16 bits minimum. Let's use 32 to be safe.
    logic [31:0] sum; 

    always_ff @(posedge clk) begin
        sum = 0;
        
        // This loop looks like software, but the tool "Unrolls" it.
        // It creates K*K parallel multipliers (or shifters) in hardware.
        for (int y = 0; y < K; y++) begin
            for (int x = 0; x < K; x++) begin
                // WEIGHTS[y][x] is just a constant number here (e.g., 36)
                sum += window[y][x] * WEIGHTS[y][x]; 
            end
        end
        
        // Final normalization shift
        pixel_out <= sum[SHIFT_VAL + DATA_W - 1 : SHIFT_VAL]; 
        
        // Latency match
        o_valid <= i_valid;
    end

endmodule