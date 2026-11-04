// ===========================================================================
// switch_dbg_latch —— 切图链路数码管实时视图（v2）
//
// 【文件名说明】v1 是"卡死死因锁存器"（3 s 无提交则冻结快照）。上板后发现
//   冻结快照与实时值混在一起判读极易搞错，且三次读数在 RTL 上互相矛盾
//   （bmp_ready=0 时 state_code 不可能是 0）。故 v2 改为**全部实时**：
//   不再锁存、不再切换显示模式、不再点亮小数点，读到的永远"就是现在"。
//   文件名与模块名沿用，避免改动工程清单。
//
// 【上板现象】随机某次按切图键后画面冻结，req_cnt 只增不减，pfb_valid 恒 0。
//   提交条件 req_cnt!=0 && pfb_valid && display_valid 里的 pfb_valid 回不到 1。
//
// 【本模块只用寄存器做一件事】
//   统计"累计发起过几次加载" → load_cnt，用来判断两次读数之间系统到底
//   有没有尝试读卡。恒不增长 = 预取分支从未被触发。
//
// 【输出位定义（全部实时）】
//   lat_a = {sd_init_done, bmp_ready, load_busy, display_valid}
//   lat_b = {pfb_valid, fade_pending, scan_done, first_image_committed}
//   lat_c = img_found_count[3:0]
//
// 仅观测，不驱动任何功能逻辑；删掉本模块不影响原有行为。
// ===========================================================================
module switch_dbg_latch (
    input  wire        clk,
    input  wire        rst,

    // ---- 被观测信号（全部位于 sd_card_bmp 的 clk 域）----
    input  wire        load_start_pulse,     // 发起一次加载（首图/预取/保鲜重写）
    input  wire        pfb_valid,
    input  wire        fade_pending,
    input  wire        display_valid,
    input  wire        load_busy,
    input  wire        bmp_ready,
    input  wire        scan_done,
    input  wire        first_image_committed,
    input  wire [3:0]  img_found_count,
    input  wire        sd_init_done,

    // ---- 观测结果 ----
    output reg  [3:0]  load_cnt,             // 累计加载次数（饱和 15，仅复位清零）
    output wire [3:0]  lat_a,
    output wire [3:0]  lat_b,
    output wire [3:0]  lat_c,
    output wire        fault,                // v2 不再锁存，恒 0
    output wire [3:0]  state_seen            // v2 不再用，恒 0
);

    assign lat_a = {sd_init_done, bmp_ready, load_busy, display_valid};
    assign lat_b = {pfb_valid, fade_pending, scan_done, first_image_committed};
    assign lat_c = img_found_count;
    assign fault      = 1'b0;
    assign state_seen = 4'd0;

    // 累计加载次数：只增不减，方便"隔一会儿再看一眼"判断系统是否还在活动
    always @(posedge clk or posedge rst) begin
        if (rst)
            load_cnt <= 4'd0;
        else if (load_start_pulse && (load_cnt != 4'd15))
            load_cnt <= load_cnt + 4'd1;
    end

endmodule
