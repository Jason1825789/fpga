//====================================================
// osd_engine.v — OSD 叠加引擎(扩展1/2 共同地基)
//
// 结构:像素流经过时,从底到顶逐层"命中判断 + Alpha 混合":
//   底图 → 图层0(红色字幕条) → 图层1(黑字+灰影滚动字幕) → 输出
//
// 滚动算法(平滑滚动,零乘除):
//   scroll_pos 每帧(vs 下降沿)+1,周期 = 216(字宽)+640(轨宽)= 856
//   字幕左边缘 x_head = 640 - scroll_pos:从 640(屏外右)滚到 -216(屏外左)
//   即字幕从右往左移动;回绕瞬间:尾部出左缘,头部马上从右缘进入 = 无缝循环
//   速度 = 每帧 1 像素 = 60 像素/秒 = 14.3 秒一轮
//
// 字幕样式:纯黑字面 + 右下偏移 2 像素灰色阴影(3D 悬浮感)
//
// 加图层 = 在属性表加一组 localparam + 加一级混合
//
// 模式 {sw2,sw1}:00 硬切,01 单通道淡入淡出,10 横向黑幕,11 双通道交叉淡化。
// 各动画进度只在 vs 下降沿更新,同一帧内保持不变。
//====================================================
module osd_engine #(
    parameter integer STATUS_DEBOUNCE_CYCLES = 400000 // 16 ms @ 25 MHz
)(
    input  wire             clk,            // video_clk 25MHz
    input  wire             rst,
    input  wire             vs,             // 场同步(负极性):下降沿 = 新一帧 = 滚动节拍
    input  wire [15:0]      pixel_x,        // 当前像素坐标
    input  wire [15:0]      pixel_y,
    input  wire [23:0]      bg_pixel,       // 底图像素(读通道1 = 当前显示缓冲/转场时的旧图)
    input  wire [23:0]      bg_pixel_alt,   // 读通道2(转场时 = 新图,按需激活)
    input  wire             sw_fade,        // SW1(2026-10-05 起仅作兼容保留:实际用 mode[0], 见下面同步链)
    input  wire [1:0]       mode,           // {sw2,sw1}:00=硬切 01=淡入淡出 10=横向黑幕 11=交叉淡化
    input  wire [1:0]       selected_mode_async, // 当前拨码选择,仅供状态条;内部同步+整组消抖
    input  wire             mode11_external,// 1:模式11由独立 mode_11_controller 处理
    input  wire             curtain_black,  // 模式11幕布的逐像素覆盖标志(1=该像素被幕布盖住)
    input  wire             fade_start,     // 保持型转场请求(sd_card_clk 域,内部同步)
    output wire             fade_rd,        // 只在模式11的 ARM/RUN 中使能第二读通道
    output wire             fade_done,      // 转场完成(或中途取消):1 拍脉冲
    output wire [1:0]       O_fade_state,   // 调试用:当前转场状态 0=IDLE 1=ARM 2=RUN 3=HOLD
    output wire [3:0]       O_trans_state,  // 0空闲,1~3模式01,4~8模式10,9/A模式11
    input  wire             display_valid,  // 首图是否已就绪
    input  wire             txt_sel,        // 0=开园句 1=闭园句(滚动字幕文案选择,SW3)
    output wire [23:0]      out_pixel       // 叠加后的最终像素
);

// ================= 图层0:底部字幕条(整幅宽) =================
localparam       L0_EN    = 1'b1;
localparam [15:0] L0_X0    = 16'd0;
localparam [15:0] L0_Y0    = 16'd460;     // 底部 20 像素
localparam [15:0] L0_X1    = 16'd640;     // 整幅宽
localparam [15:0] L0_Y1    = 16'd480;     // 到屏幕底边
// 与图片椭圆外的底色 #F0F0F0 完全相同 → 字幕条与画面灰底无缝, 黑字直接浮在灰上。
// 注意: 图片素材的 BG 也必须保持 (240,240,240), 两边数值相同才不会出现接缝。
localparam [23:0] L0_COLOR = 24'hF0F0F0;
localparam [2:0]  L0_ALPHA = 3'd4;          // 0=0% 1=25% 2=50% 3=75% 4=100%

// ================= 图层1:纯黑滚动字幕 =================
localparam [15:0] L1_Y0  = 16'd462;      // 460+(20-16)/2 = 462 条内垂直居中
localparam [2:0]  L1_ALPHA = 3'd4;          // 100% 不透明
localparam [23:0] L1_FACE_COLOR   = 24'h000000;   // 字面:纯黑

// 滚动参数
// 字幕串 "9:00-17:00颐和园欢迎您" = 16 字符,变宽排版:
//   数字/符号 12px 格(10 个),汉字 16px 格(6 个)→ 总宽 10x12+6x16 = 216
localparam [15:0] SCROLL_W    = 16'd216;
localparam [10:0] SCROLL_PERIOD = 11'd856;   // 216(字宽) + 640(轨宽);速度 = 每帧 1 像素

// ================= 滚动计数器 =================
// vs 是负极性:下降沿(1→0)= 场同步开始 = 新一帧
reg        vs_d;
reg [10:0] scroll_pos;                      // 0 ~ 855 循环
wire       vs_fall;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        vs_d       <= 1'b0;
        scroll_pos <= 11'd0;
    end else begin
        vs_d <= vs;
        if (vs_d & ~vs) begin
            if (scroll_pos == SCROLL_PERIOD - 11'd1)   // 855 → 回绕到 0
                scroll_pos <= 11'd0;
            else
                scroll_pos <= scroll_pos + 11'd1;
        end
    end
end
assign vs_fall = vs_d & ~vs;

// ================= 淡入淡出状态机(只服务模式 01) =================
// 流程:IDLE → (fade_start 同步) ARM(等 2 帧,让缓冲翻转对齐到帧边界)
//      → RUN 前半段:alpha 255→0,画面逐渐变暗
//      →       alpha==0 时发 fade_done → sd_card_bmp 在「全黑」处翻转显示缓冲
//      → RUN 后半段:alpha 0→255,画面逐渐变亮(此时 ch1 已经是新图)
//      → HOLD(3 帧收尾) → IDLE(停在最亮,等待下一次按键)
//
// 状态机四个状态的作用:
//   IDLE : 纯显示 ch1(当前缓冲),亮度直通。转场请求到来才进 ARM。
//   ARM  : 等 2 帧对齐帧边界,然后开始转场(此期间仍显示纯旧图)。
//   RUN  : 两段式淡入淡出。前半段 ch1(旧图)亮度 255→0;
//          全黑那一帧发出 fade_done → sd_card_bmp 翻转显示缓冲;
//          后半段 ch1 已变成新图,亮度 0→255。
//   HOLD : 多停 3 帧收尾,然后回 IDLE 停在最亮。
//
// 为什么需要 HOLD:
//   虽然翻转在全黑帧就发出去了,但 disp_buf_idx 跨域同步 + 读地址在 S_ACK
//   重新锁存还需要几拍。HOLD 留 3 帧做安全余量,确保回 IDLE 时 ch1 已稳定
//   指向新图,不会再出现"跳回旧图"的一帧。
localparam FADE_ST_IDLE = 2'd0;   // 平时:纯显示 ch1(当前缓冲)
localparam FADE_ST_ARM  = 2'd1;   // 预热:等帧边界对齐(此期间仍显示纯旧图)
localparam FADE_ST_RUN  = 2'd2;   // 转场中:模式 1 两段式淡入淡出(变暗→黑→变亮)
localparam FADE_ST_HOLD = 2'd3;   // 保持:等缓冲翻转彻底生效,再回 IDLE

// ---- 8bit 定点亮度 alpha(0..255)：只在 vsync 场消隐期间更新，DE=1 期间保持不变 ----
localparam [7:0]  ALPHA_MAX   = 8'd255;   // 最亮(原图)
localparam [7:0]  ALPHA_STEP  = 8'd8;     // 每帧亮度变化量：约 32 帧/段
                                          // 变暗约 0.53s，完整转场约 1.2s @60Hz
localparam [1:0]  HOLD_FRAMES = 2'd3;     // HOLD 保持帧数：需覆盖缓冲翻转 + ch1 重新锁址
localparam [2:0]  SWAP_WAIT_FRAMES = 3'd4;// 全黑后等待新缓冲跨域并从帧首生效

// ===== 模式01淡入淡出 = 两段式 =====
//   前半段 : ch1(旧图) 亮度 255→0 → 画面由亮逐渐变暗
//   全黑时 : alpha == 0,通知 sd_card_bmp 翻转显示缓冲
//            —— 切图动作正好发生在全黑的一瞬间,肉眼看不到
//   后半段 : ch1(此时已经变成新图) 亮度 0→255 → 画面由最暗逐渐变回最亮
//
//   ★ 模式01全程只显示 ch1,不切换像素来源。
//     旧写法是"后半段显示 ch2",但缓冲翻转之后 read2_addr_index 会跟着
//     (disp_buf_idx ^ 1) 变成旧缓冲,于是结尾出现
//     "新图 → 旧图 → 新图" 的闪帧。改成全程 ch1 后这个问题彻底消失。
//
//   实现上只做一次亮度缩放:out = (pix * alpha) >> 8(逐通道)。
//   alpha = 255 时直接直通原图,避免 255/256 的 1 LSB 截断。
//
//   淡化是否包含 OSD 字幕/红条:
//     1'b0 = 只淡化底图,字幕/红条保持常亮 ← 当前(完全不碰 OSD 输出)
//     1'b1 = 整屏一起变暗,"亮度到 0"是真正的全黑
localparam        FADE_INCLUDE_OSD = 1'b1;

// 模式00的硬切由 sd_card_bmp 完成;模式01、10、11各有独立动画状态机。

// fade_start 跨域同步(sd_card_clk → video_clk)
//
// fade_start(即 sd_card_bmp 的 fade_req)是**保持型**信号:
//   一次按键 → 整段转场期间一直为 1 → 转场结束(fade_done)才拉低。
// 所以这里同步后的 fs_d1 直接当作"当前有没有转场请求"的**电平**用,
// 不再做"单拍上升沿"检测。好处:即使请求的上升沿正好被 osd 忙的时候错过,
// 回到 IDLE 后依然能靠电平响应,不会出现"请求悬空 → 等 5s 超时 → 硬切"。
reg  fs_d0, fs_d1;
always @(posedge clk or posedge rst) begin
    if (rst) begin fs_d0 <= 1'b0; fs_d1 <= 1'b0; end
    else begin fs_d0 <= fade_start; fs_d1 <= fs_d0; end
end

// SW 同步 + 16ms 稳定滤波(机械开关抖动)
// 2026-10-05: 改成 2 位一起同步, 得到 mode_stable = {sw2, sw1}。
// 两位必须一起消抖, 否则"只拨了 sw2"时会出现中间态被判成 mode01/10。
// (原来的 sw_fade 单位同步链语义完全保留在 mode_stable[0] 上, mode01 行为不变)
reg  [1:0] sw_d0, sw_d1;
reg  [19:0] sw_cnt;                          // 16ms @25MHz = 400000
reg  [1:0] mode_stable;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sw_d0 <= 2'b00; sw_d1 <= 2'b00;
        sw_cnt <= 20'd0; mode_stable <= 2'b00;
    end else begin
        sw_d0 <= mode;
        sw_d1 <= sw_d0;
        if (sw_d1 != mode_stable) begin
            if (sw_cnt >= 20'd399999) begin
                mode_stable <= sw_d1;
                sw_cnt <= 20'd0;
            end else
                sw_cnt <= sw_cnt + 20'd1;
        end else
            sw_cnt <= 20'd0;
    end
end
wire sw_fade_stable = mode_stable[0];                    // sw1(单独用, 与原语义相同)

// 状态条必须显示“当前拨码选择”，而不是正在执行的旧转场模式。顶层的 mode
// 在 fade_start 期间会切到 transition_mode_latched，所以这里给显示路径单独同步
// 原始 {sw2,sw1}。两位一起稳定满 16 ms 才更新，避免拨动过程中闪过中间码。
reg  [1:0] status_mode_d0;
reg  [1:0] status_mode_d1;
reg  [1:0] status_mode_stable;
reg [19:0] status_mode_cnt;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        status_mode_d0     <= 2'b00;
        status_mode_d1     <= 2'b00;
        status_mode_stable <= 2'b00;
        status_mode_cnt    <= 20'd0;
    end else begin
        status_mode_d0 <= selected_mode_async;
        status_mode_d1 <= status_mode_d0;
        if (status_mode_d1 != status_mode_stable) begin
            if (status_mode_cnt >= STATUS_DEBOUNCE_CYCLES - 1) begin
                status_mode_stable <= status_mode_d1;
                status_mode_cnt    <= 20'd0;
            end else begin
                status_mode_cnt <= status_mode_cnt + 20'd1;
            end
        end else begin
            status_mode_cnt <= 20'd0;
        end
    end
end

// 2026-10-05 P0 修复: mode_fade 原来写成 mode_stable[1] ^ mode_stable[0],
// 但 XOR 的语义是"两位不同",它只排除了 00/11,**没有排除 10** ——
// 于是 mode=2'b10 时 mode_fade 同样是 1, 淡化 FSM 和黑幕 FSM 被同时启动。
// 后果: 两个 FSM 各自推进自己的进度条(淡化 76 帧 / 黑幕 89 帧),而
//       fade_done = fade_done_r | wipe_done_r 让先跑完的淡化抢到切缓冲脉冲
//       → 真正的 buffer flip 发生在 F36(设计意图是 F42 的整黑帧),
//         且画面出现"旧图闪回 3%~5%"的二次黑→亮,动画与换图错开 53 帧。
// 正确译码: 只有 sw1=1 且 sw2=0(纯 2'b01)才是淡入淡出。
wire mode_fade      = ~mode_stable[1] &  mode_stable[0]; // 2'b01 = 淡入淡出
wire mode_wipe      =  mode_stable[1] & ~mode_stable[0]; // 2'b10 = 横向黑幕擦除
// 外置控制器接管模式11时,仅屏蔽下面保留的旧内联 mode11 实现。
// mode01/mode10 的译码、状态机、触发条件和时序均保持原样。
wire mode_crossfade =  mode_stable[1] &  mode_stable[0] & ~mode11_external;
wire fade_start_fade, fade_start_wipe, fade_start_cross;
reg  trans_req_claimed;

reg [1:0]  fade_state;
reg [7:0]  alpha;                 // 当前显示那张图的亮度 0..255，仅 vsync 更新
reg        fade_half;             // 0=前半段(旧图变暗) 1=后半段(新图变亮)
reg [1:0]  arm_cnt;               // ARM 阶段已等待的帧数
reg [1:0]  hold_cnt;              // HOLD 阶段已等待的帧数
reg [2:0]  swap_wait_cnt;         // 切换缓冲后保持全黑的帧数
reg        fade_done_r;

// 完成脉冲由三个互斥状态机汇合,包括切换模式时的取消脉冲。
// fade_done 与 fade_rd 在模式11状态机声明后赋值。
assign O_fade_state = fade_state;                  // 模式01状态诊断

always @(posedge clk or posedge rst) begin
    if (rst) begin
        fade_state  <= FADE_ST_IDLE;
        alpha       <= ALPHA_MAX;
        fade_half   <= 1'b0;
        arm_cnt     <= 2'd0;
        hold_cnt    <= 2'd0;
        swap_wait_cnt <= 3'd0;
        fade_done_r <= 1'b0;
    end else begin
        fade_done_r <= 1'b0;
        case (fade_state)
            FADE_ST_IDLE: begin
                // 一次按键 = 一个完整循环。fs_d1 是"有没有转场请求"的电平,
                // 转场跑完回到 IDLE 后它会是 0,于是停在最亮状态不动,
                // 直到下一次按键把它拉高,才开始下一个循环。
                // 2026-10-05: 只有 mode=2'b01(淡入淡出) 才启动本 FSM;
                //              mode=10/11 由各自的 FSM 处理。
                if (fade_start_fade) begin
                    fade_state <= FADE_ST_ARM;      // 等帧边界,让转场从整帧起点开始
                    arm_cnt    <= 2'd0;
                    swap_wait_cnt <= 3'd0;
                end
            end
            FADE_ST_ARM: begin
                if (vs_fall) begin
                    if (arm_cnt == 2'd1) begin       // 等满 2 个 vs 下降沿(2 帧)后开始转场
                        fade_state <= FADE_ST_RUN;
                        alpha      <= ALPHA_MAX;     // 前半段从"最亮"开始
                        fade_half  <= 1'b0;          // 先走"旧图变暗"
                    end else
                        arm_cnt <= arm_cnt + 2'd1;
                end
            end
            FADE_ST_RUN: begin
                // !! 转场进度只在 vs 下降沿(场消隐开始)推进,DE=1 期间完全不变,
                //    因此同一帧内所有有效像素用的是同一个 alpha,
                //    不会出现"帧内撕裂 / 横向阴影"。
                if (vs_fall) begin
                    if (mode_fade) begin
                        // ---- 模式 1:两段式淡入淡出 ----
                        //   前半段(fade_half=0):ch1 还是旧图,alpha 255→0 → 画面由亮变到全黑
                        //   后半段(fade_half=1):全黑帧已翻转缓冲,ch1 变成新图,alpha 0→255
                        // 两段在 alpha==0 处接上,那一帧是纯黑,所以"旧图→新图"的切换
                        // 正好发生在全黑的一瞬间,肉眼看不到任何跳变。
                        // 全程只有一个来源(ch1),不存在源切换,所以结尾不会闪。
                    if (!fade_half) begin
                        if (alpha == 8'd0) begin
                            fade_half   <= 1'b1;     // 切到后半段
                            fade_done_r <= 1'b1;     // ★ 在"全黑"这一帧通知 sd_card_bmp 翻转显示缓冲
                            swap_wait_cnt <= SWAP_WAIT_FRAMES;
                                                    //   (切图动作藏在全黑里,肉眼看不到)
                        end
                        else if (alpha <= ALPHA_STEP)
                            alpha <= 8'd0;
                        else
                            alpha <= alpha - ALPHA_STEP;
                    end else begin
                        // 后半段:ch1 已经翻成新图,这里只把亮度拉回最亮。
                        // 注意:不再发 fade_done —— 缓冲已经在全黑时翻过了。
                        // 先保持若干个完整黑帧，覆盖 sd/video/mem 三个时钟域的
                        // 同步、读 FIFO 清空和新帧首批像素预取，避免旧帧被短暂拉亮。
                        if (swap_wait_cnt != 3'd0) begin
                            swap_wait_cnt <= swap_wait_cnt - 3'd1;
                            alpha         <= 8'd0;
                        end else if (alpha >= ALPHA_MAX) begin
                            fade_state <= FADE_ST_HOLD;
                            hold_cnt   <= 2'd0;
                        end else if ({1'b0, alpha} + {1'b0, ALPHA_STEP} >= {1'b0, ALPHA_MAX}) begin
                            // ★ 9 位比较 —— 修复 8 位回绕 bug(2026-10-05):
                            //   旧写法 alpha + ALPHA_STEP 是 8 位加法,ALPHA_STEP=8 时
                            //   alpha=248 → 248+8 回绕成 0,饱和条件永远为假,
                            //   alpha 被赋成 0 → FADE_IN 在 0..248 间无限循环,
                            //   永远到不了 255,状态机卡死在 RUN:
                            //   现象 = 转场结束后屏幕反复"变暗→变亮"、不再切图。
                            //   (ALPHA_STEP=4 时同理:252+4 回绕;此 bug 自两段式
                            //    转场引入起就存在,Python 参考模型整数不回绕所以没测出。)
                            //   零扩展到 9 位后 248+8=256 >= 255 成立,alpha 饱和到 255。
                            alpha <= ALPHA_MAX;
                        end else
                            alpha <= alpha + ALPHA_STEP;   // 到这里的 alpha+STEP<=254,8 位赋值不回绕
                    end
                    end else begin
                        // 若中途切离模式01,结束该请求,避免淡化状态机停在 RUN。
                        fade_state  <= FADE_ST_HOLD;
                        hold_cnt    <= 2'd0;
                        fade_done_r <= 1'b1;
                    end
                end
            end
            FADE_ST_HOLD: begin
                // 缓冲翻转已经在全黑那一帧完成,ch1 此时已是新图;
                // 这里多停留几帧做收尾,然后回到 IDLE 停在最亮。
                if (vs_fall) begin
                    if (hold_cnt >= HOLD_FRAMES - 2'd1)
                        fade_state <= FADE_ST_IDLE;
                    else
                        hold_cnt <= hold_cnt + 2'd1;
                end
            end
            default: fade_state <= FADE_ST_IDLE;
        endcase
    end
end

// ============================================================================
// mode = 2'b10:横向黑幕擦除(2026-10-05 新增)
//
//   W_IDLE → W_ARM → W_OUT → W_BLACK → W_IN → W_HOLD → W_IDLE
//
//   做法:只用"比较器 + MUX + 帧级计数器",不碰读通路:
//     * 切缓冲那一帧整屏全黑,所以"翻转 disp_buf_idx 的延迟"完全被黑幕盖住;
//     * frame_fifo_read 每帧在 vs 边沿清 FIFO 并整帧重读,切缓冲只是换基址,
//       **不会产生额外 SDRAM 读请求**(这是本方案省功耗的根本原因);
//     * 切缓冲请求复用现有的 fade_done 脉冲(与淡入淡出同一个 wire),
//       sd_card_bmp 侧代码一行不改。
//
//   wipe_pos 只在 vs_fall 更新 → 一整帧内它是常量,比较器输出整帧稳定,无行内撕裂。
// ============================================================================
localparam [15:0] WIPE_W        = 16'd640;   // 屏宽(pixel_x 上限 639)
localparam [9:0]  WIPE_STEP     = 10'd16;    // 每帧推进 16px → 40 帧/阶段 ≈0.67s
localparam [2:0]  W_SWITCH_HOLD = 3'd4;      // 全黑等待帧(切缓冲 + FIFO 重填),4 帧足够
localparam [2:0]  WIPE_HOLD_F   = 3'd2;      // 揭开后的收尾帧

localparam [2:0] W_IDLE  = 3'd0;
localparam [2:0] W_ARM   = 3'd1;
localparam [2:0] W_OUT   = 3'd2;   // 黑幕从左向右盖住旧图
localparam [2:0] W_BLACK = 3'd3;   // 整屏全黑:发切缓冲脉冲,并等 FIFO 重填
localparam [2:0] W_IN    = 3'd4;   // 黑幕从右向左退开,露出新图
localparam [2:0] W_HOLD  = 3'd5;

reg [2:0] wipe_state;
reg [9:0] wipe_pos;                 // 0..640
reg [2:0] w_cnt;
reg       wipe_done_r;               // "请在安全边界切缓冲"脉冲(整黑帧发一次)

wire wipe_active = (wipe_state != W_IDLE);
// W_ARM 期间还没开始推幕,底图原样显示
wire wipe_pass   = (wipe_state == W_IDLE) | (wipe_state == W_ARM);
// 幕的"隐藏"条件:
//   W_OUT / W_BLACK : pixel_x <  wipe_pos → 黑(黑幕从左向右推进;wipe_pos=640 时整屏黑)
//   W_IN  / W_HOLD  : pixel_x >= wipe_pos → 黑(幕从右向左退开;wipe_pos=640 时整屏亮)
wire wipe_hide   = ((wipe_state == W_OUT) | (wipe_state == W_BLACK))
                 ? (pixel_x[9:0] <  wipe_pos)
                 : (pixel_x[9:0] >= wipe_pos);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wipe_state  <= W_IDLE;
        wipe_pos    <= 10'd0;
        w_cnt       <= 3'd0;
        wipe_done_r <= 1'b0;
    end else begin
        wipe_done_r <= 1'b0;
        case (wipe_state)
            W_IDLE: begin
                // 只接管尚未由其它模式处理过的保持型请求。
                if (fade_start_wipe) begin
                    wipe_state <= W_ARM;
                    wipe_pos   <= 10'd0;
                    w_cnt      <= 3'd0;
                end
            end
            W_ARM: if (vs_fall) begin          // 等 2 帧,让幕从整帧起点开始
                if (w_cnt >= 2'd1) begin
                    wipe_state <= W_OUT;
                    wipe_pos   <= 10'd0;
                    w_cnt      <= 3'd0;
                end else
                    w_cnt <= w_cnt + 3'd1;
            end
            W_OUT: if (vs_fall) begin
                if (wipe_pos >= WIPE_W - WIPE_STEP) begin
                    wipe_pos   <= 10'd640;      // 盖满
                    wipe_state <= W_BLACK;
                    w_cnt      <= 3'd0;
                end else
                    wipe_pos <= wipe_pos + WIPE_STEP;
            end
            W_BLACK: if (vs_fall) begin
                // 整屏全黑的第 1 帧发脉冲:sd_card_bmp 收到后翻转 disp_buf_idx,
                // 新基址在"下一帧的 read_req"才被锁存,之后还有 4 帧全黑兜底。
                if (w_cnt == 3'd0)
                    wipe_done_r <= 1'b1;
                if (w_cnt + 3'd1 >= W_SWITCH_HOLD) begin
                    wipe_state <= W_IN;
                    wipe_pos   <= 10'd0;
                    w_cnt      <= 3'd0;
                end else
                    w_cnt <= w_cnt + 3'd1;
            end
            W_IN: if (vs_fall) begin
                if (wipe_pos >= WIPE_W - WIPE_STEP) begin
                    wipe_pos   <= 10'd640;      // 全部揭开
                    wipe_state <= W_HOLD;
                    w_cnt      <= 3'd0;
                end else
                    wipe_pos <= wipe_pos + WIPE_STEP;
            end
            W_HOLD: if (vs_fall) begin
                if (w_cnt + 3'd1 >= WIPE_HOLD_F) begin
                    wipe_state <= W_IDLE;
                    w_cnt      <= 3'd0;
                end else
                    w_cnt <= w_cnt + 3'd1;
            end
            default: wipe_state <= W_IDLE;
        endcase

        // 黑幕过程中把 sw 拨离 2'b10(切到其它模式):
        // 必须先补一个切缓冲脉冲再回 IDLE,否则 sd_card_bmp 的 fade_pending
        // 会一直挂到 5s 超时兜底(表现为"卡 5 秒后才跳图")。
        if (wipe_active && !mode_wipe) begin
            wipe_done_r <= 1'b1;
            wipe_state  <= W_IDLE;
            wipe_pos    <= 10'd0;
            w_cnt       <= 3'd0;
        end
    end
end

// ============================================================================
// mode = 2'b11:老师的 16 档双通道交叉淡化
// ARM 预读新图两个帧边界;RUN 中旧图权重每两帧减一档(16→0)。
// 切到纯新图的帧边界就通知 sd_card_bmp 翻转主显示缓冲;
// 纯新图仍由 ch2 显示完整一帧,下个帧边界再交回已切到新图的 ch1。
// ============================================================================
localparam [1:0] XFADE_ST_IDLE = 2'd0;
localparam [1:0] XFADE_ST_ARM  = 2'd1;
localparam [1:0] XFADE_ST_RUN  = 2'd2;
reg [1:0] xfade_state;
reg [4:0] xfade_w;
reg [1:0] xfade_arm_cnt;
reg       xfade_half_frame;
reg       xfade_done_r;
wire      xfade_active = (xfade_state != XFADE_ST_IDLE);

// 一次保持型请求只允许一个动画接管;忙时不启动其它模式。
assign fade_start_fade = fs_d1 && !trans_req_claimed && mode_fade &&
                         (fade_state == FADE_ST_IDLE) && !wipe_active && !xfade_active;
assign fade_start_wipe = fs_d1 && !trans_req_claimed && mode_wipe &&
                         (fade_state == FADE_ST_IDLE) && !wipe_active && !xfade_active;
assign fade_start_cross = fs_d1 && !trans_req_claimed && mode_crossfade &&
                          (fade_state == FADE_ST_IDLE) && !wipe_active && !xfade_active;

always @(posedge clk or posedge rst) begin
    if (rst)
        trans_req_claimed <= 1'b0;
    else if (!fs_d1)
        trans_req_claimed <= 1'b0;
    else if (fade_start_fade || fade_start_wipe || fade_start_cross)
        trans_req_claimed <= 1'b1;
end

assign fade_done = fade_done_r | wipe_done_r | xfade_done_r;
assign fade_rd   = xfade_active;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        xfade_state      <= XFADE_ST_IDLE;
        xfade_w          <= 5'd16;
        xfade_arm_cnt    <= 2'd0;
        xfade_half_frame <= 1'b0;
        xfade_done_r     <= 1'b0;
    end else begin
        xfade_done_r <= 1'b0;
        case (xfade_state)
            XFADE_ST_IDLE: begin
                if (fade_start_cross) begin
                    xfade_state      <= XFADE_ST_ARM;
                    xfade_w          <= 5'd16;
                    xfade_arm_cnt    <= 2'd0;
                    xfade_half_frame <= 1'b0;
                end
            end
            XFADE_ST_ARM: if (vs_fall) begin
                if (xfade_arm_cnt == 2'd1) begin
                    xfade_state      <= XFADE_ST_RUN;
                    xfade_w          <= 5'd16;
                    xfade_half_frame <= 1'b0;
                end else
                    xfade_arm_cnt <= xfade_arm_cnt + 2'd1;
            end
            XFADE_ST_RUN: if (vs_fall) begin
                if (xfade_w == 5'd0) begin
                    xfade_state  <= XFADE_ST_IDLE;
                end else if (xfade_half_frame) begin
                    xfade_w          <= xfade_w - 5'd1;
                    xfade_half_frame <= 1'b0;
                    // 权重 1→0 时已经开始显示纯新图:此刻通知 SD 翻转 ch1。
                    // 若等到 0→IDLE 才通知,下一帧会短暂显示仍指向旧图的 ch1。
                    if (xfade_w == 5'd1)
                        xfade_done_r <= 1'b1;
                end else
                    xfade_half_frame <= 1'b1;
            end
            default: xfade_state <= XFADE_ST_IDLE;
        endcase

        // 中途切离 11 时完成这次请求,不让上游等待超时。
        if (xfade_active && !mode_crossfade) begin
            xfade_state      <= XFADE_ST_IDLE;
            xfade_w          <= 5'd16;
            xfade_arm_cnt    <= 2'd0;
            xfade_half_frame <= 1'b0;
            xfade_done_r     <= 1'b1;
        end
    end
end

// 统一转场状态码(给数码管第 4 位做调试):
//   0        = 空闲
//   1,2,3    = 淡入淡出 ARM / RUN / HOLD
//   4,5,6,7,8= 黑幕 ARM / W_OUT / W_BLACK / W_IN / W_HOLD
//   9,A      = 交叉淡化 ARM / RUN
wire [3:0] trans_state = (fade_state != FADE_ST_IDLE) ? {2'b00, fade_state}
                       : wipe_active ? (4'd3 + {1'b0, wipe_state})
                       : xfade_active ? (4'd8 + {2'b00, xfade_state})
                       : 4'd0;
assign O_trans_state = trans_state;

// 亮度缩放:out = (pix * alpha) >> 8
//   用来做"整屏由亮变黑 / 由黑变亮"的淡入淡出。
//   alpha = 255 → 原图(调用处直接直通,避免 255/256 的 1 LSB 截断)
//   alpha = 0   → 纯黑
// 必须按 R/G/B 三个通道分别运算,不能把 24bit 当成一个整数,
// 否则低位通道的进位会串到高位通道,产生彩色噪点。
// 位宽:单通道最大 255*255 = 65025 < 2^16,16 位足够。
function [23:0] scale_by_alpha;
    input [23:0] pix;
    input [7:0]  a;              // 亮度权重 0..255
    reg   [15:0] r, g, b;
    begin
        r = (pix[23:16] * a) >> 8;
        g = (pix[15:8]  * a) >> 8;
        b = (pix[7:0]   * a) >> 8;
        scale_by_alpha = {r[7:0], g[7:0], b[7:0]};
    end
endfunction

// 模式11的两个 RGB 像素逐通道混合;整包乘加会让进位串入相邻颜色通道。
function [23:0] blend_w;
    input [23:0] old_pix;
    input [23:0] new_pix;
    input [4:0]  old_weight;
    reg [4:0] new_weight;
    reg [12:0] r_acc, g_acc, b_acc;
    begin
        new_weight = 5'd16 - old_weight;
        r_acc = ({5'b0, old_pix[23:16]} * {8'b0, old_weight}) +
                ({5'b0, new_pix[23:16]} * {8'b0, new_weight});
        g_acc = ({5'b0, old_pix[15:8]} * {8'b0, old_weight}) +
                ({5'b0, new_pix[15:8]} * {8'b0, new_weight});
        b_acc = ({5'b0, old_pix[7:0]} * {8'b0, old_weight}) +
                ({5'b0, new_pix[7:0]} * {8'b0, new_weight});
        blend_w = {r_acc[11:4], g_acc[11:4], b_acc[11:4]};
    end
endfunction

// 模式01只用 ch1;模式10黑幕遮住 ch1 的部分区域;模式11混合 ch1/ch2。
// 这里仅处理底图,红条和滚动字幕保持原有叠加顺序。
wire [23:0] bg_eff = (xfade_state == XFADE_ST_RUN)
                   ? blend_w(bg_pixel, bg_pixel_alt, xfade_w)
                   : (wipe_active & ~wipe_pass)
                   ? (wipe_hide ? 24'h000000 : bg_pixel)
                   : bg_pixel;

// ================= Alpha 混合函数 =================
// out = alpha%×fg + (1-alpha)%×bg,移位近似实现,无乘法器(省资源,呼应"优化导向")
// 注意:必须按 R/G/B 逐通道运算,原实现把 24bit 当整数做减法会在通道间借位,
//       例如 bg=0x000100 时 3*bg/4 会算成 0x0000C0(绿色被清掉)
function [23:0] alpha_blend;
    input [23:0] fg;
    input [23:0] bg;
    input [2:0]  alpha;
    reg [7:0] r, g, b;
    begin
        case (alpha)
            3'd0: begin                                                   // 0%: 全背景
                r = bg[23:16];               g = bg[15:8];               b = bg[7:0];
            end
            3'd1: begin                                                   // 25%: fg/4 + 3bg/4
                r = (fg[23:16] >> 2) + bg[23:16] - (bg[23:16] >> 2);
                g = (fg[15:8]  >> 2) + bg[15:8]  - (bg[15:8]  >> 2);
                b = (fg[7:0]   >> 2) + bg[7:0]   - (bg[7:0]   >> 2);
            end
            3'd2: begin                                                   // 50%: 平均
                r = (fg[23:16] >> 1) + (bg[23:16] >> 1);
                g = (fg[15:8]  >> 1) + (bg[15:8]  >> 1);
                b = (fg[7:0]   >> 1) + (bg[7:0]   >> 1);
            end
            3'd3: begin                                                   // 75%: 3fg/4 + bg/4
                r = fg[23:16] - (fg[23:16] >> 2) + (bg[23:16] >> 2);
                g = fg[15:8]  - (fg[15:8]  >> 2) + (bg[15:8]  >> 2);
                b = fg[7:0]   - (fg[7:0]   >> 2) + (bg[7:0]   >> 2);
            end
            default: begin                                                // 100%: 全前景
                r = fg[23:16];               g = fg[15:8];               b = fg[7:0];
            end
        endcase
        alpha_blend = {r, g, b};
    end
endfunction

// ================= 图层0 命中判断 =================
wire l0_active = L0_EN && (pixel_x >= L0_X0) && (pixel_x < L0_X1) &&
                           (pixel_y >= L0_Y0) && (pixel_y < L0_Y1);

// ================= 图层1 滚动字幕命中与字模查询 =================
// 字幕左边缘屏幕坐标 x_head = 640 - scroll_pos(从右往左滚动);
// 串内偏移 dx = pixel_x - x_head = pixel_x + scroll_pos - 640
// 无符号回绕,越界由 cell 内门控挡掉
wire [15:0] str_dy = pixel_y - L1_Y0;
wire [15:0] str_dx = pixel_x + {5'b0, scroll_pos} - 16'd640;

wire face_on;
osd_text_cell #(
    .CELL_W (SCROLL_W)
) u_text_cell(
    .dx         (str_dx),
    .dy         (str_dy),
    .txt_sel    (txt_sel),
    .face_on    (face_on)
);

// 字幕层:命中 → 纯黑字面
wire [23:0] sub_fg = L1_FACE_COLOR;
wire        sub_hit = face_on;

// ================= 从底到顶逐层混合 =================
// 未命中 → alpha=0 → 该层透明透传
wire [2:0]  l0_alpha = l0_active ? L0_ALPHA : 3'd0;
wire [2:0]  l1_alpha = sub_hit ? L1_ALPHA : 3'd0;

// 淡入淡出的亮度缩放放在哪一级:
//   FADE_INCLUDE_OSD = 1 → 放在最后一级,连 OSD 字幕/红条一起变暗
//   FADE_INCLUDE_OSD = 0 → 只缩放底图,字幕/红条保持常亮
// 两种写法 alpha 都只乘一次,不会二次变暗。
wire        fade_scale_on = (fade_state == FADE_ST_RUN);
wire [7:0]  bg_alpha  = (fade_scale_on && !FADE_INCLUDE_OSD) ? alpha : 8'd255;
wire [23:0] bg_scaled = (bg_alpha == 8'd255) ? bg_eff : scale_by_alpha(bg_eff, bg_alpha);

wire [23:0] mix0 = alpha_blend(L0_COLOR, bg_scaled, l0_alpha);
wire [23:0] mix1 = alpha_blend(sub_fg, mix0, l1_alpha);

wire [7:0]  out_alpha = (fade_scale_on && FADE_INCLUDE_OSD) ? alpha : 8'd255;
// r23 基线原样保留：底图/底条/滚动字幕这条主通路仍在这里统一乘一次，不动它。
// 左上状态条和时间戳跑在这条通路下游，它们各自的转场处理见文件末尾"输出级"。
wire [23:0] mix_final = (out_alpha == 8'd255) ? mix1 : scale_by_alpha(mix1, out_alpha);

// ================= 左上角模式状态条(最终顶层) =================
// 坐标均以 de 有效区左上角为 (0,0)：背景贴齐左上边界，文字内缩 4 像素。
// 固定九格格式："00 · 直接切换"；数字和中点为黑色，四个标题汉字也是黑色（2026-11-02 统一）。
// 该层优先级最高，但仍然跟随转场：黑幕/幕布/淡化都在文件末尾的输出级对它单独处理。
localparam [15:0] STATUS_X0 = 16'd0;
localparam [15:0] STATUS_Y0 = 16'd0;
localparam [15:0] STATUS_X1 = 16'd152;
localparam [15:0] STATUS_Y1 = 16'd24;
localparam [15:0] STATUS_TEXT_X0 = 16'd4;
localparam [15:0] STATUS_TEXT_Y0 = 16'd4;
// 左上状态条配色（2026-11-02）：底色改为与图片椭圆外一致 #F0F0F0，
// 文字统一纯黑，与底部滚动字幕同色，避免深色方块突兀。
localparam [23:0] STATUS_BG_COLOR = 24'hF0F0F0;
localparam [23:0] STATUS_PREFIX_COLOR = 24'h000000;
localparam [23:0] STATUS_TITLE_COLOR = 24'h000000;

wire status_bar_hit = (pixel_x >= STATUS_X0) && (pixel_x < STATUS_X1) &&
                      (pixel_y >= STATUS_Y0) && (pixel_y < STATUS_Y1);
wire status_text_zone = (pixel_x >= STATUS_TEXT_X0) &&
                        (pixel_x < STATUS_TEXT_X0 + 16'd144) &&
                        (pixel_y >= STATUS_TEXT_Y0) &&
                        (pixel_y < STATUS_TEXT_Y0 + 16'd16);
wire [15:0] status_text_dx = pixel_x - STATUS_TEXT_X0;
wire [15:0] status_text_dy = pixel_y - STATUS_TEXT_Y0;
wire [3:0] status_char_pos = status_text_dx[7:4];

reg [4:0] status_glyph_sel;
always @(*) begin
    case (status_char_pos)
        4'd0: status_glyph_sel = status_mode_stable[1] ? 5'd1 : 5'd0;
        4'd1: status_glyph_sel = status_mode_stable[0] ? 5'd1 : 5'd0;
        4'd2: status_glyph_sel = 5'd31; // 空格
        4'd3: status_glyph_sel = 5'd2;  // ·
        4'd4: status_glyph_sel = 5'd31; // 空格
        4'd5: begin
            case (status_mode_stable)
                2'b00: status_glyph_sel = 5'd3;  // 直
                2'b01: status_glyph_sel = 5'd7;  // 淡
                2'b10: status_glyph_sel = 5'd10; // 横
                default: status_glyph_sel = 5'd13;// 幕
            endcase
        end
        4'd6: begin
            case (status_mode_stable)
                2'b00: status_glyph_sel = 5'd4;  // 接
                2'b01: status_glyph_sel = 5'd8;  // 入
                2'b10: status_glyph_sel = 5'd11; // 向
                default: status_glyph_sel = 5'd14;// 布
            endcase
        end
        4'd7: begin
            case (status_mode_stable)
                2'b00: status_glyph_sel = 5'd5;  // 切
                2'b01: status_glyph_sel = 5'd7;  // 淡
                2'b10: status_glyph_sel = 5'd12; // 黑
                default: status_glyph_sel = 5'd15;// 开
            endcase
        end
        4'd8: begin
            case (status_mode_stable)
                2'b00: status_glyph_sel = 5'd6;  // 换
                2'b01: status_glyph_sel = 5'd9;  // 出
                2'b10: status_glyph_sel = 5'd13; // 幕
                default: status_glyph_sel = 5'd16;// 合
            endcase
        end
        default: status_glyph_sel = 5'd31;
    endcase
end

wire status_font_on;
mode_status_font_rom u_mode_status_font_rom(
    .glyph_sel (status_glyph_sel),
    .row       (status_text_dy[3:0]),
    .col       (status_text_dx[3:0]),
    .pixel_on  (status_font_on)
);

wire [23:0] status_text_color = (status_char_pos <= 4'd4)
                              ? STATUS_PREFIX_COLOR : STATUS_TITLE_COLOR;

// ---------------------------------------------------------------------------
// display_valid 来自 sd_card_clk(100MHz) 域，这里两级同步到 video_clk 再用。
// 该信号在首图提交后恒为 1，仅上电初期发生一次跳变；同步只为消除跳变瞬间的
// 亚稳态，不影响功能。
// ---------------------------------------------------------------------------
reg dv_s0;
reg dv_s1;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dv_s0 <= 1'b0;
        dv_s1 <= 1'b0;
    end else begin
        dv_s0 <= display_valid;
        dv_s1 <= dv_s0;
    end
end
wire dv_ok = dv_s1;

wire [23:0] normal_pixel = dv_ok ? mix_final : 24'd0;
wire [23:0] status_pixel = (status_text_zone && status_font_on)
                         ? status_text_color : STATUS_BG_COLOR;

// ---------------------------------------------------------------------------
// 图层(新增): 右上角时间戳 HH:MM:SS —— 对应扩展要求 01「动态文字(时间戳、标语)」
// 绘制逻辑全部在独立模块 clock_overlay.v 里，这里只在输出级插一级 mux，
// 不触碰上面三层(红条/滚动字幕/状态条)和两个转场状态机。
// 同样受 dv_ok 门控: 首图未就绪时整块不显示，避免"时钟先于画面出现"(同 r4 抢跑坑)。
// ---------------------------------------------------------------------------
wire        clock_hit;
wire [23:0] clock_pixel;

clock_overlay u_clock_overlay(
    .clk        (clk),
    .rst        (rst),
    .dv_ok      (dv_ok),
    .pixel_x    (pixel_x),
    .pixel_y    (pixel_y),
    .hit        (clock_hit),
    .pixel      (clock_pixel)
);

// ================= 输出级：只给左上两块加转场处理 =================
// 2026-11-02：需求是"转场时左上角那块灰底也要变黑"。
// **刻意只动状态条和时间戳这两支**，主通路 normal_pixel（底图/底灰条/滚动字幕）
// 完全保持 r23 原样，连一笔都不改 —— 这样一旦出问题，可以立刻确定不是主通路引起的。
//
//   · 模式10 横向黑幕：wipe_hide 是逐像素判据，擦除线扫过哪一列，状态条那列就变黑，
//                      边界与画面完全对齐；
//   · 模式11 幕布开合：curtain_black 是 mode_11_controller 内部 curtain_pixel 的
//                      原样引出，上下幕布压到哪一行，状态条那行就变黑；
//   · 模式01 淡入淡出：没有"逐像素遮罩"这种概念，走的是整屏亮度缩放，
//                      所以这里让状态条/时间戳也乘同一个 out_alpha，一起变暗。
//
// 运算量：只新增一处 scale_by_alpha（3 个 8x8 乘法），且仅在 overlay 命中时才用到。
// 叠加优先级: 状态条 > 时间戳 > 普通画面（与 r23 一致）
wire        trans_black  = (wipe_active & ~wipe_pass & wipe_hide) | curtain_black;
wire        overlay_hit  = status_bar_hit | clock_hit;
wire [23:0] overlay_raw  = status_bar_hit ? status_pixel : clock_pixel;
wire [23:0] overlay_pix  = trans_black            ? 24'h000000 :
                           (out_alpha == 8'd255) ? overlay_raw :
                                                   scale_by_alpha(overlay_raw, out_alpha);

assign out_pixel = (overlay_hit && dv_ok) ? overlay_pix :
                                           normal_pixel;

endmodule

//====================================================
// osd_text_cell — 字幕绘制单元
// 输入:相对字幕原点的偏移坐标(可为回绕大值)
// 输出:字面命中(纯黑文字,无阴影无透明)
//====================================================
module osd_text_cell #(
    parameter [15:0] CELL_W = 16'd216   // 字幕串总宽(变宽排版后的总宽)
)(
    input  wire [15:0]  dx,         // 相对字幕原点的列偏移
    input  wire [15:0]  dy,         // 相对字幕原点的行偏移
    input  wire         txt_sel,    // 0=开园句 1=闭园句(两句排版相同,共用字库)
    output wire         face_on
);

// ============ 变宽排版 ============
// 数字/字母 12px 格(位置 0~9),汉字 16px 格(位置 10~15)
// 总宽 = 10x12 + 6x16 = 216
function [8:0] pos_xbase;
    input [3:0] pos;
    begin
        case (pos)
            4'd0 : pos_xbase = 9'd0;
            4'd1 : pos_xbase = 9'd12;
            4'd2 : pos_xbase = 9'd24;
            4'd3 : pos_xbase = 9'd36;
            4'd4 : pos_xbase = 9'd48;
            4'd5 : pos_xbase = 9'd60;
            4'd6 : pos_xbase = 9'd72;
            4'd7 : pos_xbase = 9'd84;
            4'd8 : pos_xbase = 9'd96;
            4'd9 : pos_xbase = 9'd108;
            4'd10: pos_xbase = 9'd120;
            4'd11: pos_xbase = 9'd136;
            4'd12: pos_xbase = 9'd152;
            4'd13: pos_xbase = 9'd168;
            4'd14: pos_xbase = 9'd184;
            default: pos_xbase = 9'd200;
        endcase
    end
endfunction

// x → 位置号(比较器链;越界大值落到 15,由门控区挡掉)
function [3:0] pos_of;
    input [15:0] x;
    begin
        pos_of = (x < 16'd12)  ? 4'd0 :
                 (x < 16'd24)  ? 4'd1 :
                 (x < 16'd36)  ? 4'd2 :
                 (x < 16'd48)  ? 4'd3 :
                 (x < 16'd60)  ? 4'd4 :
                 (x < 16'd72)  ? 4'd5 :
                 (x < 16'd84)  ? 4'd6 :
                 (x < 16'd96)  ? 4'd7 :
                 (x < 16'd108) ? 4'd8 :
                 (x < 16'd120) ? 4'd9 :
                 (x < 16'd136) ? 4'd10 :
                 (x < 16'd152) ? 4'd11 :
                 (x < 16'd168) ? 4'd12 :
                 (x < 16'd184) ? 4'd13 :
                 (x < 16'd200) ? 4'd14 : 4'd15;
    end
endfunction

// 面层查找坐标(变宽解码)
wire [3:0]  c_sel = pos_of(dx);                // 位置号
// 注意:不能直接写 pos_xbase(c_sel)[3:0] —— 对函数调用结果做位选不符合
//       IEEE 1800 语法,TD 会报 HDL-5007 WARNING。先落成 wire 再取位。
wire [8:0]  c_xbase = pos_xbase(c_sel);        // 该字符的起始列
// 4 位模减 → 格内列号 0~15(格宽 12 或 16，低位足够)。再显式补 0 到 5 位，
// 与 font_rom 的 [4:0] col 端口位宽严格对齐：原先 4 位直连会让高位悬空，
// TD 报 PCDPC 位宽告警，ModelSim 仿真时高位为 X 导致字形输出全 X。
wire [3:0]  c_col4 = dx[3:0] - c_xbase[3:0];
wire [4:0]  c_col  = {1'b0, c_col4};
// 行号必须与字模行 1:1 对应: c_row = dy。不要再给数字/字母加行偏移
// (2026-10-05 曾试过 +3 做基线对齐, 上板后出现字符顶部被裁剪/字体消失, 已回退)。
// 字幕整体高度只能靠 L1_Y0 这类显示窗口 Y 参数调整, 不能动字模行映射。
wire [4:0]  c_row = dy[4:0];

// 门控区:面 dx<CELL_W
wire f_zone = (dx < CELL_W) && (dy < 16'd16);

wire f_px;

font_rom u_font_face(                       // 字本体:偏移(0,0)
    .char_sel   (c_sel),
    .txt_sel    (txt_sel),
    .row        (c_row),
    .col        (c_col),
    .pixel_on   (f_px),
    .outline_on ()
);

assign face_on   = f_zone && f_px;

endmodule

//====================================================
// mode_status_font_rom — 左上角模式条专用字模
//
// 该模块故意与 osd_engine 放在同一个、原工程已经稳定引用的源文件中。
// TD GUI 会缓存工程源文件列表；若 GUI 打开期间从磁盘增加一个新的 .v，旧的
// Active Syn 清单可能在下一次保存时覆盖磁盘工程并漏掉新文件。合并在这里可
// 消除这种工程清单依赖，同时保持字模逻辑和原滚动字幕 font_rom 完全独立。
// 字形数据由 python/mode_status_font2verilog.py 生成；映射表紧随其后。
//====================================================
// mode_status_font_rom — glyph ROM for "00 · 直接切换" and the other titles
// Generated by python/mode_status_font2verilog.py using the same 64x64
// grayscale -> LANCZOS -> 16x16 -> threshold pipeline as font_rom.v.
// Glyph map: 00 11 2· 3直 4接 5切 6换 7淡 8入 9出 10横 11向 12黑 13幕 14布 15开 16合
// Existing scrolling-subtitle FONT_ALL is not modified.
//====================================================
module mode_status_font_rom(
    input  wire [4:0] glyph_sel,
    input  wire [3:0] row,
    input  wire [3:0] col,
    output wire       pixel_on
);

localparam [4351:0] MODE_FONT_ALL = 4352'h0000_0808_1FFC_1FFC_180C_180C_1FFC_0FFC_0000_27F2_7FFF_1C1C_0730_03E0_01C0_00C0_0000_0000_3018_3818_1818_0C18_0C18_0410_7FFF_7FFF_0618_0618_0618_0610_3FFE_3FFF_0000_0040_08C8_0CDE_0CC6_0CC6_6C46_3CC6_1FFE_0CC0_0C40_0600_7FFF_3FFE_0300_0100_0000_0080_0C98_0888_7FFF_1FFE_0CDC_7FFF_1FFC_180C_1FFC_180C_1FFC_0630_3FFE_0630_0000_2000_3323_3366_1004_7FFF_7FFF_01C0_3FFE_0080_1FFC_1FFC_12A4_1694_1DDC_1FFC_0000_6038_603C_6404_67E4_67E4_6464_6464_6464_67E4_6004_6004_7FFC_0300_0300_0300_0000_0000_1B87_18CC_18CC_59FE_79B6_3FFE_3DB6_1DFE_1830_3FFF_3ECC_19FE_19FE_184C_0000_000C_7FFC_630C_610C_610C_610C_410C_0300_3FF8_3318_2108_2108_2118_0300_0100_0000_0000_7003_3806_0C0C_0618_0630_0330_0360_01E0_01C0_01C0_0180_0300_0600_0000_0000_0000_278F_31DC_1078_1B7C_0B66_0126_0220_3B86_70DC_0078_036C_0926_3926_0020_0000_3202_3307_19CC_18D8_1870_73FF_7DB6_1D36_1936_19F6_7FFC_7D88_10FC_18C0_1040_0000_0000_031E_0186_10C2_1CC3_1F63_1863_1863_1863_7823_7F23_1A23_1833_19FF_1800_0000_3302_33EE_1878_19F8_198C_7BFF_7FFF_1C60_1BFF_1BFF_7CC8_7C8C_19FE_1830_1020_0000_7FFF_7FFF_180C_1FFC_180C_1FFC_1FFC_1FFC_1FFC_180C_1FFC_0180_3FFF_3FFE_0080_0000_0000_0000_0000_0000_0000_01C0_01C0_01C0_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_7F00_7F00_0C00_0C00_0C00_0C00_0C00_0C00_0C00_0C00_7C00_1C00_0000_0000_0000_0000_1C00_3E00_6300_6300_6300_6300_6300_6300_6300_6300_3E00_1E00;
wire [255:0] glyph_bits = MODE_FONT_ALL[{glyph_sel, 8'b00000000} +: 256];
wire [15:0] glyph_row = glyph_bits[{row, 4'b0000} +: 16];
assign pixel_on = (glyph_sel < 5'd17) ? glyph_row[15 - col] : 1'b0;

endmodule
