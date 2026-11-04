//============================================================================
// spectrum_engine.v -- 音频频谱引擎（MVP）
//
// 职责：把 48kHz 单声道 PCM 变成 80 根柱子的像素高度。
//
// 结构：
//   写缓冲(1024x16) → 灌入 TD 的 fft 核 → 收 1024 个频点
//   → 幅度(α·max+β·min) → 对数取 MSB → 柱高 → 区间取最大 → 非对称跟随
//
// 关键设计取舍（都是有原因的，改之前先看）：
//   1) 先缓冲再突发灌数。若把 48kHz 的 audio_valid 直接当 din_en 喂给 IP，
//      IP 要连续 1024 拍，跨 21ms——能跑但依赖 IP 容忍稀疏使能。缓冲后每次
//      灌数是 1 拍 1 个样本的确定性突发，与 IP 时序解耦，也好仿真。
//   2) 不做乒乓。算 FFT 期间丢弃约 23 个样本（窗口不连续），肉眼不可见。
//   3) 幅度用 26bit 全精度 FFT 输出，不是 16bit——这个 IP 不做逐级缩放。
//   4) 柱高在收数据流的过程中边收边聚合，不另存 1024 点幅度，省 RAM/寄存器。
//
// 时钟域：video_clk (25MHz)。audio_valid/audio_l 本来就在这个域，零 CDC。
//============================================================================
module spectrum_engine #(
    parameter integer N_BARS     = 80,      // 柱数
    parameter integer BIN_STRIDE = 6,       // ★ 2026-11-04 起已废弃，只为兼容旧例化保留
    parameter integer DECAY      = 2        // 每帧柱高衰减（像素）
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        audio_valid,         // 48kHz 单拍有效
    input  wire [23:0] audio_l,             // 左声道 24bit PCM（有符号）

    input  wire [6:0]  bar_idx,             // 显示端请求的柱号 0..79
    output wire [7:0]  bar_h,               // 该柱像素高度 0..240
    output wire [4:0]  dbg_state            // 调试：当前状态
);

    // ---------------- 常量 ----------------
    localparam integer FFT_N      = 1024;
    localparam integer BIN_FIRST  = 1;                    // 跳过 DC
    localparam integer BIN_LAST   = 480;   // ★ 与 edge_lut(80) 必须一致（原来是 N_BARS*BIN_STRIDE）
    localparam integer H_MAX      = 240;                  // 最大像素高度
    localparam integer MSB_BASE   = 10;                   // 柱高为 0 的 MSB 位置
    localparam integer MSB_STEP   = 15;                   // 每 1 个 MSB ≈ 6dB ≈ 15 像素

    localparam [4:0] S_FILL  = 5'd0,   // 攒 1024 个样本
                     S_ARM   = 5'd1,   // 等 busy 落下，发 start 脉冲
                     S_LOAD  = 5'd2,   // start 收尾 + 预置读地址
                     S_PRIME = 5'd6,   // 等一拍让单口 RAM 的读数据就位
                     S_DATA  = 5'd3,   // 突发灌 1024 个样本
                     S_CAP   = 5'd4,   // 收 1024 个频点并算柱
                     S_END   = 5'd5;   // 收尾：冲掉最后一根柱

    // =====================================================================
    // bin → 柱 的边界表（半对数分箱，2026-11-04 改）
    //
    // 为什么改：原来是线性分箱（每柱固定 6 个 bin = 281Hz），80 柱铺满
    //   0~22.5kHz。但音乐能量和对数听觉都集中在中低频，线性分箱的后果是
    //   C4~C5 音阶（261~523Hz）只占柱 0~2，右边 70 根柱永远是空的。
    //
    // 改成：前 32 柱线性（每柱 1 个 bin，保住低频分辨率），
    //       后 48 柱对数（每柱约 1.06 倍频宽，约 0.96 半音）。
    //   bin 1 → 柱 0（46.9Hz），bin 480 → 柱 79 末端（22.5kHz）。
    //
    // 改后映射（实测校验过）：
    //   C3 131Hz→柱1  C4 262Hz→柱4  E4 330Hz→柱6  C5 523Hz→柱10
    //   C4x3 785Hz→柱15  C4x5 1308Hz→柱26  C5x3 1570Hz→柱32
    //   C4x7 1831Hz→柱35  C5x5 2616Hz→柱41  C4x15 3924Hz→柱48
    //   同一个音阶循环能铺开柱 1~48，而不是原来的柱 0~2。
    //
    // ★ 表的单调性由 Python 生成时断言过（严格递增、每柱至少 1 个 bin）。
    //   若要改柱数或频段范围，必须重新生成并重新验证单调性，否则
    //   a_first 会漏判，某些柱永远不提交（表现：柱子卡住不动）。
    // =====================================================================
    function [9:0] edge_lut;
        input [6:0] k;              // 0..80（80 是最后一柱的右边界）
        begin
            case (k)
                7'd0 : edge_lut = 10'd1;   7'd1 : edge_lut = 10'd2;
                7'd2 : edge_lut = 10'd3;   7'd3 : edge_lut = 10'd4;
                7'd4 : edge_lut = 10'd5;   7'd5 : edge_lut = 10'd6;
                7'd6 : edge_lut = 10'd7;   7'd7 : edge_lut = 10'd8;
                7'd8 : edge_lut = 10'd9;   7'd9 : edge_lut = 10'd10;
                7'd10: edge_lut = 10'd11;  7'd11: edge_lut = 10'd12;
                7'd12: edge_lut = 10'd13;  7'd13: edge_lut = 10'd14;
                7'd14: edge_lut = 10'd15;  7'd15: edge_lut = 10'd16;
                7'd16: edge_lut = 10'd17;  7'd17: edge_lut = 10'd18;
                7'd18: edge_lut = 10'd19;  7'd19: edge_lut = 10'd20;
                7'd20: edge_lut = 10'd21;  7'd21: edge_lut = 10'd22;
                7'd22: edge_lut = 10'd23;  7'd23: edge_lut = 10'd24;
                7'd24: edge_lut = 10'd25;  7'd25: edge_lut = 10'd26;
                7'd26: edge_lut = 10'd27;  7'd27: edge_lut = 10'd28;
                7'd28: edge_lut = 10'd29;  7'd29: edge_lut = 10'd30;
                7'd30: edge_lut = 10'd31;  7'd31: edge_lut = 10'd32;
                7'd32: edge_lut = 10'd33;  7'd33: edge_lut = 10'd35;
                7'd34: edge_lut = 10'd37;  7'd35: edge_lut = 10'd39;
                7'd36: edge_lut = 10'd41;  7'd37: edge_lut = 10'd44;
                7'd38: edge_lut = 10'd46;  7'd39: edge_lut = 10'd49;
                7'd40: edge_lut = 10'd52;  7'd41: edge_lut = 10'd55;
                7'd42: edge_lut = 10'd58;  7'd43: edge_lut = 10'd61;
                7'd44: edge_lut = 10'd64;  7'd45: edge_lut = 10'd68;
                7'd46: edge_lut = 10'd72;  7'd47: edge_lut = 10'd76;
                7'd48: edge_lut = 10'd81;  7'd49: edge_lut = 10'd85;
                7'd50: edge_lut = 10'd90;  7'd51: edge_lut = 10'd95;
                7'd52: edge_lut = 10'd101; 7'd53: edge_lut = 10'd106;
                7'd54: edge_lut = 10'd113; 7'd55: edge_lut = 10'd119;
                7'd56: edge_lut = 10'd126; 7'd57: edge_lut = 10'd133;
                7'd58: edge_lut = 10'd141; 7'd59: edge_lut = 10'd149;
                7'd60: edge_lut = 10'd157; 7'd61: edge_lut = 10'd166;
                7'd62: edge_lut = 10'd176; 7'd63: edge_lut = 10'd186;
                7'd64: edge_lut = 10'd197; 7'd65: edge_lut = 10'd208;
                7'd66: edge_lut = 10'd220; 7'd67: edge_lut = 10'd232;
                7'd68: edge_lut = 10'd246; 7'd69: edge_lut = 10'd260;
                7'd70: edge_lut = 10'd275; 7'd71: edge_lut = 10'd291;
                7'd72: edge_lut = 10'd307; 7'd73: edge_lut = 10'd325;
                7'd74: edge_lut = 10'd343; 7'd75: edge_lut = 10'd363;
                7'd76: edge_lut = 10'd384; 7'd77: edge_lut = 10'd406;
                7'd78: edge_lut = 10'd429; 7'd79: edge_lut = 10'd454;
                default: edge_lut = 10'd480;    // k=80，最后一柱右边界
            endcase
        end
    endfunction

    // ---------------- 样本写缓冲 1024x16 ----------------
    // 单口 RAM：写优先，否则读（读延迟 1 拍）。TD 会推成 2 个 BRAM9K。
    reg  [15:0] sbuf [0:FFT_N-1];
    reg  [9:0]  wr_addr;
    reg  [9:0]  rd_addr;
    reg         sbuf_we;
    reg  [15:0] sbuf_wd;
    reg  [15:0] sbuf_q;

    always @(posedge clk) begin
        if (sbuf_we)
            sbuf[wr_addr] <= sbuf_wd;
        else
            sbuf_q <= sbuf[rd_addr];
    end

    // ---------------- FFT 核接口 ----------------
    reg         fft_start;
    reg         fft_din_en;
    reg  [15:0] fft_din_re;
    wire        fft_busy;
    wire        fft_done;
    wire        fft_dout_en;
    wire [25:0] fft_dout_re;
    wire [25:0] fft_dout_im;

    fft u_fft (
        .clk     (clk),
        .rst     (rst),
        .mode    (1'b0),
        .start   (fft_start),
        .din_en  (fft_din_en),
        .din_re  (fft_din_re),
        .din_im  (16'd0),            // 实数输入
        .done    (fft_done),
        .busy    (fft_busy),
        .dout_en (fft_dout_en),
        .dout_re (fft_dout_re),
        .dout_im (fft_dout_im)
    );

    // ---------------- 主状态机 ----------------
    reg  [4:0]  state;
    reg  [9:0]  fill_cnt;        // 已攒样本数
    reg  [9:0]  load_cnt;        // 已灌样本数
    reg  [9:0]  bin_cnt;         // 已收频点数
    reg  [19:0] cap_wdog;        // 收数据看门狗

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= S_FILL;
            fill_cnt     <= 10'd0;
            load_cnt     <= 10'd0;
            bin_cnt      <= 10'd0;
            cap_wdog     <= 20'd0;
            wr_addr      <= 10'd0;
            rd_addr      <= 10'd0;
            sbuf_we      <= 1'b0;
            sbuf_wd      <= 16'd0;
            fft_start    <= 1'b0;
            fft_din_en   <= 1'b0;
            fft_din_re   <= 16'd0;
        end else begin
            // 默认不写
            sbuf_we    <= 1'b0;
            fft_start  <= 1'b0;

            case (state)

            // ---- 攒样本：audio_valid 单拍写一个 24→16 位样本 ----
            S_FILL: begin
                fft_din_en <= 1'b0;
                if (audio_valid) begin
                    sbuf_we   <= 1'b1;
                    sbuf_wd   <= audio_l[23:8];   // 24bit 取高 16bit（有符号右移8）
                    wr_addr   <= wr_addr + 10'd1;
                    if (fill_cnt == FFT_N - 1) begin
                        fill_cnt <= 10'd0;
                        wr_addr  <= 10'd0;        // 下一帧从头写
                        state    <= S_ARM;
                    end else begin
                        fill_cnt <= fill_cnt + 10'd1;
                    end
                end
            end

            // ---- 等 FFT 核空闲，再发 start（busy 期间发会被忽略）----
            S_ARM: begin
                if (!fft_busy) begin
                    fft_start <= 1'b1;
                    state     <= S_LOAD;
                end
            end

            // ---- start 保持这一拍，同时预置读地址 ----
            S_LOAD: begin
                fft_start <= 1'b0;
                rd_addr   <= 10'd0;
                load_cnt  <= 10'd0;
                state     <= S_PRIME;
            end

            // ---- 单口 RAM 的读数据要晚一拍才出来，这里必须等一拍 ----
            // 少了这一拍，灌进去的第一个样本会是上一帧的残留值（首帧是 0），
            // 且最后一个样本发不出去——窗口里多一个"缺口样本"会造成全频段
            // 泄漏，表现就是所有柱子都抬到一个固定地板高度。
            S_PRIME: begin
                rd_addr <= 10'd1;
                state   <= S_DATA;
            end

            // ---- 突发灌数：每拍 1 个样本 ----
            // 经 S_PRIME 那一拍之后，本状态的第一拍 sbuf_q 正好是 sbuf[0]，
            // 所以 din_re<=sbuf_q 与 din_en<=1 天然对齐，1024 个样本不多不少。
            S_DATA: begin
                fft_din_en <= 1'b1;
                fft_din_re <= sbuf_q;
                rd_addr    <= rd_addr + 10'd1;
                if (load_cnt == FFT_N - 1) begin
                    load_cnt <= 10'd0;
                    bin_cnt  <= 10'd0;
                    cap_wdog <= 20'd0;
                    state    <= S_CAP;
                end else begin
                    load_cnt <= load_cnt + 10'd1;
                end
            end

            // ---- 收频点 ----
            S_CAP: begin
                fft_din_en <= 1'b0;
                cap_wdog   <= cap_wdog + 20'd1;
                if (fft_dout_en) begin
                    bin_cnt <= bin_cnt + 10'd1;
                    if (bin_cnt == FFT_N - 1)
                        state <= S_END;
                end
                // 看门狗：约 1M 拍（40ms @25MHz）没结果就放弃本帧，
                // 避免 FFT 异常时状态机永久卡死。
                if (cap_wdog == 20'hFFFFF)
                    state <= S_FILL;
            end

            // ---- 收尾冲最后一根柱 ----
            S_END: begin
                fill_cnt <= 10'd0;
                wr_addr  <= 10'd0;
                state    <= S_FILL;
            end

            default: state <= S_FILL;
            endcase
        end
    end

    // ---------------- 柱高三级流水 ----------------
    // A 级：锁存 FFT 输出 + 该 bin 属于哪根柱
    reg         a_vld;
    reg  [25:0] a_re, a_im;
    reg  [6:0]  a_bar;
    reg         a_first;

    // B 级：幅度
    reg         b_vld;
    reg  [26:0] b_mag;
    reg  [6:0]  b_bar;
    reg         b_first;

    // C 级：对数 → 像素高度
    reg         c_vld;
    reg  [7:0]  c_h;
    reg  [6:0]  c_bar;
    reg         c_first;

    // bin → 柱 的映射（半对数边界表，见上面 edge_lut；sub_cnt 已废弃删除）
    reg  [6:0]  bar_gen;
    // ★ 左闭右开：处理 bin BIN_FIRST..BIN_LAST-1，与 edge_lut 的定义严格一致
    //   （edge[80]=480 是"右边界不含"，若写成 <=BIN_LAST，最后一柱会多收 bin 480）
    wire        bin_in_range = (bin_cnt >= BIN_FIRST) && (bin_cnt < BIN_LAST);

    // 当前 bin 是否正好是「本柱的第一个」/「本柱的最后一个」
    //   is_bar_first：聚合器靠它把上一根柱冲进 bars[]，每根柱必须有且仅有一拍为 1
    //   is_bar_last ：靠它把 bar_gen 推进到下一根柱
    wire [9:0]  edge_cur     = edge_lut(bar_gen);
    wire [9:0]  edge_next    = edge_lut(bar_gen + 7'd1);
    wire        is_bar_first = (bin_cnt == edge_cur);
    wire        is_bar_last  = ((bin_cnt + 10'd1) >= edge_next);

    // ---- A 级 ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_vld   <= 1'b0;
            a_re    <= 26'd0;
            a_im    <= 26'd0;
            a_bar   <= 7'd0;
            a_first <= 1'b0;
            bar_gen <= 7'd0;
        end else if (state == S_LOAD) begin
            // 每次灌数前复位柱计数
            bar_gen <= 7'd0;
            a_vld   <= 1'b0;
        end else if ((state == S_CAP) && fft_dout_en) begin
            if (bin_in_range) begin
                a_vld   <= 1'b1;
                a_re    <= fft_dout_re;
                a_im    <= fft_dout_im;
                a_bar   <= bar_gen;
                a_first <= is_bar_first;
                // 收完本柱最后一个 bin 就换到下一根；最后一柱原地不动，由 flush_last 收尾
                if ((bar_gen < N_BARS - 1) && is_bar_last)
                    bar_gen <= bar_gen + 7'd1;
            end else begin
                a_vld <= 1'b0;
            end
        end else begin
            a_vld <= 1'b0;
        end
    end

    // ---- B 级：幅度 = max + min/4 + min/8（α=1, β=0.375，误差 <6%，免开方）----
    wire [25:0] a_re_abs = a_re[25] ? (~a_re + 26'd1) : a_re;
    wire [25:0] a_im_abs = a_im[25] ? (~a_im + 26'd1) : a_im;
    wire [25:0] a_max    = (a_re_abs > a_im_abs) ? a_re_abs : a_im_abs;
    wire [25:0] a_min    = (a_re_abs > a_im_abs) ? a_im_abs : a_re_abs;
    wire [26:0] b_mag_c  = {1'b0, a_max} + {1'b0, (a_min >> 2)} + {1'b0, (a_min >> 3)};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            b_vld   <= 1'b0;
            b_mag   <= 27'd0;
            b_bar   <= 7'd0;
            b_first <= 1'b0;
        end else begin
            b_vld   <= a_vld;
            b_mag   <= b_mag_c;
            b_bar   <= a_bar;
            b_first <= a_first;
        end
    end

    // ---- C 级：对数压缩 → 像素高度 ----
    // 取最高有效位做"每 bit = 6dB"的近似对数，再用 MSB 下方 3 位做内插，
    // 避免柱子只按 15 像素一档跳。
    function [4:0] msb_of;
        input [26:0] v;
        integer i;
        begin
            msb_of = 5'd0;
            for (i = 0; i < 27; i = i + 1)
                if (v[i]) msb_of = i[4:0];
        end
    endfunction

    wire [4:0]  c_msb   = msb_of(b_mag);
    wire [4:0]  c_sh    = 5'd26 - c_msb;          // 把 MSB 归一到 bit26
    wire [26:0] c_norm  = b_mag << c_sh;
    wire [2:0]  c_mant  = c_norm[25:23];          // MSB 下方 3 位
    wire [4:0]  c_exp   = c_msb - MSB_BASE;       // 可能下溢，下面判断
    wire [8:0]  c_base  = ({4'd0, c_exp} << 4) - {4'd0, c_exp};   // ×15
    wire [8:0]  c_sum   = c_base + {5'd0, c_mant, 1'b0};          // + mant×2
    wire [7:0]  c_h_c = (c_msb <= MSB_BASE) ? 8'd0 :
                          ((c_sum > H_MAX) ? 8'd240 : c_sum[7:0]);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            c_vld   <= 1'b0;
            c_h     <= 8'd0;
            c_bar   <= 7'd0;
            c_first <= 1'b0;
        end else begin
            c_vld   <= b_vld;
            c_h     <= c_h_c;
            c_bar   <= b_bar;
            c_first <= b_first;
        end
    end

    // ---------------- 区间聚合 + 非对称跟随 ----------------
    // 每根柱覆盖的 bin 由 edge_lut 决定（低频 1 个、高频最多 26 个），取其中最大者；
    // 柱与柱之间切换时把上一根冲进 bars[]。上升立即跟随，下降每帧只减 DECAY——
    // 没有这一条，柱子会每 21ms 剧烈闪，看不出是真在动还是逻辑在抖。
    reg         agg_vld;
    reg  [6:0]  agg_bar;
    reg  [7:0]  agg_max;

    // 注意：bars 必须先声明，后面 bar_old 才能引用它（Verilog 要求先声明后使用）
    reg  [7:0]  bars [0:N_BARS-1];
    integer     bi;

    wire [7:0]  bar_old = bars[agg_bar];
    wire [7:0]  bar_dec = (bar_old > DECAY) ? (bar_old - DECAY) : 8'd0;
    wire [7:0]  bar_new = (agg_max > bar_dec) ? agg_max : bar_dec;
    wire        flush_last = (state == S_END);


    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (bi = 0; bi < N_BARS; bi = bi + 1)
                bars[bi] <= 8'd0;
        end else if (c_vld && c_first && agg_vld) begin
            bars[agg_bar] <= bar_new;
        end else if (flush_last && agg_vld) begin
            bars[agg_bar] <= bar_new;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            agg_vld <= 1'b0;
            agg_bar <= 7'd0;
            agg_max <= 8'd0;
        end else if (state == S_LOAD) begin
            agg_vld <= 1'b0;
            agg_bar <= 7'd0;
            agg_max <= 8'd0;
        end else if (c_vld) begin
            if (c_first) begin
                agg_vld <= 1'b1;
                agg_bar <= c_bar;
                agg_max <= c_h;
            end else if (c_h > agg_max) begin
                agg_max <= c_h;
            end
        end
    end

    // ---------------- 输出 ----------------
    // 先把下标夹到合法范围再索引：越界读 bars[] 在仿真里出 X、在综合里出垃圾。
    wire [6:0] bar_idx_s = (bar_idx < N_BARS) ? bar_idx : 7'd0;
    assign bar_h     = (bar_idx < N_BARS) ? bars[bar_idx_s] : 8'd0;
    assign dbg_state = state;

endmodule
