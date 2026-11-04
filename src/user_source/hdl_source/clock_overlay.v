//====================================================
// clock_overlay.v -- 右上角时间戳图层（扩展要求 01：动态文字/时间戳）
//
// 本模块由 gen_clock_overlay.py 生成，勿手改！改字形请改脚本里的 GLYPH。
//
// 【为什么独立成模块】
// osd_engine.v 已有三层（红条 / 滚动字幕 / 左上状态条）和两个转场状态机，
// 直接往里加图层容易碰到现有分支。这里做成纯"命中判断"的旁挂模块，
// 由 osd_engine 在输出级插入一级 mux，对现有逻辑只增加一行 assign。
//
// 【内容】
//   右上角一块与左上状态条同风格的深色框，内部显示 HH:MM:SS。
//   时基 = video_clk(25MHz) / CLK_HZ，首图出现(dv_ok 首次为 1)时从 00:00:00 开始走。
//
// 【布局】640x480 画面
//   框体 (X0,Y0)-(X1,Y1) = (0,24)-(152,48)：紧贴左上状态条(0,0)-(152,24)正下方，
//        同宽、同底色，视觉上合成一整块"状态 + 时间"面板
//   文字 8 字符 x 16px = 128px，起点 x=12，左右各留 12px，上下各留 4px
//====================================================
module clock_overlay #(
    parameter [15:0] X0 = 16'd0,
    parameter [15:0] Y0 = 16'd24,
    parameter [15:0] X1 = 16'd152,
    parameter [15:0] Y1 = 16'd48,
    parameter integer CLK_HZ = 25_000_000        // video_clk 频率
)(
    input  wire        clk,        // video_clk
    input  wire        rst,
    input  wire        dv_ok,      // 首图就绪：未就绪时整块不显示（防上电抢跑）
    input  wire [15:0] pixel_x,
    input  wire [15:0] pixel_y,
    output wire        hit,        // 本像素落在时间戳区域
    output wire [23:0] pixel       // 该区域的颜色
);

//--------------------------------------------------------------------
// 1Hz 时基
// 25,000,000 = 25 位可表示（2^25 = 33,554,432），计数器不溢出
//--------------------------------------------------------------------
localparam [24:0] DIV_LAST = 25'd24_999_999;

reg [24:0] hz_cnt;
reg        sec_tick;
reg        time_started;

// 首图上屏前保持 00:00:00：dv_ok 第一次为 1 才允许计时，之后连续走，
// 不会因后续 dv_ok 抖动而暂停或清零。这样时间基准就是"画面出现那一刻"。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hz_cnt       <= 25'd0;
        sec_tick     <= 1'b0;
        time_started <= 1'b0;
    end else if (!time_started) begin
        hz_cnt   <= 25'd0;
        sec_tick <= 1'b0;
        if (dv_ok)
            time_started <= 1'b1;
    end else if (hz_cnt >= DIV_LAST) begin
        hz_cnt   <= 25'd0;
        sec_tick <= 1'b1;
    end else begin
        hz_cnt   <= hz_cnt + 25'd1;
        sec_tick <= 1'b0;
    end
end

//--------------------------------------------------------------------
// BCD 计时：时 分 秒，各用十位/个位两个 4 位寄存器
// 每个计数器独立判断自己该不该进位，避免六层嵌套 if 拖长组合路径
//--------------------------------------------------------------------
reg [3:0] sec_l, sec_h;
reg [3:0] min_l, min_h;
reg [3:0] hr_l,  hr_h;

wire sec_carry = (sec_l == 4'd9) && (sec_h == 4'd5);
wire min_carry = (min_l == 4'd9) && (min_h == 4'd5);
wire hr_carry  = (hr_h == 4'd2) && (hr_l == 4'd3);   // 23:59:59 -> 00:00:00

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sec_l <= 4'd0; sec_h <= 4'd0;
        min_l <= 4'd0; min_h <= 4'd0;
        hr_l  <= 4'd0; hr_h  <= 4'd0;
    end else if (sec_tick) begin
        // 秒个位
        if (sec_l == 4'd9) sec_l <= 4'd0;
        else               sec_l <= sec_l + 4'd1;

        // 秒十位
        if (sec_l == 4'd9) begin
            if (sec_h == 4'd5) sec_h <= 4'd0;
            else               sec_h <= sec_h + 4'd1;
        end

        // 分个位
        if (sec_carry) begin
            if (min_l == 4'd9) min_l <= 4'd0;
            else               min_l <= min_l + 4'd1;
        end

        // 分十位
        if (sec_carry && (min_l == 4'd9)) begin
            if (min_h == 4'd5) min_h <= 4'd0;
            else               min_h <= min_h + 4'd1;
        end

        // 时（十位/个位一起处理 23 -> 00）
        if (sec_carry && min_carry) begin
            if (hr_carry) begin
                hr_h <= 4'd0;
                hr_l <= 4'd0;
            end else if (hr_l == 4'd9) begin
                hr_l <= 4'd0;
                hr_h <= hr_h + 4'd1;
            end else begin
                hr_l <= hr_l + 4'd1;
            end
        end
    end
end

//--------------------------------------------------------------------
// 区域命中 + 字符定位
//--------------------------------------------------------------------
wire clock_zone = dv_ok &&
                  (pixel_x >= X0) && (pixel_x < X1) &&
                  (pixel_y >= Y0) && (pixel_y < Y1);

localparam [15:0] TX = 16'd12;      // 文字左边缘（框宽152，文字128，左右各留12）
localparam [15:0] TY = 16'd28;      // 文字上边缘（框 y24~48，字高16，上下各留4）

wire in_text = (pixel_x >= TX) && (pixel_x < TX + 16'd128) &&
               (pixel_y >= TY) && (pixel_y < TY + 16'd16);

wire [15:0] tdx = pixel_x - TX;
wire [15:0] tdy = pixel_y - TY;
wire [2:0]  char_pos = tdx[6:4];     // 每 16px 一个字符，0~7

// HH : MM : SS  ->  8 个字符位
reg [3:0] glyph_sel;
always @(*) begin
    case (char_pos)
        3'd0:    glyph_sel = hr_h;
        3'd1:    glyph_sel = hr_l;
        3'd2:    glyph_sel = 4'd10;      // 冒号
        3'd3:    glyph_sel = min_h;
        3'd4:    glyph_sel = min_l;
        3'd5:    glyph_sel = 4'd10;      // 冒号
        3'd6:    glyph_sel = sec_h;
        default: glyph_sel = sec_l;
    endcase
end

//--------------------------------------------------------------------
// 字模查询（与 mode_status_font_rom 同一套索引方式）
//--------------------------------------------------------------------
localparam [4095:0] CLOCK_FONT_ALL = 4096'h0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018001800000000001800180000000000000000000000000000003c006600c300c300c30066003e0003000300030066003c0000000000000000003c006600c300c30066003c006600c300c300c30066003c000000000000000000fe00c600060006000c000c0018001800300030006000600000000000000000003c006600c000c000c000fc00c600c300c300c30066003c000000000000000000fe00c000c000c000fc00c600030003000300c30066003c00000000000000000006000e001e0036006600c600c600fe00060006000600060000000000000000003c006600c300030003001e00030003000300c30066003c0000000000000000003c006600c300030006000c00180030006000c000c3007e000000000000000000180038007800180018001800180018001800180018007e0000000000000000003c006600c300c300c300c300c300c300c300c30066003c000000000;

wire [255:0] glyph_bits = CLOCK_FONT_ALL[{glyph_sel, 8'b0} +: 256];
// 字形在生成时 row0 存在最高 16 位，而 +: 是从低位向上取，
// 直接用 {tdy,4'b0} 会把行序整个颠倒(实测上板表现为上下镜像)。
// 这里先把行号反序，+0 仍是低位切片，取到的才是真正的 row0。
wire [3:0]  row_idx    = 4'd15 - tdy[3:0];
wire [15:0] glyph_row  = glyph_bits[{row_idx, 4'b0} +: 16];
wire        font_on    = glyph_row[15 - tdx[3:0]];

//--------------------------------------------------------------------
// 配色：与左上状态条保持一致（底色 #F0F0F0 与图片椭圆外同色，文字纯黑）
//--------------------------------------------------------------------
localparam [23:0] CLOCK_BG_COLOR   = 24'hF0F0F0;
localparam [23:0] CLOCK_TEXT_COLOR = 24'h000000;

assign hit   = clock_zone;
assign pixel = (in_text && font_on) ? CLOCK_TEXT_COLOR : CLOCK_BG_COLOR;

endmodule
