module DEMO_V01_TOP 
    #(
        parameter DATA_WIDTH = 8,
        parameter FILTER_SIZE = 3
    )
    (
    input  wire       clk_i,
    input  wire       rst_n,
    output wire [4:0] O_led,
    output wire       O_tmds_clk_p,
    output wire       O_tmds_clk_n,
    output wire [2:0] O_tmds_data_p, // {r,g,b}
    output wire [2:0] O_tmds_data_n
);

    //-----------------------------------------------------
    // Internal Signals
    //-----------------------------------------------------
    wire        tp0_vs_in;
    wire        tp0_hs_in;
    wire        tp0_de_in;
    
    // Pixel Data Signals (controlled vs raw)
    logic       data_request;
    logic       data_valid;
    logic [7:0] data_out;
    logic [7:0] data_out_controlled;

    // Clocking & Reset
    wire        serial_clk;
    wire        pll_lock;
    wire        hdmi4_rst_n;
    wire        pix_clk;
    wire        sys_clk; 

    // LED/Heartbeat
    reg  [31:0] run_cnt;
    wire        running;
    
    // Video Timing Counters
    logic [11:0] cnt_hor;
    logic [11:0] cnt_ver;

    //-----------------------------------------------------
    // Constants / Parameters
    //-----------------------------------------------------
    localparam H_ACTIVE    = 640;
    localparam H_TOTAL     = 800; // 640 + FrontPorch + Sync + BackPorch
    localparam V_ACTIVE    = 480;
    localparam V_TOTAL     = 525; // 480 + FrontPorch + Sync + BackPorch
    localparam IMG_START_X = 12'd0;
    localparam IMG_START_Y = 12'd0;

    //-----------------------------------------------------
    // LED Heartbeat Logic
    //-----------------------------------------------------
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n)
            run_cnt <= 32'd0;
        else if (run_cnt >= 32'd27_000_000)
            run_cnt <= 32'd0;
        else
            run_cnt <= run_cnt + 1'b1;
    end

    assign running  = (run_cnt < 32'd14_000_000);
    assign O_led[0] = running;
    assign O_led[1] = running;
    assign O_led[4] = running;
    assign O_led[2] = ~rst_n;
    assign O_led[3] = ~rst_n;

    //-----------------------------------------------------
    // Clock Generation
    //-----------------------------------------------------
    // 25.169MHZ ---> 59.92Hz (approx)
    Gowin_rPLL_21 u_PLL_3 (
        .clkin  (serial_clk), // input clk 
        .clkout (sys_clk)     // output clk 
    );

    // 371.25MHz TMDS Clock
    tmds_rPLL u_PLL_2 (
        .clkin  (clk_i),      // input clk 
        .clkout (serial_clk), // output clk 
        .lock   (pll_lock)    // output lock
    );

    // 371.25MHz / 5 = 74.25MHz Pixel Clock
    CLKDIV u_CLKDIV (
        .RESETN(hdmi4_rst_n),
        .HCLKIN(serial_clk), // clk x5
        .CLKOUT(pix_clk),    // clk x1
        .CALIB (1'b1)
    );
    
    defparam u_CLKDIV.DIV_MODE = "5";
    defparam u_CLKDIV.GSREN    = "false";
    
    assign hdmi4_rst_n = rst_n & pll_lock;

    //-----------------------------------------------------
    // Video Timing Generators
    //-----------------------------------------------------
    // Horizontal Counter
    always @(posedge sys_clk or negedge hdmi4_rst_n) begin
        if (!hdmi4_rst_n)
            cnt_hor <= H_ACTIVE;
        else if (cnt_hor == H_TOTAL - 1)
            cnt_hor <= 12'd0;
        else
            cnt_hor <= cnt_hor + 1'b1;
    end

    // Vertical Counter
    always @(posedge sys_clk or negedge hdmi4_rst_n) begin
        if (!hdmi4_rst_n) begin
            cnt_ver <= V_ACTIVE;
        end else if (cnt_hor == H_TOTAL - 1) begin
            if (cnt_ver == V_TOTAL - 1)
                cnt_ver <= 12'd0;
            else
                cnt_ver <= cnt_ver + 1'b1;
        end
    end

    // Sync generation (Simplified)
    assign tp0_de_in = (cnt_hor < H_ACTIVE) && (cnt_ver < V_ACTIVE);
    assign tp0_hs_in = (cnt_hor >= H_ACTIVE + 16 && cnt_hor < H_ACTIVE + 16 + 96) ? 1'b0 : 1'b1; 
    assign tp0_vs_in = (cnt_ver >= V_ACTIVE + 10 && cnt_ver < V_ACTIVE + 10 + 2)  ? 1'b0 : 1'b1;

    //-----------------------------------------------------
    // Data Loading & Image Logic
    //-----------------------------------------------------
    // Request data when we are inside the 225x225 image area
    assign data_request = (cnt_hor >= IMG_START_X && cnt_hor < IMG_START_X + 225) && 
                          (cnt_ver >= IMG_START_Y && cnt_ver < IMG_START_Y + 225);

    // Mask data if not requested
    assign data_out_controlled = data_request ? data_out : 8'b0;

    loader #(
        .DATA_WIDTH (DATA_WIDTH),
        .FILTER_SIZE (3)
    ) u_loader (
        .clk     (sys_clk),
        .rst_n   (hdmi4_rst_n),
        .i_vsync (tp0_vs_in),
        .i_next  (data_request),
        .o_data  (data_out),
        .o_valid (data_valid)
    );






    //-----------------------------------------------------
    // DVI/HDMI Output
    //-----------------------------------------------------
    DVI_TX_Top u_DVI_TX_Top (
        .I_rst_n       (hdmi4_rst_n),       // asynchronous reset, low active
        .I_serial_clk  (serial_clk),
        .I_rgb_clk     (pix_clk),           // pixel clock

        .I_rgb_vs      (tp0_vs_in), 
        .I_rgb_hs      (tp0_hs_in),    
        .I_rgb_de      (tp0_de_in), 

        .I_rgb_r       (data_out_controlled), 
        .I_rgb_g       (data_out_controlled),  
        .I_rgb_b       (data_out_controlled),  

        .O_tmds_clk_p  (O_tmds_clk_p),
        .O_tmds_clk_n  (O_tmds_clk_n),
        .O_tmds_data_p (O_tmds_data_p),     // {r,g,b}
        .O_tmds_data_n (O_tmds_data_n)
    );

endmodule
