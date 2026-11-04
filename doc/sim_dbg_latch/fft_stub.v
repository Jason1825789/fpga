//============================================================================
// fft_stub.v -- 仅供 spectrum_engine 的 bin→柱 映射仿真使用
//
// 真实 FFT 核 fft_1024_w16_x1.v 是 2451 行行为模型，跑一轮 1024 点要很久，
// 而本次改动只关心「1024 个 dout_en 依次到达时，bin_cnt 被映射到哪根柱」，
// 与 FFT 算得对不对无关。所以用这个 stub 顶替，只保证握手时序：
//   start 脉冲 → busy=1 → 收 1024 个 din_en → 输出 1024 个 dout_en → busy=0
//
// ★ 模块名必须叫 fft（与 RTL 里例化的名字一致），仿真时不要同时编译真 IP。
//============================================================================
module fft (
    input  wire        clk,
    input  wire        rst,
    input  wire        mode,
    input  wire        start,
    input  wire        din_en,
    input  wire [15:0] din_re,
    input  wire [15:0] din_im,
    output reg         done,
    output reg         busy,
    output reg         dout_en,
    output reg  [25:0] dout_re,
    output reg  [25:0] dout_im
);

reg [11:0] in_cnt;
reg [11:0] out_cnt;
reg        started;
reg [3:0]  wait_cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        busy     <= 1'b0;
        done     <= 1'b0;
        dout_en  <= 1'b0;
        dout_re  <= 26'd0;
        dout_im  <= 26'd0;
        in_cnt   <= 12'd0;
        out_cnt  <= 12'd0;
        started  <= 1'b0;
        wait_cnt <= 4'd0;
    end else begin
        dout_en <= 1'b0;
        done    <= 1'b0;

        if (start) begin
            busy     <= 1'b1;
            started  <= 1'b1;
            in_cnt   <= 12'd0;
            out_cnt  <= 12'd0;
            wait_cnt <= 4'd0;
        end else if (busy && started) begin
            if (din_en && in_cnt < 12'd1024)
                in_cnt <= in_cnt + 12'd1;

            if (in_cnt >= 12'd1023) begin
                // 灌数完成，停几拍模拟 FFT 计算延迟
                if (wait_cnt < 4'd8) begin
                    wait_cnt <= wait_cnt + 4'd1;
                end else if (out_cnt < 12'd1024) begin
                    dout_en <= 1'b1;
                    // 给一个随 bin 递增的幅度，让 bars[] 有可区分的值
                    dout_re <= {19'd0, out_cnt[6:0]} * 26'd64;
                    dout_im <= 26'd0;
                    out_cnt <= out_cnt + 12'd1;
                end else begin
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    started <= 1'b0;
                end
            end
        end
    end
end

endmodule
