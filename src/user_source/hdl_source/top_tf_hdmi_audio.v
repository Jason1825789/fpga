
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       sw1,            // 模式低位:与 SW2 组成 00/01/10/11
    input                       sw2,            // 模式高位
    input                       sw4,            // 音频总开关(SW4 / C5):拨上=开,拨下=关
    input                       sw3,            // 字幕文案选择(SW3 / C6):拨上=开园句,拨下=闭园句

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 21'd307200;   // 640*480,与 SDRAM 地址口同宽
parameter [ADDR_BITS-1:0] BUF0_ADDR    = {ADDR_BITS{1'b0}};
parameter [ADDR_BITS-1:0] BUF1_ADDR    = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data_raw2;     // 模式11纵向覆盖所需的备用图像
wire [23:0] vout_data;
wire        display_valid;

// 转场信号
wire        fade_start;         // sd_card_bmp → 转场控制器:保持型转场请求
wire        fade_done;          // 当前模式控制器 → sd_card_bmp:过渡完成(或取消)
wire [1:0]  transition_mode_latched; // 请求产生时锁存的 {sw2,sw1},防止中途串模式
wire        legacy_fade_start;  // 仅送原有 mode01/mode10 状态机
wire        legacy_fade_done;
wire        legacy_fade_rd;     // osd_engine 内保留的旧 mode11 接口(外置后恒不使用)
wire [1:0]  fade_state_dbg;     // 原有 mode01 状态:0=IDLE 1=ARM 2=RUN 3=HOLD
wire [3:0]  legacy_trans_state_dbg;   // OSD 转场状态码，目前只接不显示（见下文说明）

wire        mode11_request;
wire        mode11_selected;
wire        mode11_active;
wire        mode11_done;
wire        mode11_prefetch_en;
wire        mode11_consume_en;
wire [1:0]  mode11_state_dbg;
wire [23:0] mode11_pixel;
wire        mode11_cover;   // 模式11幕布逐像素覆盖标志 → 送 osd_engine 参与顶层掩蔽
wire [23:0] bg_pixel_selected;
wire        read_pair_ready;
wire [31:0] video_read_data2;

wire [3:0]  state_code;

// 播放进度（sd_card_clk 100MHz 域，下文两级同步到 clk 50MHz 再上数码管）
wire [2:0]  o_img_idx;      // 当前显示中的图片编号 0..7
wire [3:0]  o_img_total;    // 扫描到的图片张数 0..8

// sd_card_bmp 的诊断引出（sd_card_clk 100MHz 域，下文同步到 clk 50MHz 再上数码管）
wire [2:0]  dbg_req_cnt;
wire        dbg_pfb_valid;
wire        dbg_fade_pending;

// 卡死死因锁存器输出（同为 sd_card_clk 域，见 SD/switch_dbg_latch.v）
wire        dbg_fault;
wire [3:0]  dbg_load_cnt;
wire [3:0]  dbg_state_seen;
wire [3:0]  dbg_lat_a;
wire [3:0]  dbg_lat_b;
wire [3:0]  dbg_lat_c;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read2_req_ack;
reg         video_read2_req;
reg         video_read_req_d;
reg [1:0]   disp_buf_idx_v0;
reg [1:0]   disp_buf_idx_v1;
reg [1:0]   mode11_new_buf_idx;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;


wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire rst_all;
assign rst_all = ~rst_n | ~audio_pll_lock;

// ===========================================================================
// 音频总开关（SW4 / C5，拨上=开、拨下=关）
// ---------------------------------------------------------------------------
// 设计要点：**只在这一处门控 PCM 数据**，下游同时挂了两路消费者——
//   1) HDMI 发射核  .I_audio_left_data / .I_audio_right_data  → 决定有没有声音
//   2) spectrum_engine .audio_l                              → 决定频谱柱高不高
// 所以一个 mux 就同时管住了"声音 + 频谱图"，两者不可能出现一个开一个关的错位。
//
// 关断时**不动 audio_valid / ACR**：仍然照常以 48kHz 送数字静音(全 0)样本，
// 接收端(电视/显示器)不会因为音频中断而重新协商音频 InfoFrame，
// 避免"关开关的瞬间屏幕闪一下 / 声音设备重连"。
//
// 频谱侧不需要额外清零：spectrum_engine 收到全 0 样本后幅度 c_msb <= MSB_BASE
// 直接判 0，且 bars[] 每帧按 DECAY 自然下落 → 表现为"柱子平滑落到底"，比硬切自然。
//
// 消抖：拨码开关是机械件，动作时有毫秒级抖动；沿用本工程"两级同步 + 稳定 N 拍才认"
// 的做法。clk = 50MHz，400000 拍 ≈ 8ms。
// 极性：SW4 拨上=1=开，拨下=0=关；约束已配 PULLTYPE = PULLUP。
//       ★ 若实物方向相反（拨上变"关"），只改这一行 localparam 即可，不用动逻辑。
// ===========================================================================
localparam      SW4_ON_LEVEL = 1'b1;     // 1 = 拨上为开（当前假设）；反了就改 1'b0

wire        audio_on;                    // 1=开 0=关（已消抖）
wire [23:0] audio_l_out;                 // 门控后的 PCM（送 HDMI + 频谱）
wire [23:0] audio_r_out;

reg         sw4_d0;
reg         sw4_d1;
reg         sw4_stable;
reg  [19:0] sw4_cnt;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        sw4_d0     <= 1'b0;
        sw4_d1     <= 1'b0;
        sw4_stable <= 1'b0;
        sw4_cnt    <= 20'd0;
    end else begin
        sw4_d0 <= sw4;
        sw4_d1 <= sw4_d0;
        if (sw4_d1 != sw4_stable) begin
            if (sw4_cnt >= 20'd399999) begin
                sw4_stable <= sw4_d1;
                sw4_cnt    <= 20'd0;
            end else begin
                sw4_cnt <= sw4_cnt + 20'd1;
            end
        end else begin
            sw4_cnt <= 20'd0;
        end
    end
end

assign audio_on    = SW4_ON_LEVEL ? sw4_stable : ~sw4_stable;
assign audio_l_out = audio_on ? audio_left_data  : 24'sd0;
assign audio_r_out = audio_on ? audio_right_data : 24'sd0;

// ===========================================================================
// SW3 字幕文案选择:拨上=1=开园句, 拨下=0=闭园句(已消抖)
//   与 SW4 同款消抖。输出 txt_sel 直连 osd_engine → font_rom 的 txt_sel。
//   ★ 若实物方向相反(拨上变闭园句), 只改 SW3_ON_LEVEL 这一行即可。
// ===========================================================================
localparam      SW3_ON_LEVEL = 1'b0;     // 0 = 拨上为开园句(实测方向反了,已改)

wire        txt_sel;                      // 1=开园句 0=闭园句(已消抖)

reg         sw3_d0;
reg         sw3_d1;
reg         sw3_stable;
reg  [19:0] sw3_cnt;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        sw3_d0     <= 1'b0;
        sw3_d1     <= 1'b0;
        sw3_stable <= 1'b0;
        sw3_cnt    <= 20'd0;
    end else begin
        sw3_d0 <= sw3;
        sw3_d1 <= sw3_d0;
        if (sw3_d1 != sw3_stable) begin
            if (sw3_cnt >= 20'd399999) begin
                sw3_stable <= sw3_d1;
                sw3_cnt    <= 20'd0;
            end else begin
                sw3_cnt <= sw3_cnt + 20'd1;
            end
        end else begin
            sw3_cnt <= 20'd0;
        end
    end
end

assign txt_sel = SW3_ON_LEVEL ? sw3_stable : ~sw3_stable;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
// SD 控制器与 OSD 均接收原始模式 {sw2,sw1};
// 00 直接切换,01/10/11 等待各自的转场完成。
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (4'd8)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (key1),
    .key_auto          (key2),
    .sw_fade           (sw1),
    .sw2               (sw2),
    .fade_start        (fade_start),
    .fade_done         (fade_done),
    .transition_mode   (transition_mode_latched),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),

    // 只读诊断，仅送数码管
    .dbg_req_cnt       (dbg_req_cnt),
    .dbg_pfb_valid     (dbg_pfb_valid),
    .dbg_fade_pending  (dbg_fade_pending),
    .dbg_fault         (dbg_fault),
    .dbg_load_cnt      (dbg_load_cnt),
    .dbg_state_seen    (dbg_state_seen),
    .dbg_lat_a         (dbg_lat_a),
    .dbg_lat_b         (dbg_lat_b),
    .dbg_lat_c         (dbg_lat_c),

    .o_img_idx         (o_img_idx),
    .o_img_total       (o_img_total),

    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

// state_code 的段码译码统一放在下文"数码管实时视图（v2）"段里（第 6 位），
// 原来的 seg_decoder_m0 实例已删除。

// SW1 效果指示(原来占数码管物理第 7 位, 显示 '1'=淡化 / '2'=硬切)已取消:
//   SW1 的状态现在由下面的"模式指示"第 7 位 mode[0] 直接显示(0/1),
//   单独再占一位属于同一信息显示两遍。
//   (原 sw1_seg / sw1_seg_dec 已删除; 若要恢复 '1'/'2' 显示, 见 doc 第 21 节)
//
// 段码低有效(0=亮),与 seg_decoder 一致:{g,f,e,d,c,b,a}

// ---------------------------------------------------------------------------
// 图片切换模式指示(数码管物理第 6、7 位)
//   mode = {sw2, sw1}:
//       2'b00 → 图片硬切换模式
//       2'b01 → 淡入淡出模式    (sw1 上拨)
//       2'b10 → 原有横向黑幕切换模式
//       2'b11 → 老师实际视觉效果的安全纵向覆盖模式
//
//   ★ 位与开关的对应(2026-10-05 按用户确认):
//       物理第 6 位 = SEL5 / 引脚 F10 / 代码 seg_sel[3]  ← 显示 sw2 = mode[1]
//       物理第 7 位 = SEL6 / 引脚 E11 / 代码 seg_sel[4]  ← 显示 sw1 = mode[0]
//     (即:sw1 的状态显示在第 7 位、sw2 显示在第 6 位,
//      与原来"SW1 效果指示在第 7 位"的位置一致, 只是编码由 '1'/'2' 改成 0/1)
//     位序对照见工程根目录《开发板基础信息.md》:代码 seg_sel[0..5] 对应物理第 3~8 位;
//     物理第 1、2 位(SEL0/SEL1)板上未接线、永远灭, 不能用它们做指示。
//
//   注 1:这里用原始开关电平即时更新数码管指示;实际转场模式会送入 OSD 并消抖。
//   注 2:低有效段码(0=亮), 与 seg_decoder 一致:{g,f,e,d,c,b,a}。
// ---------------------------------------------------------------------------
wire [1:0] mode_sel = {sw2, sw1};       // 必须保持:mode_sel[1]=sw2, mode_sel[0]=sw1

// 一次保持型请求的模式在 sd_card_bmp 发起时锁存。
// 这样拨动开关不会让同一个 fade_start 同时启动两个不同控制器。
assign legacy_fade_start = fade_start & (transition_mode_latched != 2'b11);
assign mode11_request    = fade_start & (transition_mode_latched == 2'b11);
assign fade_done         = legacy_fade_done | mode11_done;

// 第 6/7 位的 sw2/sw1 段码已改为在下文"数码管取值选择"里统一 mux 后译码，
// 原来的 mode_seg_dec6 / mode_seg_dec7 两个实例已删除（避免重复译码）。

// ---------------------------------------------------------------------------
// 模式01的 fade_state 译码仍在, 但**当前不送给任何一位数码管**
//   原因:fade_state 原来占的那一位(代码 seg_data_3)已被"模式指示"的 mode[0] 占用,
//         而按用户要求"只占用第 6、7 位、其它位保持不变", 不能再占用其它空位。
//   要恢复显示:把下面这个实例的输出接到 seg_scan 的 .seg_data_0 / .seg_data_1 /
//         .seg_data_2 中任意一个(对应物理第 3/4/5 位) 即可, 一行改动。
//   数值含义:0 = IDLE(未转场)   1 = ARM(预热,等帧对齐)
//             2 = RUN(正在转场) 3 = HOLD(保持新图,等缓冲翻转)
//   排查模式01时:按切图键该值应有 0→1→2→3→0 的跳变;
//     若恒为 0 → 转场状态机没启动; 若画面不对, 再抓 bg_pixel_alt / rd2usedw。
// ---------------------------------------------------------------------------
reg [1:0] fade_state_s0;
reg [1:0] fade_state_s1;
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        fade_state_s0 <= 2'd0;
        fade_state_s1 <= 2'd0;
    end else begin
        fade_state_s0 <= fade_state_dbg;   // video_clk(25MHz) → clk(50MHz) 两级同步
        fade_state_s1 <= fade_state_s0;
    end
end

wire [6:0] fade_state_seg;
seg_decoder fade_state_seg_dec(
    .bin_data          ({2'b00, fade_state_s1}),
    .seg_data          (fade_state_seg)
);

// ---------------------------------------------------------------------------
// 统一转场状态码 trans_state_dbg 目前不占用任何数码管位（v2 改显示切图链路
//   的实时状态）。OSD 的 O_trans_state 仍接到 legacy_trans_state_dbg 线上，
//   需要时再把它接回某一位显示即可。
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 切图链路实时诊断：把 sd_card_bmp 的状态同步到 clk(50MHz) 域再上数码管。
//   全部为毫秒级慢变量，两级同步足够，不需要握手。
//   位定义与判读表见本段末尾"数码管实时视图（v2）"的注释。
//   复原方法：删掉本段与下文 v2 视图段，seg_scan 六个口改回 {1'b1,7'b1111_111}。
// ---------------------------------------------------------------------------
reg [2:0] dbg_req_s0;
reg [2:0] dbg_req_s1;

// v2 实时视图：各组 4 位状态，两级同步即可（都是慢变量）
reg [3:0]  dbg_lc_s0;        // load_cnt
reg [3:0]  dbg_lc_s1;
reg [3:0]  dbg_la_s0;        // lat_a
reg [3:0]  dbg_la_s1;
reg [3:0]  dbg_lb_s0;        // lat_b
reg [3:0]  dbg_lb_s1;
reg [3:0]  dbg_lc2_s0;       // lat_c
reg [3:0]  dbg_lc2_s1;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        dbg_req_s0 <= 3'd0;
        dbg_req_s1 <= 3'd0;
        dbg_lc_s0  <= 4'd0;
        dbg_lc_s1  <= 4'd0;
        dbg_la_s0  <= 4'd0;
        dbg_la_s1  <= 4'd0;
        dbg_lb_s0  <= 4'd0;
        dbg_lb_s1  <= 4'd0;
        dbg_lc2_s0 <= 4'd0;
        dbg_lc2_s1 <= 4'd0;
    end else begin
        dbg_req_s0 <= dbg_req_cnt;                        // sd_card_clk → clk
        dbg_req_s1 <= dbg_req_s0;
        dbg_lc_s0  <= dbg_load_cnt;
        dbg_lc_s1  <= dbg_lc_s0;
        dbg_la_s0  <= dbg_lat_a;
        dbg_la_s1  <= dbg_la_s0;
        dbg_lb_s0  <= dbg_lat_b;
        dbg_lb_s1  <= dbg_lb_s0;
        dbg_lc2_s0 <= dbg_lat_c;
        dbg_lc2_s1 <= dbg_lc2_s0;
    end
end

// ---------------------------------------------------------------------------
// 数码管显示：两套视图，用下面这个 localparam 在源码级切换
//   SEG_PROGRESS = 1 → 正式版【播放进度】：显示 "03-08"(第3张/共8张)
//   SEG_PROGRESS = 0 → 调试版【链路诊断】：沿用 r22 起的实时诊断视图
// 常量选择会被综合折叠，未选中的那一路逻辑不会进芯片，所以两套并存没有代价。
//
// 为什么默认用进度视图：答辩现场数码管如果一直跳十六进制调试码，既难看也不好解释；
// 进度视图同时还能证明"图确实在往下走"。
//
// 诊断视图（SEG_PROGRESS=0 时）：
//   第3位  req_cnt          排队请求数 0~4（0=按键没进队列）
//   第4位  {sd_init_done, bmp_ready, load_busy, display_valid}
//   第5位  {pfb_valid, fade_pending, scan_done, first_image_committed}
//   第6位  state_code       0=超时/复位 1=空闲 2=扫描或读表头 3=等FIFO 4=读数据
//   第7位  img_found_count  扫描到的张数（正常 8）
//   第8位  load_cnt         累计发起加载次数（只增，复位清零）
//   十六进制：10~15 显示 A/b/C/d/E/F。健康待机：第4位=F、第5位=b、第6位=1、第7位=8。
// ---------------------------------------------------------------------------
localparam      SEG_PROGRESS = 1'b1;    // 1=播放进度(正式版)  0=链路诊断(调试用)

// ============ 播放进度视图 ============
// 跨时钟域：o_img_idx / o_img_total 在 sd_card_clk(100MHz)，本段在 clk(50MHz)。
// 这两个值只在切图瞬间更新，两级同步足够；多比特偶尔可能采到中间值，但仅持续
// 1 个 20ns 周期，而单个数码管刷新周期是 5ms，肉眼不可见。与既有 dbg_* 同步一致。
reg [2:0] pidx_s0;
reg [2:0] pidx_s1;
reg [3:0] ptot_s0;
reg [3:0] ptot_s1;
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        pidx_s0 <= 3'd0;
        pidx_s1 <= 3'd0;
        ptot_s0 <= 4'd0;
        ptot_s1 <= 4'd0;
    end else begin
        pidx_s0 <= o_img_idx;       // sd_card_clk → clk
        pidx_s1 <= pidx_s0;
        ptot_s0 <= o_img_total;
        ptot_s1 <= ptot_s0;
    end
end

wire [6:0] pv_d3;
wire [6:0] pv_d4;
wire [6:0] pv_d5;
wire [6:0] pv_d6;
wire [6:0] pv_d7;
wire [6:0] pv_d8;

seg_progress_view u_seg_progress (
    .img_idx   (pidx_s1),
    .img_total (ptot_s1),
    .lat_a     (dbg_la_s1),     // {sd_init_done, bmp_ready, load_busy, display_valid}
    .seg_d3    (pv_d3),
    .seg_d4    (pv_d4),
    .seg_d5    (pv_d5),
    .seg_d6    (pv_d6),
    .seg_d7    (pv_d7),
    .seg_d8    (pv_d8)
);

// ============ 诊断视图（调试用，SEG_PROGRESS=0 时生效）============
wire [3:0] nib_d3 = {1'b0, dbg_req_s1};
wire [3:0] nib_d4 = dbg_la_s1;
wire [3:0] nib_d5 = dbg_lb_s1;
wire [3:0] nib_d6 = state_code;
wire [3:0] nib_d7 = dbg_lc2_s1;
wire [3:0] nib_d8 = dbg_lc_s1;

wire [6:0] dv_d3;
wire [6:0] dv_d4;
wire [6:0] dv_d5;
wire [6:0] dv_d6;
wire [6:0] dv_d7;
wire [6:0] dv_d8;

seg_decoder u_seg_d3(.bin_data(nib_d3), .seg_data(dv_d3));
seg_decoder u_seg_d4(.bin_data(nib_d4), .seg_data(dv_d4));
seg_decoder u_seg_d5(.bin_data(nib_d5), .seg_data(dv_d5));
seg_decoder u_seg_d6(.bin_data(nib_d6), .seg_data(dv_d6));
seg_decoder u_seg_d7(.bin_data(nib_d7), .seg_data(dv_d7));
seg_decoder u_seg_d8(.bin_data(nib_d8), .seg_data(dv_d8));

// ============ 视图选择 → 唯一的 seg_scan ============
wire [6:0] seg_d3 = SEG_PROGRESS ? pv_d3 : dv_d3;
wire [6:0] seg_d4 = SEG_PROGRESS ? pv_d4 : dv_d4;
wire [6:0] seg_d5 = SEG_PROGRESS ? pv_d5 : dv_d5;
wire [6:0] seg_d6 = SEG_PROGRESS ? pv_d6 : dv_d6;
wire [6:0] seg_d7 = SEG_PROGRESS ? pv_d7 : dv_d7;
wire [6:0] seg_d8 = SEG_PROGRESS ? pv_d8 : dv_d8;

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_d3}),     // 第3位
    .seg_data_1        ({1'b1,seg_d4}),     // 第4位(E10)
    .seg_data_2        ({1'b1,seg_d5}),     // 第5位
    .seg_data_3        ({1'b1,seg_d6}),     // 第6位(F10)
    .seg_data_4        ({1'b1,seg_d7}),     // 第7位(E11)
    .seg_data_5        ({1'b1,seg_d8})      // 第8位
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

// 第二读通道独立等待自己的 ACK;不能借主通道 ACK 提前撤销请求。
// 在每帧主读请求上升沿发起,预热期启动预读,退出 11 后停止。
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        video_read_req_d  <= 1'b0;
        video_read2_req   <= 1'b0;
        disp_buf_idx_v0    <= 2'd0;
        disp_buf_idx_v1    <= 2'd0;
        mode11_new_buf_idx <= 2'd1;
    end else begin
        video_read_req_d <= video_read_req;
        disp_buf_idx_v0 <= disp_buf_idx;
        disp_buf_idx_v1 <= disp_buf_idx_v0;
        // 本次转场开始前,备用缓冲为 disp_buf_idx^1。锁住物理地址直到
        // mode11 完全退出,避免 transition_done 翻转 disp_buf_idx 后,
        // HOLD 中下一帧请求把 ch2 改读回旧图。
        if (!mode11_active && !video_read2_req)
            mode11_new_buf_idx <= disp_buf_idx_v1 ^ 2'b01;
        // 请求发出后必须等 ch2 自己的 ACK 撤销；即使控制器刚退出 HOLD，
        // 也不能提前撤销跨域握手或释放其地址索引锁存。
        if (!video_read2_req && mode11_prefetch_en && video_read_req && !video_read_req_d)
            video_read2_req <= 1'b1;
        else if (video_read2_req && video_read2_req_ack)
            video_read2_req <= 1'b0;
    end
end

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .read_data2        (video_read_data2[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw),
    .vout_data2        (vout_data_raw2)
);

//  #################################################################################
// 像素坐标计数器:与延迟后的 de/vs 对齐,OSD 定位用
// 注意:640x480 场同步是负极性——同步脉冲期间 vs=0,其余时间 vs=1!
// 所以用 vs 下降沿(1→0)作为"新一帧开始"
reg [15:0] pixel_x;
reg [15:0] pixel_y;
reg        vs_d;                        // vs 打一拍,用于检测边沿
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        vs_d    <= 1'b0;
        pixel_x <= 16'd0;
        pixel_y <= 16'd0;
    end
    else begin
        vs_d <= vs;                     // 先记下上一拍的 vs
        if (vs_d & ~vs) begin           // 下降沿:1→0 = 场同步开始 = 新帧
            pixel_x <= 16'd0;
            pixel_y <= 16'd0;
        end
        else if (de) begin              // 有效像素区:每拍列+1
            pixel_x <= pixel_x + 16'd1;
            if (pixel_x == 16'd639)     // 一行扫完:行+1
                pixel_y <= pixel_y + 16'd1;
        end
        else                            // 消隐区:列归零
            pixel_x <= 16'd0;
    end
end

// ============ 模式11独立控制器 ============
// 单读通道上下幕布:只使用主图像流。旧 ch2 接口为兼容保留,
// 控制器恒不启用第二路预取/消费,避免双 FIFO 欠载时显示坐标继续前进。
// transition_mode_latched 在请求期间固定为 11,避免机械开关中途变化造成串模式。
mode_11_controller u_mode_11_controller(
    .clk               (video_clk),
    .rst               (rst_all),
    .vs                (vs),
    .mode_sel          (mode11_request ? transition_mode_latched : mode_sel),
    .transition_req    (mode11_request),
    .pixel_pair_ready  (read_pair_ready),
    .pixel_y           (pixel_y),
    .old_pixel         (vout_data_raw),
    .new_pixel         (vout_data_raw2),
    .read2_prefetch_en (mode11_prefetch_en),
    .read2_consume_en  (mode11_consume_en),
    .mode11_selected   (mode11_selected),
    .active            (mode11_active),
    .cover_black       (mode11_cover),
    .transition_done   (mode11_done),
    .state_dbg         (mode11_state_dbg),
    .mixed_pixel       (mode11_pixel)
);

// mode11_selected 使用与 OSD 相同的 16ms 整组消抖;
// active 保证全黑保护和开幕阶段始终由模式11控制器接管主通道。
assign bg_pixel_selected = (mode11_selected | mode11_active)
                         ? mode11_pixel : vout_data_raw;

// ============ 音频可视化：频谱引擎 ============
// 只负责"每根柱多高"，不碰像素通路，因此放在 OSD 前后都无所谓。
// 真正的叠加在 osd_engine 下游做，见本段末尾的 u_spectrum_overlay。
wire [7:0]  spec_bar_h;      // 当前像素所在柱的高度 0..240

spectrum_engine u_spectrum_engine (
    .clk         (video_clk),
    .rst         (rst_all),
    .audio_valid (audio_valid),      // 48kHz，与送 HDMI 的是同一路 PCM
    .audio_l     (audio_l_out),      // ★ 门控后的 PCM：SW4 关 → 全 0，柱子自然落到底
    .bar_idx     (pixel_x[9:3]),     // 每格 8 像素，位选即柱号，无除法器
    .bar_h       (spec_bar_h),
    .dbg_state   ()
);

// ============ OSD 叠加引擎(所有图层/字模仍在原 osd_engine.v 内) ============
// ★ .bg_pixel 接的是「不含频谱的原始图」，这是有意的：
//   横向黑幕(wipe_hide 直接刷 0)和淡入淡出(bg_eff × alpha)都在 osd_engine 内部
//   改写 bg_pixel，频谱只要留在它上游就一定会被一起刷黑/压暗。
//   所以频谱挪到下游(见下)，结构上就拿不到 alpha 和 wipe_hide，不可能被变黑。
wire [23:0] vout_data_osd;   // 转场 + OSD 之后的像素，尚未叠频谱

osd_engine u_osd_engine(
    .clk           (video_clk),
    .rst           (rst_all),
    .vs            (vs),
    .pixel_x       (pixel_x),
    .pixel_y       (pixel_y),
    .bg_pixel      (bg_pixel_selected),   // 原始图（不含频谱），转场在 osd_engine 内部改写它
    .bg_pixel_alt  (vout_data_raw2),
    .sw_fade       (sw1),
    .mode          (fade_start ? transition_mode_latched : mode_sel),
    .selected_mode_async(mode_sel), // 当前拨码选择;OSD 内两级同步+16ms 整组消抖
    .mode11_external(1'b1),       // 11 由 u_mode_11_controller 独立处理
    .curtain_black (mode11_cover),// 幕布逐像素覆盖 → 让 OSD 也一起被盖住
    .fade_start    (legacy_fade_start),
    .fade_rd       (legacy_fade_rd),
    .fade_done     (legacy_fade_done),
    .O_fade_state  (fade_state_dbg),
    .O_trans_state (legacy_trans_state_dbg),
    .display_valid (display_valid),
    .txt_sel       (txt_sel),          // SW3 选开园/闭园句
    .out_pixel     (vout_data_osd)
);

// ============ 频谱叠加：摆在转场的下游，最后一道 ============
// 黑幕/淡入淡出只作用在照片上，柱子保持常亮——效果就是幕布开合而频谱始终在上层。
// 绘制区 y=219..459，与底部红条(460+)、滚动字幕(462+)、左上状态条(0..23) 均不重叠，
// 因此放到最上层也不会遮挡任何 OSD 元素。
// ⚠ 若日后调大 spectrum_overlay 的 H_MAX 让柱顶越过 y=219，必须同步下移绘制窗，
//    否则会压到左上角状态条——那时频谱优先级已经高于 OSD。
wire [23:0] spec_pixel;      // 叠完频谱、但尚未过首图门控的像素

spectrum_overlay u_spectrum_overlay (
    .pixel_x    (pixel_x),
    .pixel_y    (pixel_y),
    .bar_h      (spec_bar_h),
    .bg_pixel   (vout_data_osd),
    .out_pixel  (spec_pixel)
);

// ============ 首图就绪门控 ============
// osd_engine 内部是用 display_valid 同步后的 dv_ok 去把 out_pixel 压成全黑，
// 但频谱现在在它下游，那条门控管不到——上电时 FFT 只要有输入就开始出柱高，
// 会出现"柱子先亮、画面和字幕后到"。
// 所以这里按同样方式同步一份 display_valid，用它再门控一次，
// 保证首图提交那一刻「画面 + 字幕 + 频谱」同时出现。
// 该信号在上电后只跳变一次(0→1)，两级同步只为消亚稳态。
reg spec_dv_s0;
reg spec_dv_s1;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        spec_dv_s0 <= 1'b0;
        spec_dv_s1 <= 1'b0;
    end else begin
        spec_dv_s0 <= display_valid;
        spec_dv_s1 <= spec_dv_s0;
    end
end

assign vout_data = spec_dv_s1 ? spec_pixel : 24'd0;
// #################################################################################



// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
//assign vout_data = display_valid ? ~vout_data_raw : 24'd0;
// vout_data_raw = 从 SDRAM 读出来、经过时序对齐的"原始像素数据"---"raw"就是"未加工原料"的意思
/*
display_valid 是"第一张图已完整写入 SDRAM 并提交显示"的标志
display_valid = 1 → 画面有效,把 SDRAM 出来的每个像素取反后送给 HDMI(反色滤镜)
display_valid = 0 → 首图还没就绪,输出 24 位全 0(纯黑),防止显示 SDRAM 里的垃圾数据
*/
frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       ({ADDR_BITS{1'b0}}),
    .read_addr_3       ({ADDR_BITS{1'b0}}),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    // 第二读通道为兼容旧工程保留；单读幕布模式下两个控制使能恒为0。
    .read2_req         (video_read2_req),
    .read2_req_ack     (video_read2_req_ack),
    .read2_finish      (),
    .read2_addr_0      (BUF0_ADDR),
    .read2_addr_1      (BUF1_ADDR),
    .read2_addr_2      ({ADDR_BITS{1'b0}}),
    .read2_addr_3      ({ADDR_BITS{1'b0}}),
    .read2_addr_index  (mode11_new_buf_idx),
    .read2_len         (FRAME_PIXELS),
    // mode11_consume_en 恒为0，不让 ch2 参与主读 FIFO 的消费门控。
    .read2_en          (video_read_en & mode11_consume_en),
    .read2_data        (video_read_data2),
    .read_pair_ready   (read_pair_ready),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      ({ADDR_BITS{1'b0}}),
    .write_addr_3      ({ADDR_BITS{1'b0}}),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

// 缓冲别名自检:仿真中若"正在写入的缓冲"与"正在显示的缓冲"相同则报错
// synopsys translate_off
`ifdef SIMULATION
always @(posedge ext_mem_clk) begin
    if (display_valid && App_wr_en && (write_buf_idx == disp_buf_idx))
        $display("[BUF ALIAS ERROR] write_buf_idx == disp_buf_idx == %0d @ %0t", disp_buf_idx, $time);
end
`endif
// synopsys translate_on

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：内部 I2S 测试音 =====================
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd2000000)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (rst_all),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_all),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_l_out),    // ★ 门控后的 PCM：SW4 关 → 数字静音
    .I_audio_right_data (audio_r_out),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

// ===========================================================================
// seg_progress_view —— 数码管"播放进度"字段生成
//
// 单独成模块（放在本文件内，不新增工程文件）是为了能被仿真直接例化验证。
// r30 那次的教训是"只测了模块内部、没测接缝"，这里把整段映射做成可测单元，
// 仿真直接驱动 img_idx / img_total，检查 6 路段码是否符合预期。
//
// 输出 6 组 7 位段码，对应物理第 3~8 位（左→右）：
//   第3位 = 当前张号十位（恒 0，见下方说明）
//   第4位 = 当前张号个位（1~8）
//   第5位 = '-'          分隔符
//   第6位 = 总张数十位（恒 0）
//   第7位 = 总张数个位（0~8）
//   第8位 = 故障码（平时全灭，只有 display_valid=0 黑屏时才出现）
// 于是正常时整屏读作 "03-08"，即"第 3 张 / 共 8 张"。
//
// 关于"十位恒 0"：
//   img_idx 是 3 位（0..7）→ 当前张号 = img_idx + 1 ≤ 8；
//   img_found_count 在 sd_card_bmp 里受 `if (img_found_count < 4'd8)` 饱和，上限也是 8。
//   两个十位永远是 0，所以直接输出 "0" 的段码，不做除法。
//   ★ 若以后把 img_idx 位宽或 SCAN_TARGET_COUNT 改到 >9，这里必须改成真除法。
//
// 关于第8位的"故障码"（2026-11-03 加，起因是 r32 上板黑屏但数码管显示 01-08 却读不到死因）：
//   lat_a = {sd_init_done, bmp_ready, load_busy, display_valid}，与诊断视图第4位同源。
//   正常（display_valid=1）时第8位全灭，不破坏 "03-08" 的观感；
//   一旦黑屏（display_valid=0）立刻把这个 nibble 显示出来，用来一眼判断：
//     d / f            → 一切健康（不该黑屏）
//     7 / 3            → display_valid=0，首图没提交；看 bit2/bmp_ready 与 bit1/load_busy
//     6 / 2 / 0        → bmp_ready=0，bmp_read 没回 IDLE（卡在读数据）
//     bit3=0           → sd_init_done=0，SD 卡在重新初始化（对应第7位在 0/8 之间跳）
//
// 帧序约定（与 seg_decoder 一致）：7 位里 bit0=a … bit6=g，**0 = 点亮**。
// ===========================================================================
module seg_progress_view(
    input  wire [2:0]  img_idx,      // 当前图片编号 0..7（已同步到本时钟域）
    input  wire [3:0]  img_total,    // 扫描到的张数 0..8
    input  wire [3:0]  lat_a,        // {sd_init_done, bmp_ready, load_busy, display_valid}
    output wire [6:0]  seg_d3,       // 第3位：当前张号十位
    output wire [6:0]  seg_d4,       // 第4位：当前张号个位
    output wire [6:0]  seg_d5,       // 第5位：'-'
    output wire [6:0]  seg_d6,       // 第6位：总张数十位
    output wire [6:0]  seg_d7,       // 第7位：总张数个位
    output wire [6:0]  seg_d8        // 第8位：故障码（正常时全灭）
);

localparam [6:0] SEG_ZERO  = 7'b100_0000;   // "0"（a~f 亮，g 灭）
localparam [6:0] SEG_DASH  = 7'b011_1111;   // "-"（只有 g 亮）
localparam [6:0] SEG_BLANK = 7'b111_1111;   // 全灭

// 当前张号 = 编号 + 1（显示 1~8，而不是 0~7，符合"第几张"的直觉）
// img_idx ≤ 7 → 结果 1..8，4 位足够，不会溢出到 9
wire [3:0] cur = {1'b0, img_idx} + 4'd1;

wire [6:0] seg_cur_ones;    // 当前张号个位
wire [6:0] seg_tot_ones;    // 总张数个位
wire [6:0] seg_fault;       // 故障码

seg_decoder u_cur_ones(.bin_data(cur),       .seg_data(seg_cur_ones));
seg_decoder u_tot_ones(.bin_data(img_total), .seg_data(seg_tot_ones));
seg_decoder u_fault   (.bin_data(lat_a),     .seg_data(seg_fault));

assign seg_d3 = SEG_ZERO;
assign seg_d4 = seg_cur_ones;
assign seg_d5 = SEG_DASH;
assign seg_d6 = SEG_ZERO;
assign seg_d7 = seg_tot_ones;
// display_valid = lat_a[0]；为 1（画面正常）时第8位灭，为 0（黑屏）时显示故障码
assign seg_d8 = lat_a[0] ? SEG_BLANK : seg_fault;

endmodule
