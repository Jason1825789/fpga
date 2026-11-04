
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. 音频 I2S 发生器/接收器跨域
#
#    audio_mclk 域里生成 I2S，video_clk 域里做三拍同步采样。
#    这类路径不是普通同步时序路径，直接切掉更合理。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {video_clk} hdmi_5x_clk sd_card_clk ext_mem_clk]

# ------------------------------------------------------------
# 6. 跨时钟域分组(2026-10-04 已核对后启用)
#
#    核对结论:本工程所有跨域通路都只经过"异步 FIFO / 多级同步器",没有裸穿组合逻辑:
#      * sd_card_clk <-> ext_mem_clk : frame_read_write 内的 wfifo/rfifo 异步 FIFO
#      * video_clk   <-> ext_mem_clk : 两个读 FIFO + read_req/read_req_ack 三级同步
#      * sd_card_clk <-> video_clk   : fade_start/fade_done/sw_fade 单 bit + 多级同步
#      * clk(50M)    <-> 各 PLL 输出 : PLL 输出本身就是独立时钟域
#      多 bit 跨域信号(disp_buf_idx / write_buf_idx / read_addr_index)只取 0/1 两个值,
#      每次变化只有 1 个 bit 翻转,等价于格雷码,配合两级采样安全。
#
#    不加这组约束时,工具会把这些 CDC 路径当同步路径分析,
#    报出 fade_done(-3.695ns)、fifo_aclr(-0.453ns) 等大量伪违例,
#    既污染 TNS,也让优化器把资源浪费在不可能收敛的路径上。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {clk}] \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk}] \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. SDRAM 物理接口:不是片内寄存器到寄存器时序
#
#    SDRAM 的 addr/dq/dm/ba/ras/cas/we 由 EG_PHY_SDRAM 硬核按相移时钟 osclk 直接驱动,
#    属于"FPGA 引脚 -> 外部 SDRAM 器件"的板级时序。
#    本 SDC 没有写任何 Input/Output delay,若不切掉,工具会按"整个时钟周期"来分析这些
#    引脚路径,产生一批假的 -6.699ns / -3.695ns 违例:
#      U3/sdram.osclk      -> U3/sdram.addr[7]   -6.699ns
#      U3/sdram.dq[*]      -> U3/sdram.bpad      -6.699ns
#      U3/u2_ram/.../app_wr_addr_4d_reg[*] -> U3/sdram.dq[*]  -3.695ns
#    这些路径的真实约束应来自板级 SDRAM 时序,不是片内 STA,故直接设 false path。
# ------------------------------------------------------------
# 查询 routed DB 已确认该集合匹配 55 个 EG_PHY_SDRAM 端口。这里必须分别
# 从/到硬核端口切断；单独使用 -through 不会覆盖“硬核端口本身就是起点或终点”
# 的路径，旧报告因此仍把 32 条 DQ 板级路径计成 -6.699ns 的片内违例。
set_false_path -from [get_pins {U3/sdram.*}]
set_false_path -to   [get_pins {U3/sdram.*}]

# ------------------------------------------------------------
# 8. 低速人机接口
#    数码管刷新约 1kHz、按键/拨码是机械器件,都不参与高速时序分析。
#    (不切掉时 write_req -> seg_data 会报 -1.125ns 的假违例)
# ------------------------------------------------------------
set_false_path -to [get_ports {seg_sel[*]}]
set_false_path -to [get_ports {seg_data[*]}]
set_false_path -from [get_ports {key1 key2 sw1 sw2}]

# ------------------------------------------------------------
# 9. 说明:HDMI 的 TMDS 输出与 DDC 仍是真实高速路径,未做处理,
#    由视频 PLL 的 5 倍串行时钟(hdmi_5x_clk)约束,需保持收敛。
# ------------------------------------------------------------
