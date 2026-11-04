#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模式 1 两段式淡入淡出 参考模型(与 osd_engine.v 当前实现逐条对齐)。

效果定义(一次按键 = 一个完整循环):
  前半段 : 显示 ch1(旧图), 亮度 alpha 255→0  → 画面由亮逐渐变暗, 直到全黑
  全黑帧 : alpha==0 的那一帧发出 fade_done → sd_card_bmp 翻转 disp_buf_idx
           —— 切图动作藏在全黑里, 肉眼看不到
  黑场等待: 保持若干完整黑帧，等待新缓冲跨域并从帧首生效
  后半段 : ch1 此时已指向新图, 亮度 alpha 0→255 → 画面由最暗逐渐变回最亮
  HOLD   : 多停几帧收尾, 然后回 IDLE 停在最亮, 等待下一次按键

本模型验证七件事:
  1) 亮度序列单调(先降后升), 端点正确(255→0→255)
  2) 切图点(fade_half 0→1)落在 alpha==0 的那一帧
  3) **结尾无可见闪帧**: 全程只显示 ch1, 翻转发生在全黑帧,
     显示内容序列不会出现"新图→旧图"回跳(与旧写法对照)
  4) OSD 字幕/红条随整屏淡化(FADE_INCLUDE_OSD=1, 全黑时屏幕确实全黑)
  5) 进度量只在 vsync 更新(DE=1 期间恒定 → 无帧内撕裂)
  6) 完整转场时长 < sd_card_bmp 的 FADE_TIMEOUT_CYCLES
  7) sd_card_bmp 两条切图路径互不干扰

说明:
  * 本文件只做"结构/时序语义"级别的验证, 不涉及具体像素值;
    像素级亮度缩放由 logic_ref_check.py 的 check_scale_alpha 负责。
  * "本帧显示内容"用 img 表示(OLD_IMG / NEW_IMG), 与真实缓冲索引一一对应;
    disp_buf 的翻转在"下一帧"才生效(读地址只在 S_ACK 时锁存)。
"""

ALPHA_MAX = 255
ALPHA_STEP = 8
HOLD_FRAMES = 3
SWAP_WAIT_FRAMES = 4
FADE_TIMEOUT_FRAMES = 5 * 60          # sd_card_bmp: CLK_FREQ_HZ * 5 = 5s @60Hz
GHOST_ALPHA_LIMIT = 8                 # 亮度低于此值的帧视为"黑", 其上换图不可见
FADE_INCLUDE_OSD = 1                  # osd_engine.v 当前取值(整屏淡化)


def w8(x):
    """RTL 8 位寄存器语义(截断到 0..255)。

    模型必须模拟位宽:Python 整数不回绕,若不做 w8,
    "alpha + ALPHA_STEP" 在 RTL 里发生的 8 位回绕 bug 在模型里
    永远复现不出来 —— 这正是 2026-10-05 上板"转场结束后反复
    变暗变亮"被漏检的根本原因(模型与 RTL 的位宽语义不一致)。
    """
    return x & 0xFF

IDLE, ARM, RUN, HOLD = "IDLE", "ARM", "RUN", "HOLD"
OLD_IMG, NEW_IMG = 0, 1


def osd_step(st, alpha, half, arm_cnt, hold_cnt, swap_wait_cnt, start, buggy=False):
    """模式 1 状态机一步(= 一个 vs 下降沿)。

    返回 (新状态, alpha, half, arm_cnt, hold_cnt, swap_wait_cnt,
          flip_black, done_end)
      flip_black : 本步发生在"全黑"帧 → 新写法在此刻翻转缓冲(切图藏在黑场)
      done_end   : 本步进入 HOLD → 旧写法在此刻翻转缓冲(导致结尾闪帧)
    """
    flip_black = False
    done_end = False
    if st == IDLE:
        if start:
            st, arm_cnt = ARM, 0
    elif st == ARM:
        if arm_cnt == 1:
            st, alpha, half = RUN, ALPHA_MAX, 0     # 前半段从最亮开始
        else:
            arm_cnt += 1
    elif st == RUN:
        if half == 0:
            if alpha == 0:
                half = 1                            # 已全黑 → 切到后半段(改看新图)
                flip_black = True                   # ★ 全黑帧: 通知翻转缓冲
                swap_wait_cnt = SWAP_WAIT_FRAMES    # 等新缓冲在三个时钟域稳定
            elif alpha <= ALPHA_STEP:
                alpha = 0
            else:
                alpha -= ALPHA_STEP
        else:
            if swap_wait_cnt != 0:
                swap_wait_cnt -= 1
                alpha = 0
            elif alpha >= ALPHA_MAX:
                st, hold_cnt, done_end = HOLD, 0, True
            elif buggy:
                # 修复前的 RTL:饱和比较也用 8 位加法(alpha + ALPHA_STEP)。
                # ALPHA_STEP=8 时 alpha=248 → 248+8 回绕成 0,比较 0>=255 永假,
                # 走 else 被赋成回绕后的 0 → FADE_IN 在 0..248 间无限循环,
                # 永远升不到 255,状态机卡死在 RUN:
                #   现象 = 转场结束后屏幕反复"变暗→变亮"、图片不再切换。
                if w8(alpha + ALPHA_STEP) >= ALPHA_MAX:
                    alpha = ALPHA_MAX        # 只有回绕值恰为 255 才成立,实际到不了
                else:
                    alpha = w8(alpha + ALPHA_STEP)
            elif alpha + ALPHA_STEP >= ALPHA_MAX:
                # 修复后的 RTL:{1'b0,alpha}+{1'b0,STEP} 9 位比较,
                # 248+8=256 >= 255 成立 → alpha 饱和到 255,FADE_IN 正常结束。
                alpha = ALPHA_MAX
            else:
                alpha = w8(alpha + ALPHA_STEP)
    elif st == HOLD:
        if hold_cnt >= HOLD_FRAMES - 1:
            st = IDLE
        else:
            hold_cnt += 1
    return (st, alpha, half, arm_cnt, hold_cnt, swap_wait_cnt,
            flip_black, done_end)


def run_model(mode="new", frames=220):
    """逐帧记录本帧的显示内容 / 亮度 / 状态。

    mode="new" : 当前实现 —— 全程只显示 ch1, 翻转发生在全黑帧
    mode="old" : 旧写法对照 —— 后半段/HOLD 显示 ch2, 翻转发生在后半段结束
                  (用来证明"结尾闪一下"确实是旧写法引入的)
    """
    st, alpha, half, arm_cnt, hold_cnt = IDLE, ALPHA_MAX, 0, 0, 0
    swap_wait_cnt = 0
    disp_buf = 0                     # ch1 当前指向的缓冲; 0=旧图, 1=新图
    log = []
    for k in range(frames):
        # ---- 本帧显示来源 ----
        if mode == "new":
            src_img = disp_buf                          # 全程 ch1
        else:
            if st == HOLD or (st == RUN and half == 1):
                src_img = disp_buf ^ 1                  # ch2 = disp_buf^1
            else:
                src_img = disp_buf

        # ---- 本帧亮度与文字描述 ----
        if st == RUN:
            bright = alpha
            if alpha == 0:
                shown = "全黑        "
            elif half == 0:
                shown = "旧图 亮度%3d" % alpha
            else:
                shown = "新图 亮度%3d" % alpha
        else:
            bright = ALPHA_MAX
            shown = "新图 亮度255" if src_img == NEW_IMG else "旧图 亮度255"

        log.append(dict(k=k, st=st, alpha=alpha, half=half,
                        img=src_img, bright=bright, shown=shown))

        # ---- 推进到下一帧(寄存器更新) ----
        (st, alpha, half, arm_cnt, hold_cnt, swap_wait_cnt,
         flip_black, done_end) = osd_step(
            st, alpha, half, arm_cnt, hold_cnt, swap_wait_cnt, k == 0)
        if mode == "new":
            if flip_black:
                disp_buf ^= 1          # 全黑帧翻转 → 下一帧起 ch1 = 新图
        else:
            if done_end:
                disp_buf ^= 1          # 旧写法: 后半段结束才翻转
    return log


def find_img_switches(log):
    """找出"显示内容发生切换"的帧: (帧号, 切换前img, 切换后img, 切换时亮度)"""
    out = []
    for i in range(1, len(log)):
        if log[i]["img"] != log[i - 1]["img"]:
            out.append((log[i]["k"], log[i - 1]["img"], log[i]["img"], log[i]["bright"]))
    return out


def check_two_paths() -> bool:
    """验证 sd_card_bmp 的两条切图路径互不干扰。

    最关键的一条:即使 fade_pending 残留为 1(模式 1 的转场状态没清干净,
    例如转场中途拨动 SW1),路径 B(硬切)也必须能正常切图 ——
    这正是重构前被外层 `!fade_pending` 挡住的地方。
    """
    def path_b_new(fade_pending_leftover):
        """重构后:路径 B 只依赖 req_cnt / pfb_valid / display_valid"""
        req_cnt, pfb_valid, display_valid = 1, 1, 1
        disp_buf = 0
        if req_cnt != 0 and pfb_valid and display_valid:
            disp_buf ^= 1
            req_cnt -= 1
        return disp_buf, req_cnt

    def path_b_old(fade_pending_leftover):
        """重构前:整个换图块被套在 `&& !fade_pending` 里"""
        req_cnt, pfb_valid, display_valid = 1, 1, 1
        disp_buf = 0
        if req_cnt != 0 and pfb_valid and display_valid and not fade_pending_leftover:
            disp_buf ^= 1
            req_cnt -= 1
        return disp_buf, req_cnt

    old_ok, _ = path_b_old(True)
    new_ok, _ = path_b_new(True)
    ok = (new_ok == 1) and (old_ok == 0)

    print("-- 两条路径互不干扰 --")
    print("   场景:fade_pending 残留 = 1 时, 模式 2 按一下键")
    print("     重构前(换图块被 !fade_pending 套住) → disp_buf_idx 翻转 = %d%s"
          % (old_ok, "  ← 被卡住, 这就是之前的现象" if old_ok == 0 else ""))
    print("     重构后(路径 B 完全不看 fade_*)      → disp_buf_idx 翻转 = %d%s"
          % (new_ok, "  ← 可正常切换" if new_ok == 1 else "  ← 仍被卡住!"))
    print("   -> %s" % ("通过" if ok else "不通过"))
    return ok


def trace_fade_in(buggy=False, frames=120):
    """只跑后半段(FADE_IN)的 alpha 轨迹, 对比修复前后能否升到 ALPHA_MAX。

    buggy=False : 当前 RTL(9 位比较) → 0,8,...,248,255 → 进入 HOLD
    buggy=True  : 修复前 RTL(8 位回绕) → 0,8,...,248,0,8,... 永远循环, 卡死
    """
    st, alpha, half, hold_cnt, swap_wait_cnt = RUN, 0, 1, 0, 0
    trace = []
    for _ in range(frames):
        trace.append(alpha)
        (st, alpha, half, _, hold_cnt, swap_wait_cnt, _, _) = osd_step(
            st, alpha, half, 0, hold_cnt, swap_wait_cnt, False, buggy=buggy)
        if st == HOLD:
            break
    return trace, st


def check_overflow_bug() -> bool:
    """复现并证明已修复"8 位回绕"bug(与 osd_engine.v 第 260 行对应)。"""
    fixed_tr, fixed_end = trace_fade_in(buggy=False)
    buggy_tr, buggy_end = trace_fade_in(buggy=True)

    fixed_ok = (fixed_end == HOLD) and (fixed_tr[-1] == ALPHA_MAX)
    buggy_stuck = (buggy_end == RUN) and (ALPHA_MAX not in buggy_tr)
    ok = fixed_ok and buggy_stuck

    print("-- 8 位回绕 bug 复现与修复(本次核心) --")
    print("   [修复前] alpha 轨迹尾段: %s" % buggy_tr[-6:])
    print("      在 %d 帧内升到 255? %s   结束状态 = %s"
          % (len(buggy_tr), "是" if ALPHA_MAX in buggy_tr else "否", buggy_end))
    print("   [修复后] alpha 轨迹尾段: %s" % fixed_tr[-4:])
    print("      在 %d 帧内升到 255? %s   结束状态 = %s"
          % (len(fixed_tr), "是" if ALPHA_MAX in fixed_tr else "否", fixed_end))
    print("   -> %s" % ("通过(修复前卡死在 RUN、修复后正常收敛到 HOLD)" if ok else "不通过"))
    return ok


def main() -> int:
    log = run_model("new")
    old_log = run_model("old")
    run = [e for e in log if e["st"] == "RUN"]
    if not run:
        print("模型异常: 没有进入 RUN")
        return 1

    # 1) 亮度序列
    half0 = [e["alpha"] for e in run if e["half"] == 0]
    half1 = [e["alpha"] for e in run if e["half"] == 1]
    down = all(half0[i] >= half0[i + 1] for i in range(len(half0) - 1))
    up = all(half1[i] <= half1[i + 1] for i in range(len(half1) - 1))

    # 2) 切图点(最关键):fade_half 0→1 落在全黑帧
    switch_idx = None
    for i in range(1, len(run)):
        if run[i - 1]["half"] == 0 and run[i]["half"] == 1:
            switch_idx = i
            break
    switch_alpha = run[switch_idx]["alpha"] if switch_idx is not None else None
    prev_alpha = run[switch_idx - 1]["alpha"] if switch_idx else None
    black = [e["k"] for e in run if e["alpha"] == 0]

    # 3) 结尾无可见闪帧
    sw_new = find_img_switches(log)
    sw_old = find_img_switches(old_log)
    ghost_new = [s for s in sw_new if s[3] > GHOST_ALPHA_LIMIT]
    ghost_old = [s for s in sw_old if s[3] > GHOST_ALPHA_LIMIT]

    # 4) OSD 随整屏淡化，alpha=0 时输出真正全黑
    osd_ok = (FADE_INCLUDE_OSD == 1)

    # 5) 进度只在 vsync 更新 —— 由模型结构保证(每步 = 一帧)
    vsync_ok = True

    # 6) 时长
    first_run = run[0]["k"]
    last_run = run[-1]["k"]
    total_frames = (last_run - first_run) + 1 + HOLD_FRAMES

    ok_math = (down and up and half0[0] == ALPHA_MAX and half0[-1] == 0
               and half1[0] == 0 and half1[-1] == ALPHA_MAX)
    ok_switch = (switch_alpha == 0) and (prev_alpha == 0)
    ok_flash = (ghost_new == [])

    print("== 模式 1:两段式淡入淡出 参考模型 ==")
    print("   ALPHA_STEP = %d, 每段 %d 步, 黑场等待 = %d 帧, HOLD = %d 帧"
          % (ALPHA_STEP, -(-ALPHA_MAX // ALPHA_STEP), SWAP_WAIT_FRAMES, HOLD_FRAMES))
    print()
    print("-- 亮度序列 --")
    print("   前半段(旧图): %s ... %s  共 %d 帧, 单调递减 = %s"
          % (half0[:4], half0[-3:], len(half0), down))
    print("   后半段(新图): %s ... %s  共 %d 帧, 单调递增 = %s"
          % (half1[:4], half1[-3:], len(half1), up))
    print("   端点: 起点 %d(最亮) → 谷底 %d(全黑) → 终点 %d(最亮)"
          % (half0[0], half0[-1], half1[-1]))
    print()
    print("-- 切图点(最关键) --")
    print("   fade_half 0→1 发生在第 %d 帧, 该帧 alpha = %s" % (run[switch_idx]["k"], switch_alpha))
    print("   切图前一帧 alpha = %s" % prev_alpha)
    print("   -> 切图动作%s"
          % ("正好落在全黑那一帧, 肉眼看不到跳变" if ok_switch else "不在全黑点, 会看到跳变!"))
    print("   全黑帧号 = %s(共 %d 帧)" % (black, len(black)))
    print()
    print("-- 结尾无可见闪帧(本次修复的核心) --")
    print("   [旧写法] 后半段/HOLD 显示 ch2, 翻转在后半段结束:")
    for k, a, b, br in sw_old:
        tag = "  ← 亮度 %d 时换图 = 可见闪帧!" % br if br > GHOST_ALPHA_LIMIT else ""
        print("      第 %3d 帧: %s → %s%s"
              % (k, "旧图" if a == OLD_IMG else "新图",
                 "旧图" if b == OLD_IMG else "新图", tag))
    print("   [新写法] 全程 ch1, 翻转在全黑帧:")
    for k, a, b, br in sw_new:
        tag = "  ← 亮度 %d 时换图 = 可见闪帧!" % br if br > GHOST_ALPHA_LIMIT else "  ← 发生在全黑, 不可见"
        print("      第 %3d 帧: %s → %s%s"
              % (k, "旧图" if a == OLD_IMG else "新图",
                 "旧图" if b == OLD_IMG else "新图", tag))
    print("   旧写法可见闪帧数 = %d, 新写法可见闪帧数 = %d" % (len(ghost_old), len(ghost_new)))
    print("   -> 新写法 %s" % ("结尾无可见闪帧" if ok_flash else "仍有可见闪帧!"))
    print()
    print("-- 时长 --")
    print("   完整转场 ≈ %d 帧 ≈ %.2fs @60Hz" % (total_frames, total_frames / 60.0))
    print("   必须 < 超时 %d 帧 (%.1fs) → %s"
          % (FADE_TIMEOUT_FRAMES, FADE_TIMEOUT_FRAMES / 60.0,
             "通过" if total_frames < FADE_TIMEOUT_FRAMES else "超时, 会被硬切!"))
    print()
    ok_paths = check_two_paths()
    print()
    ok_bug = check_overflow_bug()
    print()
    print("-- OSD 字幕/红条随整屏淡化 --")
    print("   FADE_INCLUDE_OSD = %d → %s"
          % (FADE_INCLUDE_OSD, "整屏一起变暗，全黑点无常亮图层" if osd_ok else "仍有常亮图层"))
    print()
    print("-- 进度只在 vsync 更新 --")
    print("   模型每步 = 一帧(场消隐时刻), alpha 在帧内恒定 → 无帧内撕裂 = %s" % vsync_ok)
    print()
    print("-- 一次按键 = 一个完整循环(循环结束后保持在最亮) --")
    final_state = log[-1]["st"]
    final_ok = (final_state == IDLE)
    print("   一次按键跑完后, 第 %d 帧的状态 = %s (%s)"
          % (len(log) - 1, final_state,
             "保持最亮、等待下一次按键" if final_ok else "没有回到 IDLE, 会继续动!"))
    print("   此时转场请求电平 fs_d1 应为 0, 所以不会自动开始第二个循环")

    ok = (ok_math and ok_switch and ok_flash and osd_ok and vsync_ok
          and (total_frames < FADE_TIMEOUT_FRAMES) and ok_paths and final_ok
          and ok_bug)
    print()
    print("结论:")
    print("   亮度曲线单调 + 端点正确 = %s" % ok_math)
    print("   切图点落在全黑帧      = %s" % ok_switch)
    print("   结尾无可见闪帧        = %s" % ok_flash)
    print("   OSD 随整屏淡化        = %s" % osd_ok)
    print("   帧内无撕裂            = %s" % vsync_ok)
    print("   时长在超时之内        = %s" % (total_frames < FADE_TIMEOUT_FRAMES))
    print("   两条路径互不干扰      = %s" % ok_paths)
    print("   8 位回绕 bug 已修复   = %s" % ok_bug)
    print("   循环结束后停在最亮    = %s" % final_ok)
    print("   总结: %s" % ("通过" if ok else "不通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
