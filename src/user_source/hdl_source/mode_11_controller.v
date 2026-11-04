//====================================================
// mode_11_controller.v -- 模式 11 单读通道上下幕布控制器
//
// 数据面只使用主显示通道 old_pixel:
//   1. 上、下黑幕从画面边缘向中心合拢；
//   2. 全黑后发出一次 transition_done，请求上游翻转显示缓冲；
//   3. 全黑保持若干帧，覆盖缓冲索引跨域、下一帧请求和 FIFO 重填；
//   4. 黑幕从中心向上、下打开，露出主通道中的新图。
//
// 为保持顶层接口兼容，第二读通道端口仍保留，但两个使能恒为 0。
// 本模块不访问 SDRAM/FIFO，也不改变模式 00/01/10 的公共数据路径。
//====================================================
module mode_11_controller #(
    parameter [19:0] MODE_STABLE_CYCLES  = 20'd400000, // 16ms @25MHz
    parameter [9:0]  FRAME_HEIGHT        = 10'd480,
    parameter [9:0]  CURTAIN_STEP        = 10'd8,      // 每侧每帧推进 8 行
    parameter [2:0]  SWITCH_GUARD_FRAMES = 3'd4,       // 与模式10相同的全黑保护帧
    parameter [23:0] CURTAIN_COLOR       = 24'h000000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        vs,                    // 负极性场同步,下降沿为新帧
    input  wire [1:0]  mode_sel,              // 必须保持 {sw2,sw1}
    input  wire        transition_req,        // 保持型请求,仅 mode11 请求送入
    input  wire        pixel_pair_ready,      // 兼容旧接口,单读模式不使用
    input  wire [15:0] pixel_y,                // 与 old_pixel 对齐的当前行坐标
    input  wire [23:0] old_pixel,              // ch1:当前主显示通道
    input  wire [23:0] new_pixel,              // 兼容旧接口,单读模式不使用

    output wire        read2_prefetch_en,      // 单读模式恒为 0
    output wire        read2_consume_en,       // 单读模式恒为 0
    output wire        mode11_selected,        // 消抖后的 mode_sel == 2'b11
    output wire        active,
    output wire        cover_black,            // 当前像素是否被上下幕布盖住(逐像素,供 OSD 顶层掩蔽)
    output reg         transition_done,        // 1 个 video_clk 周期完成脉冲
    output wire [1:0]  state_dbg,
    output reg  [23:0] mixed_pixel
);

localparam [1:0] ST_IDLE = 2'd0;
localparam [1:0] ST_ARM  = 2'd1;
localparam [1:0] ST_RUN  = 2'd2;
localparam [1:0] ST_HOLD = 2'd3;
localparam [9:0] HALF_HEIGHT = FRAME_HEIGHT >> 1;

// 模式开关跨域同步并整组消抖。两位一起确认,避免拨动时经过错误中间模式。
reg [1:0]  mode_d0;
reg [1:0]  mode_d1;
reg [1:0]  mode_stable;
reg [19:0] mode_stable_cnt;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mode_d0         <= 2'b00;
        mode_d1         <= 2'b00;
        mode_stable     <= 2'b00;
        mode_stable_cnt <= 20'd0;
    end else begin
        mode_d0 <= mode_sel;
        mode_d1 <= mode_d0;
        if (mode_d1 != mode_stable) begin
            if (mode_stable_cnt >= (MODE_STABLE_CYCLES - 20'd1)) begin
                mode_stable     <= mode_d1;
                mode_stable_cnt <= 20'd0;
            end else begin
                mode_stable_cnt <= mode_stable_cnt + 20'd1;
            end
        end else begin
            mode_stable_cnt <= 20'd0;
        end
    end
end
assign mode11_selected = (mode_stable == 2'b11);

// sd_card_clk -> video_clk:保持型请求用两级同步，不依赖窄脉冲采样。
reg req_d0;
reg req_d1;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        req_d0 <= 1'b0;
        req_d1 <= 1'b0;
    end else begin
        req_d0 <= transition_req;
        req_d1 <= req_d0;
    end
end

// 幕布边界和状态只在场同步下降沿改变，一整帧内保持不变。
reg vs_d;
wire vs_fall;
always @(posedge clk or posedge rst) begin
    if (rst)
        vs_d <= 1'b0;
    else
        vs_d <= vs;
end
assign vs_fall = vs_d & ~vs;

reg [1:0] state;
reg [9:0] curtain_extent;         // 每侧黑幕深度:0..FRAME_HEIGHT/2
reg [2:0] guard_frame_cnt;
reg       opening;
reg       request_claimed;

wire start_req = req_d1 && !request_claimed
               && mode11_selected && (state == ST_IDLE);
wire [10:0] close_next = {1'b0, curtain_extent} + {1'b0, CURTAIN_STEP};
wire [15:0] lower_curtain_start =
                 {6'd0, FRAME_HEIGHT} - {6'd0, curtain_extent};
wire curtain_pixel = ((state == ST_RUN) || (state == ST_HOLD))
                   && ((curtain_extent >= HALF_HEIGHT)
                    || (pixel_y < curtain_extent)
                    || (pixel_y >= lower_curtain_start));

assign state_dbg         = state;
assign active            = (state != ST_IDLE);
// 幕布的逐像素覆盖判据本来就是给 mixed_pixel 用的，这里原样引出给 osd_engine：
// 让左上状态条、时间戳、底部灰条、滚动字幕在合幕时被一起盖住，而不是浮在黑幕之上。
assign cover_black       = curtain_pixel;
assign read2_prefetch_en = 1'b0;
assign read2_consume_en  = 1'b0;

// 一个保持型请求只认领一次。只在 IDLE 认领，避免 HOLD 期间提前吞掉
// 后续快速按键产生的新请求；上游撤销当前请求后即可等待下一次。
always @(posedge clk or posedge rst) begin
    if (rst)
        request_claimed <= 1'b0;
    else if (!req_d1)
        request_claimed <= 1'b0;
    else if (start_req)
        request_claimed <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state            <= ST_IDLE;
        curtain_extent   <= 10'd0;
        guard_frame_cnt  <= 3'd0;
        opening          <= 1'b0;
        transition_done  <= 1'b0;
    end else begin
        transition_done <= 1'b0;
        case (state)
            ST_IDLE: begin
                curtain_extent  <= 10'd0;
                guard_frame_cnt <= 3'd0;
                opening         <= 1'b0;
                if (start_req)
                    state <= ST_ARM;
            end

            ST_ARM: begin
                // 从完整帧边界开始合幕，避免一帧内改变遮罩边界。
                if (vs_fall) begin
                    state          <= ST_RUN;
                    curtain_extent <= 10'd0;
                end
            end

            ST_RUN: begin
                if (vs_fall) begin
                    if (close_next >= {1'b0, HALF_HEIGHT}) begin
                        // 从这一帧起整屏全黑，安全提交一次显示缓冲翻转。
                        curtain_extent  <= HALF_HEIGHT;
                        guard_frame_cnt <= 3'd0;
                        opening         <= 1'b0;
                        transition_done <= 1'b1;
                        state           <= ST_HOLD;
                    end else begin
                        curtain_extent <= close_next[9:0];
                    end
                end
            end

            ST_HOLD: begin
                if (vs_fall) begin
                    if (!opening) begin
                        // F1..F4 保持全黑；下一帧才开始打开。
                        if (guard_frame_cnt < SWITCH_GUARD_FRAMES) begin
                            guard_frame_cnt <= guard_frame_cnt + 3'd1;
                        end else begin
                            opening <= 1'b1;
                            if (curtain_extent <= CURTAIN_STEP) begin
                                curtain_extent <= 10'd0;
                                state          <= ST_IDLE;
                            end else begin
                                curtain_extent <= curtain_extent - CURTAIN_STEP;
                            end
                        end
                    end else if (curtain_extent <= CURTAIN_STEP) begin
                        curtain_extent <= 10'd0;
                        opening        <= 1'b0;
                        state          <= ST_IDLE;
                    end else begin
                        curtain_extent <= curtain_extent - CURTAIN_STEP;
                    end
                end
            end

            default: begin
                state            <= ST_IDLE;
                curtain_extent   <= 10'd0;
                guard_frame_cnt  <= 3'd0;
                opening          <= 1'b0;
            end
        endcase
    end
end

always @(*) begin
    if (curtain_pixel)
        mixed_pixel = CURTAIN_COLOR;
    else
        mixed_pixel = old_pixel;
end

endmodule
