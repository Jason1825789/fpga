//============================================================================
// tb_spec_logbin.v -- 验证 spectrum_engine 改成半对数分箱后的 bin→柱 映射
//
// 起因：原线性分箱（每柱 6 bin = 281Hz）让 C4~C5 音阶只占柱 0~2，
//       右边 70 根永远空。改成半对数（前 32 柱每柱 1 bin，后 48 柱对数）后
//       必须逐 bin 验证 80 个边界都正确，否则会出现「某些柱永不提交」
//       ——表现就是柱子卡住不动，而上板后很难定位。
//
// 用 stub 替换真实 FFT 核（fft_1024_w16_x1 是 2451 行行为模型，跑一轮很慢），
// stub 只保证「1024 个 din_en 进、1024 个 dout_en 出」的握手时序。
//
// 检查项：
//   V1 每个 bin 落在期望的柱（逐 bin 对照 81 个边界）
//   V2 80 根柱全都被访问过（没有柱被跳过）
//   V3 每根柱的 first 标记恰好出现一次（聚合器依赖它提交）
//   V4 一轮结束后 bars[] 至少有一半柱子非零（说明提交链通了）
//============================================================================
`timescale 1ns/1ps

module tb_spec_logbin;

reg         clk;
reg         rst;
reg         audio_valid;
reg  [23:0] audio_l;
reg  [6:0]  bar_idx;
wire [7:0]  bar_h;
wire [4:0]  dbg_state;

integer errors;
integer i, k, round;

// ---------------- 期望的边界表（与 spectrum_engine.edge_lut 逐项一致）-------
integer EDGE [0:80];

// 统计
integer visit_cnt  [0:79];   // 每柱收到的 bin 数
integer first_cnt  [0:79];   // 每柱 first 标记次数

// bin → 期望柱号
function integer bar_of;
    input integer b;
    integer n;
    begin
        bar_of = 0;
        for (n = 0; n < 80; n = n + 1)
            if (b >= EDGE[n]) bar_of = n;
    end
endfunction

// ---------------- DUT ----------------
spectrum_engine u_dut (
    .clk        (clk),
    .rst        (rst),
    .audio_valid(audio_valid),
    .audio_l    (audio_l),
    .bar_idx    (bar_idx),
    .bar_h      (bar_h),
    .dbg_state  (dbg_state)
);

always #20 clk = ~clk;   // 25MHz

// ---------------- 逐拍检查 ----------------
reg        cap_phase;
integer    chk_bin;
integer    last_state;

initial begin
    cap_phase = 0;
    chk_bin   = 0;
end

always @(posedge clk) begin
    if (!rst) begin
        // S_CAP = 5'd4；在 fft_dout_en 那一拍检查当前 bin 的归属
        if ((dbg_state == 5'd4) && u_dut.fft_dout_en) begin
            if (u_dut.bin_cnt >= 1 && u_dut.bin_cnt < 480) begin
                if (u_dut.bar_gen !== bar_of(u_dut.bin_cnt)) begin
                    $display("FAIL V1 bin=%0d bar_gen=%0d want=%0d",
                             u_dut.bin_cnt, u_dut.bar_gen, bar_of(u_dut.bin_cnt));
                    errors = errors + 1;
                end
                visit_cnt[u_dut.bar_gen] = visit_cnt[u_dut.bar_gen] + 1;
            end
        end
    end
end

// 统计 first 标记（a_vld && a_first 那一拍，a_bar 已经是流水线里的柱号）
always @(posedge clk) begin
    if (!rst && u_dut.a_vld && u_dut.a_first)
        first_cnt[u_dut.a_bar] = first_cnt[u_dut.a_bar] + 1;
end

// ---------------- 主流程 ----------------
task run_round;
    begin
        // 灌 1024 个 48kHz 样本（每拍一个，只是为了让状态机离开 S_FILL）
        for (i = 0; i < 1024; i = i + 1) begin
            audio_valid = 1'b1;
            audio_l     = $signed(24'sd1000000) * ((i % 64) - 32);
            @(posedge clk);
        end
        audio_valid = 1'b0;
        // 等这一轮走完（S_FILL→..→S_END→S_FILL），最多 200k 拍
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge clk);
            if (dbg_state == 5'd0 && u_dut.fill_cnt == 0 && u_dut.bin_cnt == 0) begin
                i = 200000;
            end
        end
    end
endtask

initial begin
    errors = 0;
    clk = 0; rst = 1;
    audio_valid = 0; audio_l = 0; bar_idx = 0;

    // 边界表（与 RTL 逐项一致）
    EDGE[0]=1;   EDGE[1]=2;   EDGE[2]=3;   EDGE[3]=4;   EDGE[4]=5;
    EDGE[5]=6;   EDGE[6]=7;   EDGE[7]=8;   EDGE[8]=9;   EDGE[9]=10;
    EDGE[10]=11; EDGE[11]=12; EDGE[12]=13; EDGE[13]=14; EDGE[14]=15;
    EDGE[15]=16; EDGE[16]=17; EDGE[17]=18; EDGE[18]=19; EDGE[19]=20;
    EDGE[20]=21; EDGE[21]=22; EDGE[22]=23; EDGE[23]=24; EDGE[24]=25;
    EDGE[25]=26; EDGE[26]=27; EDGE[27]=28; EDGE[28]=29; EDGE[29]=30;
    EDGE[30]=31; EDGE[31]=32; EDGE[32]=33; EDGE[33]=35; EDGE[34]=37;
    EDGE[35]=39; EDGE[36]=41; EDGE[37]=44; EDGE[38]=46; EDGE[39]=49;
    EDGE[40]=52; EDGE[41]=55; EDGE[42]=58; EDGE[43]=61; EDGE[44]=64;
    EDGE[45]=68; EDGE[46]=72; EDGE[47]=76; EDGE[48]=81; EDGE[49]=85;
    EDGE[50]=90; EDGE[51]=95; EDGE[52]=101;EDGE[53]=106;EDGE[54]=113;
    EDGE[55]=119;EDGE[56]=126;EDGE[57]=133;EDGE[58]=141;EDGE[59]=149;
    EDGE[60]=157;EDGE[61]=166;EDGE[62]=176;EDGE[63]=186;EDGE[64]=197;
    EDGE[65]=208;EDGE[66]=220;EDGE[67]=232;EDGE[68]=246;EDGE[69]=260;
    EDGE[70]=275;EDGE[71]=291;EDGE[72]=307;EDGE[73]=325;EDGE[74]=343;
    EDGE[75]=363;EDGE[76]=384;EDGE[77]=406;EDGE[78]=429;EDGE[79]=454;
    EDGE[80]=480;

    for (k = 0; k < 80; k = k + 1) begin
        visit_cnt[k] = 0;
        first_cnt[k] = 0;
    end

    #200; rst = 0; #200;

    // 跑两轮，第二轮才是稳态（第一轮 sbuf 里是初值）
    run_round;
    for (k = 0; k < 80; k = k + 1) begin
        visit_cnt[k] = 0;
        first_cnt[k] = 0;
    end
    run_round;

    // ---- V2：80 根柱全都被访问 ----
    for (k = 0; k < 80; k = k + 1) begin
        if (visit_cnt[k] == 0) begin
            $display("FAIL V2 bar %0d never visited", k);
            errors = errors + 1;
        end
    end
    $display("INFO V2 visited bars: bar0=%0d bin, bar32=%0d bin, bar79=%0d bin",
             visit_cnt[0], visit_cnt[32], visit_cnt[79]);
    // 低频每柱 1 bin，高频每柱最多 26 bin
    if (visit_cnt[0] !== 1) begin
        $display("FAIL V2 bar0 应收到 1 个 bin，实际 %0d", visit_cnt[0]); errors=errors+1; end
    if (visit_cnt[32] !== 2) begin
        $display("FAIL V2 bar32 应收到 2 个 bin(33..34)，实际 %0d", visit_cnt[32]); errors=errors+1; end
    if (visit_cnt[79] !== 26) begin
        $display("FAIL V2 bar79 应收到 26 个 bin(454..479)，实际 %0d", visit_cnt[79]); errors=errors+1; end

    // ---- V3：每柱 first 恰好一次 ----
    for (k = 0; k < 80; k = k + 1) begin
        if (first_cnt[k] !== 1) begin
            $display("FAIL V3 bar %0d first 出现 %0d 次（应为 1）", k, first_cnt[k]);
            errors = errors + 1;
        end
    end
    $display("INFO V3 first 标记每柱恰好一次");

    // ---- V4：bars[] 有内容 ----
    k = 0;
    for (i = 0; i < 80; i = i + 1)
        if (u_dut.bars[i] != 0) k = k + 1;
    $display("INFO V4 bars[] 非零柱子数 = %0d / 80", k);
    if (k < 40) begin
        $display("FAIL V4 非零柱子太少，提交链可能断了"); errors = errors + 1; end

    if (errors == 0) $display("\n==== ALL PASS ====");
    else             $display("\n==== %0d FAIL ====", errors);
    $finish;
end

endmodule
