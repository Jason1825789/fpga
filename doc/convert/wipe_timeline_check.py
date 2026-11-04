#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mode=2'b10 (横向黑幕擦除) 帧级参考模型
严格按 osd_engine.v 的 wipe FSM 逐拍复刻, 输出帧级时间轴 + 参数敏感性。
"""
import os, sys

# ---------------- 时基 ----------------
VIDEO_CLK   = 25_000_000
H_TOTAL     = 640 + 16 + 96 + 48     # 800  (color_bar.v 640x480 分支)
V_TOTAL     = 480 + 10 + 2 + 33      # 525
FRAME_CYC   = H_TOTAL * V_TOTAL      # 420000
FRAME_MS    = FRAME_CYC / VIDEO_CLK * 1000.0
FRAME_HZ    = VIDEO_CLK / FRAME_CYC

# ---------------- osd_engine 参数 ----------------
WIPE_W        = 640
WIPE_STEP     = 16
W_SWITCH_HOLD = 4
WIPE_HOLD_F   = 2

# ---------------- 淡化(mode01)参数, 用于对比 ----------------
ALPHA_MAX, ALPHA_STEP, HOLD_FRAMES, SWAP_WAIT_FRAMES = 255, 8, 3, 4

W_IDLE, W_ARM, W_OUT, W_BLACK, W_IN, W_HOLD = range(6)
NAME = {W_IDLE:'W_IDLE', W_ARM:'W_ARM', W_OUT:'W_OUT',
        W_BLACK:'W_BLACK', W_IN:'W_IN', W_HOLD:'W_HOLD'}

def wipe_trace(step=WIPE_STEP, switch_hold=W_SWITCH_HOLD, hold_f=WIPE_HOLD_F, verbose=True):
    """返回 (frames, meta)。frames[i] = (状态, wipe_pos, 该帧是否发 wipe_done)"""
    st, pos, cnt = W_IDLE, 0, 0
    frames = []
    # 帧0: 请求已在 IDLE 中被采样, 进入 W_ARM
    st, pos, cnt = W_ARM, 0, 0
    f = 0
    while True:
        done = 0
        # 本帧呈现
        frames.append([f, st, pos, done])
        # vs_fall 推进
        nxt = st
        npos, ncnt, ndone = pos, cnt, 0
        if st == W_ARM:
            if cnt >= 1:
                nxt, npos, ncnt = W_OUT, 0, 0
            else:
                ncnt = cnt + 1
        elif st == W_OUT:
            if pos >= WIPE_W - step:
                nxt, npos, ncnt = W_BLACK, WIPE_W, 0
            else:
                npos = pos + step
        elif st == W_BLACK:
            if cnt == 0:
                ndone = 1                      # ← 切缓冲脉冲
            if cnt + 1 >= switch_hold:
                nxt, npos, ncnt = W_IN, 0, 0
            else:
                ncnt = cnt + 1
        elif st == W_IN:
            if pos >= WIPE_W - step:
                nxt, npos, ncnt = W_HOLD, WIPE_W, 0
            else:
                npos = pos + step
        elif st == W_HOLD:
            if cnt + 1 >= hold_f:
                nxt, ncnt = W_IDLE, 0
            else:
                ncnt = cnt + 1
        frames[-1][3] = ndone
        st, pos, cnt = nxt, npos, ncnt
        f += 1
        if st == W_IDLE and f > 2:
            break
        if f > 400:
            break
    return frames

def classify(frames):
    full_black, first_new_px, done_frame, first_full_new = [], None, None, None
    for f, st, pos, done in frames:
        if st in (W_BLACK,) or (st == W_IN and pos == 0):
            full_black.append(f)
        if st == W_IN and pos > 0 and first_new_px is None:
            first_new_px = f          # 该帧起左边露出新图
        if done:
            done_frame = f
        if st == W_HOLD and first_full_new is None:
            first_full_new = f
    return full_black, first_new_px, done_frame, first_full_new

if __name__ == '__main__':
    fr = wipe_trace()
    print(f"帧时基: {H_TOTAL}x{V_TOTAL} @ {VIDEO_CLK/1e6:.0f}MHz "
          f"→ {FRAME_HZ:.3f} Hz, 1 帧 = {FRAME_MS:.3f} ms")
    print(f"参数: WIPE_STEP={WIPE_STEP} W_SWITCH_HOLD={W_SWITCH_HOLD} "
          f"WIPE_HOLD_F={WIPE_HOLD_F}\n")

    # 分段统计
    seg = {}
    for f, st, pos, done in fr:
        seg.setdefault(st, []).append(f)
    print("=== 各状态占用帧数 ===")
    order = [W_ARM, W_OUT, W_BLACK, W_IN, W_HOLD]
    for st in order:
        fs = seg.get(st, [])
        if fs:
            print(f"  {NAME[st]:8s} : {len(fs):3d} 帧  (F{fs[0]} ~ F{fs[-1]})"
                  f"  = {len(fs)*FRAME_MS:7.1f} ms")
    total = len(fr)
    print(f"  {'合计':8s} : {total:3d} 帧  = {total*FRAME_MS:7.1f} ms "
          f"({total*FRAME_MS/1000:.3f} s)\n")

    fb, fnew, fdone, ffull = classify(fr)
    print("=== 关键帧点 ===")
    print(f"  黑幕开始(出现全黑区)      : F{seg[W_OUT][0]+1} (wipe_pos 首次 >0)")
    print(f"  切缓冲脉冲 wipe_done       : F{fdone}  (W_BLACK 第1帧, 帧内约 +70ns 翻转)")
    print(f"  新图首像素可见            : F{fnew} (W_IN, wipe_pos={fr[fnew][2]})")
    print(f"  整屏恢复为新图            : F{ffull} (W_HOLD, wipe_pos=640)")
    print(f"  整屏全黑帧集合            : F{fb[0]} ~ F{fb[-1]}  共 {len(fb)} 帧 "
          f"= {len(fb)*FRAME_MS:.1f} ms")
    print(f"  底层切换点 → 动画结束点   : F{fdone} → F{total-1}  = {total-1-fdone} 帧 "
          f"= {(total-1-fdone)*FRAME_MS:.1f} ms\n")

    print("=== 逐帧时间轴(压缩) ===")
    def cover(st, pos):
        if st == W_BLACK or (st == W_IN and pos == 0):
            return "全屏黑"
        if st in (W_ARM, W_IDLE) or (st == W_OUT and pos == 0):
            return "旧图 100%"
        if st == W_OUT:
            return f"旧图 被遮 {100*pos//640}%"
        if st == W_IN:
            return f"新图 露出 {100*pos//640}%"
        return "新图 100%"
    prev = None
    for f, st, pos, done in fr:
        key = (st, pos, done)
        if prev is None or key != prev:
            tag = f"F{f:<3d} {NAME[st]:8s} pos={pos:<3d} " + ('◆切缓冲脉冲' if done else '')
            print(f"  {tag:46s} 覆盖: {cover(st, pos)}")
            prev = key

    print("\n=== 自动轮播节拍对比 ===")
    AUTO_MS = 1000.0
    dur = total * FRAME_MS
    print(f"  auto_tick 周期           : {AUTO_MS:.0f} ms")
    print(f"  wipe 完整时长            : {dur:.1f} ms")
    print(f"  理论安全间隔(需 > 转场)  : > {dur:.1f} ms")
    print(f"  是否 动画 > 轮播周期      : {'是 ★请求必然堆积' if dur > AUTO_MS else '否'}")
    print(f"  净积压速率               : {1000/dur:.3f} - 1.000 = "
          f"{1/dur - 1/AUTO_MS:+.3f} 请求/秒")

    print("\n=== 参数敏感性(总帧数 / 时长) ===")
    print(f"  {'STEP':>5} {'SWITCH_HOLD':>12} {'HOLD_F':>8} {'总帧':>6} {'时长ms':>9} {'全黑帧':>7}")
    for step in (8, 16, 24, 32):
        for sh in (4, 6, 8):
            fr2 = wipe_trace(step=step, switch_hold=sh)
            fb2, _, _, _ = classify(fr2)
            print(f"  {step:>5} {sh:>12} {WIPE_HOLD_F:>8} {len(fr2):>6} "
                  f"{len(fr2)*FRAME_MS:>9.1f} {len(fb2):>7}")

    print("\n=== mode01 淡化对比(已有实现) ===")
    # 前半段: 255→0 每帧 -8 ; alpha==0 时发 done + swap_wait
    a = ALPHA_MAX; half = 0; sw = 0; n = 0
    state = 'ARM'
    dark = 0; black = 0; bright = 0; hold = 0
    while n < 400:
        if state == 'ARM':
            n += 2; state = 'RUN'; a = ALPHA_MAX; half = 0
            continue
        n += 1
        if state == 'RUN':
            if not half:
                if a == 0:
                    half = 1; sw = SWAP_WAIT_FRAMES; black += 1
                else:
                    a = max(0, a - ALPHA_STEP); dark += 1
            else:
                if sw != 0:
                    sw -= 1; black += 1
                elif a >= ALPHA_MAX:
                    state = 'HOLD'; hold = 0
                else:
                    a = min(ALPHA_MAX, a + ALPHA_STEP); bright += 1
        elif state == 'HOLD':
            n += 1; hold += 2
            break
    print(f"  淡化总帧数 ≈ {n} 帧 = {n*FRAME_MS:.1f} ms "
          f"(其中全黑 {black} 帧 = {black*FRAME_MS:.1f} ms)")