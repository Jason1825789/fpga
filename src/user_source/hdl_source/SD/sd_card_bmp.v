
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [3:0]   SCAN_TARGET_COUNT = 4'd8
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       sw_fade,        // SW1:模式低位(与 sw2 一起选择 00/01/10/11)
    input                       sw2,            // SW2:模式选择(与 sw1 组成 mode={sw2,sw1})
    output [3:0]                state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,

    // ---- 只读诊断输出 ------------------------------------------------------
    // 仅用于数码管观察,不参与任何逻辑,也不改变任何内部行为。
    // 用途:按键/切图异常时,一眼看出是"请求没进来"(req_cnt=0)还是
    //      "备用缓冲没就绪"(pfb_valid=0)还是"转场没结束"(fade_pending=1)。
    output wire [2:0]           dbg_req_cnt,
    output wire                 dbg_pfb_valid,
    output wire                 dbg_fade_pending,

    // ---- 卡死死因锁存器（见 SD/switch_dbg_latch.v）-------------------------
    // 同样只读、不参与逻辑。req_cnt 非空且 3 s 无提交时冻结一次现场。
    output wire                 dbg_fault,
    output wire [3:0]           dbg_load_cnt,     // 锁存后重新发起加载的次数
    output wire [3:0]           dbg_state_seen,   // 锁存后 bmp_read 到过的状态掩码
    output wire [3:0]           dbg_lat_a,        // {load_busy,src_done,bmp_ready,disp_valid}
    output wire [3:0]           dbg_lat_b,        // {scan_done,fade,pfb_valid,first_committed}
    output wire [3:0]           dbg_lat_c,        // img_found_count

    // ---- 播放进度（只读，供数码管显示"第 N 张 / 共 M 张"）-------------------
    // 与上面 dbg_* 一样不参与任何功能逻辑，删掉不影响原有行为。
    // 单独引出是为了让正式版的数码管视图不依赖调试模块 switch_dbg_latch。
    output wire [2:0]           o_img_idx,        // 当前正在显示的图片编号 0..7
    output wire [3:0]           o_img_total,      // 扫描到的图片张数 0..8（饱和 8）

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      fade_start,     // 保持型转场请求,直到收到 fade_done
    input                       fade_done,      // 当前转场完成(或中途取消):1 拍脉冲
    output reg [1:0]            transition_mode,// 发起请求时锁存的 {sw2,sw1}
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_press;

// 转场等待超时:osd 侧若在此时限内未返回 fade_done,则按硬切完成,避免按键永久锁死。
// 必须大于 osd_engine 的完整转场时长。模式 1 是两段式(先变暗、再变亮),每段
// 255/ALPHA_STEP 帧,再加 HOLD_FRAMES 帧:
//   ALPHA_STEP=8，含全黑跨域等待与 HOLD，共约 73 帧 ≈ 1.22s @60Hz。
// 这里给 5 秒留足余量，也方便后续把 ALPHA_STEP 调小（调小会更慢）。
localparam [31:0] FADE_TIMEOUT_CYCLES = CLK_FREQ_HZ * 5;   // 5 秒

// ============================================================================
// 自动轮播周期(2026-10-05 修正)
// ============================================================================
// 原来直接用 CLK_FREQ_HZ 当周期 = 1000ms,但实测最长的转场是
//   mode=2'b10 黑幕擦除 : 88 帧 = 1478.4ms
//   mode=2'b01 淡入淡出 : 76 帧 = 1276.8ms
// 周期 < 动画时长 → 请求生产速率高于消费速率,req_cnt(3位,上限7)持续积压,
// 大约 23 秒后压满,表现为"切换节奏全乱 / 越播越快"。
//
// 改成 2000ms:对两种动画都留 500ms 以上余量,不会积压。
// 不要用 2*CLK_FREQ_HZ 之外的算法(保持整数倍,便于心算)。
// ⚠ 若以后把 WIPE_STEP 调小(动画变长)或给黑幕加更多 HOLD 帧,必须同步复核这个值。
localparam [31:0] AUTO_PLAY_PERIOD_CYCLES = 2 * CLK_FREQ_HZ;  // 2000 ms

// 请求队列深度（"当前正在处理的一次 + 最多 3 次待处理"）。
//   历史：最早饱和到 7；快速连按会把 01/10 的整段动画依次排队，7 次请求
//   需要约 8.9 s / 10.3 s 才能排空，观感是按键失去响应。后来收到 2 级。
//   但对 2 级来说，快速连按第 3 下之后的请求会被**静默丢弃**
//   （`if (req_cnt < REQ_QUEUE_MAX)` 才加），用户看到的是"按了没反应"，
//   与真正的卡死在体感上无法区分。实测 7 张图、转场模式一次约 1.27 s，
//   取 4 级：连按 4 下全部登记，排空约 5 s；再多的重复输入仍会被合并丢弃，
//   避免用户停手后系统长时间执行过期请求。
//   req_cnt 是 3 位（最大 7），4 级在位宽范围内。
localparam [2:0] REQ_QUEUE_MAX = 3'd4;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [3:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg              fade_req;                // 转场请求:保持到 osd 确认,避免跨到 25MHz 丢脉冲
reg              fade_pending;            // 转场进行中(翻转已推迟)
reg              mode11_pending;          // mode11 在途时锁住转场路径,不因拨回 00 而硬切
reg              fade_done_d0;            // fade_done 跨域同步链
reg              fade_done_d1;
reg              fade_done_d2;
reg              sw_fade_d0;              // sw_fade 跨域同步链
reg              sw_fade_d1;
reg              sw2_d0;                  // sw2 跨域同步链(2026-10-05 新增, 决定转场路径)
reg              sw2_d1;
reg [1:0]        mode_sync_d;             // 上一拍稳定模式,用于检测模式切换
wire             sw_fade_sync;
wire             sw2_sync;
wire [1:0]       mode_sync;
wire             mode_change_pulse;
wire             trans_mode;
wire             mode11_sync;
reg [31:0]       fade_wait_cnt;           // 转场等待计数(超时保护)
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [3:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg [31:0]       img_sector6;
reg [31:0]       img_sector7;
// 预取双缓冲 + 有界请求计数（当前请求 + 最多一个后续请求）
reg [2:0]        req_cnt;
reg              pfb_valid;            // 备用缓冲里是否已预取好"下一张"
reg [2:0]        pfb_idx;             // 备用缓冲里预取的是第几张图
reg              load_busy;
reg [31:0]       load_timeout_cnt;   // 加载超时保护计数器(2 秒)

// bmp_ready 先表示"源文件读取/送 FIFO 完成"；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
wire             bmp_load_done;         // bmp_read 的真完成脉冲（源图数据全部读完时拉高一拍）

// ---------------------------------------------------------------------------
// 备用缓冲"保鲜重写"定时器
//
// 本工程的 SDRAM 控制器刷新路径不可用（见 SD/sdram.v 的 self_refresh_open）：
// 打开标准刷新会污染读数据（画面出现横向彩色条），降频后又会把读写仲裁挂死。
// 而备用缓冲长期不被访问会因电荷泄漏而损坏（实测静置 20~30 秒后切图即出现噪点）。
//
// 替代方案：每 STANDBY_REWRITE_CYCLES 把同一张图从 TF 卡原样重读、写回同一块
// 缓冲。重写内容与原内容完全一致，屏幕无感知；走的是已验证的写通道，不引入
// 新的时序交互。5 秒相对 20~30 秒的实测保持时间留 4~6 倍余量。
// ---------------------------------------------------------------------------
localparam [31:0] STANDBY_REWRITE_CYCLES = 5 * CLK_FREQ_HZ;   // 5 秒

reg [31:0] pfb_age_cnt;
always @(posedge clk or posedge rst) begin
    if (rst)
        pfb_age_cnt <= 32'd0;
    else if (!pfb_valid)
        pfb_age_cnt <= 32'd0;
    else if (pfb_age_cnt < STANDBY_REWRITE_CYCLES)
        pfb_age_cnt <= pfb_age_cnt + 32'd1;
end
wire pfb_rewrite_req = pfb_valid && (pfb_age_cnt >= STANDBY_REWRITE_CYCLES);

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;
wire             fade_timeout;
wire             fade_done_pulse;

wire auto_tick;
wire [2:0] next_from_current;
wire key_req_enqueue;
wire auto_req_enqueue;
wire req_enqueue;
wire req_queue_clear;
wire transition_commit_now;
wire hard_commit_now;
wire req_commit_now;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign fade_start = fade_req;
assign auto_tick  = (auto_cnt == (AUTO_PLAY_PERIOD_CYCLES - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
// 播放进度只读引出（纯观测，不参与逻辑）
assign o_img_idx   = img_idx;
assign o_img_total = img_found_count;
assign fade_timeout       = fade_pending && (fade_wait_cnt >= (FADE_TIMEOUT_CYCLES - 32'd1));
assign key_req_enqueue    = key_next_press && scan_done && (img_found_count > 3'd0);
assign auto_req_enqueue   = auto_play_en && auto_tick && scan_done && (img_found_count > 3'd1);
assign req_enqueue        = key_req_enqueue | auto_req_enqueue;
// 清队列只在"确实把自动播放关掉"的当拍发生。
//   原实现只有 key_auto_press && auto_play_en，比下面的切换条件少了
//   scan_done 与 img_found_count>1 两个条件。后果：在扫描未完成、或卡内
//   只有 1 张图时按 KEY04，切换动作被拒绝（auto_play_en 不变），但等待中的
//   请求却被无理由清空 —— 表现为"按了没反应"。
//   这里补全成与切换条件完全一致，保证"清队列"必然伴随"关掉自动播放"。
assign req_queue_clear    = key_auto_press && auto_play_en &&
                            scan_done && (img_found_count > 3'd1);

// 与下面两条提交路径使用完全相同的条件，统一在一个地方更新 req_cnt。
// 这样“新按键”和“上一张完成”落在同一拍时是一进一出，不会因多个非阻塞赋值
// 的先后顺序把新按键覆盖掉。
// 在途转场使用 transition_mode 锁存的模式完成；提交条件不能再依赖实时拨码，
// 否则 01/10 进行中拨回 00 会漏掉完成事件并破坏请求计数。
assign transition_commit_now = fade_pending && (fade_done_pulse || fade_timeout);
assign hard_commit_now       = !(trans_mode || mode11_pending) &&
                               !mode_change_pulse && (req_cnt != 3'd0) &&
                               pfb_valid && display_valid;
assign req_commit_now        = transition_commit_now | hard_commit_now;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [2:0] next_index_limited;
    input [2:0] cur;
    input [3:0] count;
    begin
        if (count <= 3'd1)
            next_index_limited = 3'd0;
        else if (cur >= count - 1'b1)      // 到末尾 → 回到 0(支持 2~8 张)
            next_index_limited = 3'd0;
        else
            next_index_limited = cur + 3'd1;
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            3'd6: sector_lut = img_sector6;
            3'd7: sector_lut = img_sector7;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

// 注：旧的 next_buf_lut 函数已删除——引入预取双缓冲后，备用缓冲恒为 disp_buf_idx^1，
// 无需查表；首图固定写 buf0 由 display_valid==0 分支直接赋值。

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        fade_req              <= 1'b0;
        fade_pending          <= 1'b0;
        mode11_pending        <= 1'b0;
        transition_mode       <= 2'b00;
        fade_wait_cnt         <= 32'd0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 3'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        img_sector6           <= 32'd0;
        img_sector7           <= 32'd0;
        req_cnt               <= 3'd0;
        pfb_valid             <= 1'b0;
        pfb_idx               <= 3'd0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        source_done_seen      <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        // 转场等待计数:仅在 fade_pending 期间累加,超时由 fade_timeout 触发硬切兜底
        if (fade_pending) begin
            if (fade_wait_cnt >= (FADE_TIMEOUT_CYCLES - 32'd1))
                fade_wait_cnt <= FADE_TIMEOUT_CYCLES - 32'd1;
            else
                fade_wait_cnt <= fade_wait_cnt + 32'd1;
        end else begin
            fade_wait_cnt <= 32'd0;
        end

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 3'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
            img_sector6           <= 32'd0;
            img_sector7           <= 32'd0;
            req_cnt               <= 3'd0;
            pfb_valid             <= 1'b0;
            pfb_idx               <= 3'd0;
            fade_pending          <= 1'b0;
            fade_req              <= 1'b0;
            mode11_pending        <= 1'b0;
            transition_mode       <= 2'b00;
            fade_wait_cnt         <= 32'd0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            source_done_seen      <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存前 8 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;
                    3'd5: img_sector5 <= scan_found_sector;
                    3'd6: img_sector6 <= scan_found_sector;
                    3'd7: img_sector7 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 4'd8)
                    img_found_count <= img_found_count + 4'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            // ★ 旧写法 if(load_busy && bmp_ready) 有 bug：发起加载当拍 bmp_ready 还是 1
            //   （bmp_read 要到下一拍才离开 ST_IDLE），导致 source_done_seen 提前置 1，
            //   完成判定退化成"加载期间来任意一个 write_finish_pulse 就算完成"，
            //   而该脉冲是单拍边沿，丢了就永远没第二次 → 预取失败 → 偶发黑屏。
            //   现改用 bmp_read 的 load_done 电平（读完最后一字节回 IDLE 后保持 1，
            //   直到下次 load_start）。用"电平"而非"脉冲"：因为 write_finish_pulse 也是
            //   单拍，若 load_done 用单拍脉冲，两者同拍到达时 source_done_seen 因非阻塞
            //   赋值延迟一拍而漏判 → 首图/预取提交失败 → 黑屏。电平则稳定保持，
            //   write_finish_pulse 到达时 source_done_seen 早已置 1，必能捕获。
            if (load_busy && bmp_load_done)
                source_done_seen <= 1'b1;

            // ===== 加载完成提交：区分"首图上屏"和"预取填充" =====
            if (load_busy && source_done_seen && write_finish_pulse) begin
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;
                if (!display_valid) begin
                    // 首图完成：直接上屏
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                    pfb_valid             <= 1'b0;
                end else begin
                    // 预取完成：只填备用缓冲，不切换显示
                    pfb_idx   <= load_idx;
                    pfb_valid <= 1'b1;
                end
            end

            // 加载超时保护：2 秒内没完成提交（读卡中止/帧未写全）→ 强制释放，防止连按卡死
            if (load_busy) begin
                if (load_timeout_cnt >= (CLK_FREQ_HZ * 2) - 1) begin
                    load_busy        <= 1'b0;
                    source_done_seen <= 1'b0;
                    load_timeout_cnt <= 32'd0;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次"扫描前 8 张 BMP"
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 3'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                req_cnt               <= 3'd0;
                pfb_valid             <= 1'b0;
                pfb_idx               <= 3'd0;
                fade_pending          <= 1'b0;
                fade_req              <= 1'b0;
                mode11_pending        <= 1'b0;
                transition_mode       <= 2'b00;
                fade_wait_cnt         <= 32'd0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
            end else begin
                // 按键与自动播放请求在本 always 块末尾统一更新 req_cnt。

                // 自动播放开/关
                if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 2s 计数：不再受 !load_busy 影响
                // （预取机制让 load_busy 长期为 1，若仍门控 !load_busy 则 auto 永远不计时）
                // 切换显示模式后重新等待一个完整自动轮播周期，避免旧计时器在
                // 新模式刚选中时立即产生一次看似“自动跳图”的请求。
                if (mode_change_pulse) begin
                    auto_cnt <= 32'd0;
                end else if (scan_done && auto_play_en && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // =========================================================
                // 换图动作块:两套彼此独立的切图路径,由 mode={sw2,sw1} 选择,互不干扰
                //
                //   路径 A(mode = 2'b01/10/11,需要转场):
                //       发起转场请求(fade_req / fade_pending)
                //       → 等对应转场控制器回 fade_done → 翻转显示缓冲
                //       → fade_wait_cnt 超时兜底
                //       mode 01: osd 里跑"两段式淡入淡出"FSM
                //       mode 10: osd 里跑"横向黑幕擦除"FSM
                //       mode 11:独立 mode_11_controller 跑"自下向上覆盖"FSM
                //       —— 三者共用同一套握手,并锁存 transition_mode 防止串模式。
                //
                //   路径 B(mode = 2'b00,直接切换):
                //       立即翻转显示缓冲,一次按键切一张
                //
                //   ★ 关键:路径 B 完全不读也不写 fade_req / fade_pending / fade_done,
                //     所以任何转场方式留下的状态都不可能把硬切卡住。
                //     两条路径只共用"翻转 disp_buf_idx / 提交 pfb"这几个赋值,
                //     触发条件与状态变量各自独立。
                // =========================================================
                // fade_pending 表示已经开始的转场。即使用户中途拨到 00，也必须
                // 继续使用 transition_mode 锁存值完成当前一次，不能半途撤销。
                if (fade_pending || trans_mode || mode11_pending) begin
                    // ---------------- 路径 A:转场(01/10/11) ----------------
                    if (!mode_change_pulse && req_cnt != 3'd0 && pfb_valid &&
                        display_valid && !fade_pending) begin
                        fade_req     <= 1'b1;   // 保持型请求:不依赖单拍脉冲跨到 25MHz
                        fade_pending <= 1'b1;
                        // 锁存本次请求的模式,顶层据此只允许一个控制器接管。
                        transition_mode <= {sw2_sync, sw_fade_sync};
                        mode11_pending  <= mode11_sync;
                    end
                    if (fade_done_pulse && fade_pending) begin
                        // osd 报告转场完成 → 此时才翻转显示缓冲
                        disp_buf_idx  <= disp_buf_idx ^ 2'b01;
                        img_idx       <= pfb_idx;
                        display_valid <= 1'b1;
                        pfb_valid     <= 1'b0;
                        fade_pending  <= 1'b0;
                        fade_req      <= 1'b0;
                        mode11_pending <= 1'b0;
                    end else if (fade_timeout) begin
                        // osd 无响应/脉冲丢失 → 按硬切完成,避免 fade_pending 永久为 1
                        disp_buf_idx  <= disp_buf_idx ^ 2'b01;
                        img_idx       <= pfb_idx;
                        display_valid <= 1'b1;
                        pfb_valid     <= 1'b0;
                        fade_pending  <= 1'b0;
                        fade_req      <= 1'b0;
                        mode11_pending <= 1'b0;
                    end
                end else begin
                    // ---------------- 路径 B:直接切换(硬切) ----------------
                    // 只依赖"有按键请求 + 备用缓冲已就绪",不依赖任何转场状态。
                    // 顺手把转场状态清干净,保证从模式 1 切回模式 2 时不被残留状态影响。
                    fade_req     <= 1'b0;
                    fade_pending <= 1'b0;
                    mode11_pending <= 1'b0;
                    if (!mode_change_pulse && req_cnt != 3'd0 && pfb_valid && display_valid) begin
                        disp_buf_idx  <= disp_buf_idx ^ 2'b01;
                        img_idx       <= pfb_idx;
                        display_valid <= 1'b1;
                        pfb_valid     <= 1'b0;
                    end
                end

                // ★ 停止自动轮播的当拍：丢弃尚未开始的排队请求（req_cnt 存量）。
                //   现象：按 key2 停止后图片还会再切约 2 张才停。
                //   原因：auto_play_en 只门控 auto_tick 的"汇入"，不控制已经排在
                //         req_cnt 里的存量；而这些请求与 key1 共用队列、会被逐个执行。
                //   本方案（B）只清存量，不动在途转场：正在跑的那一次淡入淡出会
                //   正常走完并切 1 张后停止（fade_req / fade_pending 保持不变）。
                //   req_queue_clear 在本 always 块末尾的唯一更新点处理；若与完成事件同拍，
                //   清零优先，避免完成分支和按键分支分别写 req_cnt。
                // (2) 首图加载（还没有任何显示）→ 固定写 buf0
                if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 3'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                end
                // (2.5) 保鲜重写：把"备用缓冲里那张图"原样重写一遍
                //     触发：备用缓冲已就绪且超过 5 秒未被重写
                //     重写期间 pfb_valid 清零，切图请求会排队等它写完，避免
                //     "半写状态的缓冲被翻上来显示"。
                //
                // ★ 必须"完全空闲"才允许重写（!fade_pending && req_cnt==0）：
                //   本条和下面的切图提交都用同一个旧 disp_buf_idx 算目标缓冲
                //   （重写写 disp^1，提交把 disp 翻成 disp^1）。两者若落在同一拍，
                //   重写会写进**刚刚变成显示**的那块；写完把 pfb_idx 赋成 load_idx，
                //   于是 pfb_idx == img_idx，之后每次按键只翻转缓冲、img_idx 不变，
                //   画面看起来永远不动 —— 这正是"快速连按切图键后卡死"的成因。
                //   测到现象：每 5 秒一次重写，7 张图转场模式下一次切换约 1.27 s，
                //   连按时系统几乎全程处于转场中，撞车概率被显著放大。
                //   连续切图时每次预取本来就会把整帧真实图像写进备用缓冲，
                //   等于天然保鲜，因此推迟重写不会让备用缓冲失鲜。
                else if (scan_done && bmp_ready && display_valid && !load_busy && pfb_rewrite_req &&
                         !fade_pending && !mode11_pending && (req_cnt == 3'd0)) begin
                    load_idx         <= pfb_idx;
                    load_sector      <= sector_lut(pfb_idx);
                    pending_buf_idx  <= disp_buf_idx ^ 2'b01;
                    write_buf_idx    <= disp_buf_idx ^ 2'b01;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    pfb_valid        <= 1'b0;
                end
                // (3) 预取：把"当前显示图的后继"读进备用缓冲 disp_buf_idx^1
                //     为什么不用 next_buf_lut：备用缓冲恒为 disp_buf_idx^1，
                //     首图(display_valid==0)走分支(2)写 buf0，此处只在已有显示时预取，
                //     所以 disp_buf_idx^1 天然就是"另一块"，无需查表。
                else if (scan_done && bmp_ready && display_valid && !load_busy && !pfb_valid && (img_found_count > 3'd1)) begin
                    load_idx         <= next_index_limited(img_idx, img_found_count);
                    load_sector      <= sector_lut(next_index_limited(img_idx, img_found_count));
                    pending_buf_idx  <= disp_buf_idx ^ 2'b01;
                    write_buf_idx    <= disp_buf_idx ^ 2'b01;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                end

                // ===== 请求队列的唯一更新点 =====
                // 停止自动播放优先清掉尚未开始的请求；在途转场仍按原逻辑收尾。
                if (req_queue_clear) begin
                    req_cnt <= 3'd0;
                end else if (mode_change_pulse) begin
                    // 模式切换表示用户开始一次新的交互上下文：丢弃旧模式留下的
                    // 等待请求。若已有转场在途，只保留这一次的计数，待其按锁存
                    // 模式完成；同拍已经完成则直接归零。pfb_valid/load_busy/缓冲
                    // 索引均不清，保证预取数据仍可供新模式下的下一次按键使用。
                    if (fade_pending && !transition_commit_now)
                        req_cnt <= 3'd1;
                    else
                        req_cnt <= 3'd0;
                end else begin
                    case ({req_enqueue, req_commit_now})
                        2'b10: begin
                            if (req_cnt < REQ_QUEUE_MAX)
                                req_cnt <= req_cnt + 3'd1;
                        end
                        2'b01: begin
                            if (req_cnt != 3'd0)
                                req_cnt <= req_cnt - 3'd1;
                        end
                        2'b11: begin
                            // 同拍完成旧请求并收到新请求：一进一出，队列数量不变。
                            req_cnt <= req_cnt;
                        end
                        default: ;
                    endcase
                end
            end
        end
    end
end

// fade_done 跨域同步(video_clk 域脉冲 → sd_card_clk 域,两级同步+边沿检测)
always @(posedge clk or posedge rst) begin
    if (rst) begin
        fade_done_d0 <= 1'b0;
        fade_done_d1 <= 1'b0;
        fade_done_d2 <= 1'b0;
        sw_fade_d0   <= 1'b0;
        sw_fade_d1   <= 1'b0;
        sw2_d0       <= 1'b0;
        sw2_d1       <= 1'b0;
        mode_sync_d  <= 2'b00;
    end else begin
        fade_done_d0 <= fade_done;
        fade_done_d1 <= fade_done_d0;
        fade_done_d2 <= fade_done_d1;
        sw_fade_d0   <= sw_fade;
        sw_fade_d1   <= sw_fade_d0;
        sw2_d0       <= sw2;
        sw2_d1       <= sw2_d0;
        mode_sync_d  <= {sw2_d1, sw_fade_d1};
    end
end
// 用第 2/3 级(已完全同步)做边沿检测,避免第一级亚稳态被当成有效脉冲
assign fade_done_pulse = fade_done_d1 & ~fade_done_d2;
// 00 直接翻显示缓冲;01/10 等 osd_engine、11 等独立控制器的完成信号。
// 顶层必须把原始 sw1、sw2 传入,不能在两个模块之间重编码模式。
assign sw_fade_sync    = sw_fade_d1;
assign sw2_sync        = sw2_d1;
assign mode_sync       = {sw2_sync, sw_fade_sync};
assign mode_change_pulse = (mode_sync != mode_sync_d);
assign trans_mode      = sw_fade_sync | sw2_sync;   // 01/10/11 = 转场,00 = 硬切
assign mode11_sync     = sw2_sync & sw_fade_sync;   // 严格对应 mode_sel={sw2,sw1}=2'b11

// ---------------------------------------------------------------------------
// 切图死锁自愈看门狗（2026-11-03）
//
// 上板现象：按切图键画面不动，数码管读数 req_cnt 累加到上限(4)、pfb_valid 恒 0、
//           load_cnt 停在 2 不再增长。原因是预取分支条件里的 bmp_ready 长期为 0，
//           预取永远发不起 → pfb_valid 回不到 1 → commit 永不成立 → 队列只增不减。
//
// 判据：队列里有请求，但连续 WD_STUCK_SEC 秒没有任何一次提交（req_commit_now）。
//       正常最坏耗时 1.79s（转场 1.18s + 等预取 611ms），取 3s 有余量；
//       只要期间提交过一次，计数器就清零，所以正常连播不会误触发。
//
// 动作：对 bmp_read 与 sd_card_top 发一段 8 拍软复位。sd_card_top 复位后
//       sd_init_done 掉 0，本模块既有的 `!sd_init_done` 分支会自动把
//       req_cnt / pfb_valid / load_busy / scan_done / 各项索引全部清干净，
//       随后重新扫卡 → 效果等同一次上电，但**不改任何子模块内部逻辑**。
//
// 代价：复位期间 display_valid 被清，画面会黑一下，重新扫描＋首图加载后恢复。
//       这是"能从死锁自己爬出来"换来的代价；若复位后又立刻死锁，会 3 秒一循环，
//       此时说明 SD 硬件本身异常（拔卡/接触不良），需要人工处理。
// ---------------------------------------------------------------------------
localparam [31:0] WD_STUCK_CYCLES = 32'd300_000_000;  // 3s @100MHz(sd_card_clk)
localparam [3:0]  WD_RST_CYCLES   = 4'd8;

reg [31:0] wd_cnt;
reg [3:0]  wd_rst_cnt;
wire       wd_fire     = (wd_rst_cnt != 4'd0);
wire       sd_soft_rst = wd_fire;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wd_cnt     <= 32'd0;
        wd_rst_cnt <= 4'd0;
    end else if (wd_fire) begin
        wd_rst_cnt <= wd_rst_cnt - 4'd1;
        wd_cnt     <= 32'd0;
    end else if ((req_cnt == 3'd0) || req_commit_now) begin
        wd_cnt <= 32'd0;                 // 队列空 或 刚提交过 → 重新计时
    end else if (wd_cnt >= WD_STUCK_CYCLES - 32'd1) begin
        wd_cnt     <= 32'd0;
        wd_rst_cnt <= WD_RST_CYCLES;      // 触发一次软复位
    end else begin
        wd_cnt <= wd_cnt + 32'd1;
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst | sd_soft_rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .load_done              (bmp_load_done)
);

// ---------------------------------------------------------------------------
// 切图链路实时诊断视图（纯观测，不驱动任何功能逻辑）
//   放在 bmp_read 之后，所有被观测信号此时都已声明。
//   v2：全部实时、不锁存、不切换显示模式。位定义见 SD/switch_dbg_latch.v 文件头。
// ---------------------------------------------------------------------------
switch_dbg_latch switch_dbg_latch_m0 (
    .clk                    (clk),
    .rst                    (rst),
    .load_start_pulse       (load_start_pulse),
    .pfb_valid              (pfb_valid),
    .fade_pending           (fade_pending),
    .display_valid          (display_valid),
    .load_busy              (load_busy),
    .bmp_ready              (bmp_ready),
    .scan_done              (scan_done),
    .first_image_committed  (first_image_committed),
    .img_found_count        (img_found_count),
    .sd_init_done           (sd_init_done),
    .load_cnt               (dbg_load_cnt),
    .lat_a                  (dbg_lat_a),
    .lat_b                  (dbg_lat_b),
    .lat_c                  (dbg_lat_c),
    .fault                  (dbg_fault),
    .state_seen             (dbg_state_seen)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst | sd_soft_rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

// ---- 诊断输出：纯只读引出，不改变任何内部行为 ----
//   为什么放在这里而不是散在内部：这三个信号都是本模块的寄存器，
//   集中在一处引出，便于日后整体删除，也避免在数据通路里插入观察点。
assign dbg_req_cnt      = req_cnt;         // 排队请求数 0..REQ_QUEUE_MAX
assign dbg_pfb_valid    = pfb_valid;       // 备用缓冲是否就绪（切图的硬门控）
assign dbg_fade_pending = fade_pending;    // 是否有转场在进行

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
