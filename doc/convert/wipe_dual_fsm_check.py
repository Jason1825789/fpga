#!/usr/bin/env python3
import sys
# -*- coding: utf-8 -*-
"""
mode=2'b10 真实行为复刻: 淡化 FSM 与黑幕 FSM 同时运行
关键发现: mode_fade = mode[1]^mode[0] 在 mode=2'b10 时同样为 1,
所以 mode=10 会同时启动 FADE_ST_* 两段式淡化, 与黑幕擦除叠加。
"""
FRAME_MS = 800 * 525 / 25e6 * 1000.0   # 16.8 ms

ALPHA_MAX, ALPHA_STEP = 255, 8
HOLD_FRAMES, SWAP_WAIT_FRAMES = 3, 4
WIPE_STEP, W_SWITCH_HOLD, WIPE_HOLD_F = 16, 4, 2
WIPE_W = 640

F_IDLE, F_ARM, F_RUN, F_HOLD = range(4)
W_IDLE, W_ARM, W_OUT, W_BLACK, W_IN, W_HOLD = range(6)
FNAME = {F_IDLE:'FADE_IDLE', F_ARM:'FADE_ARM', F_RUN:'FADE_RUN', F_HOLD:'FADE_HOLD'}
WNAME = {W_IDLE:'W_IDLE', W_ARM:'W_ARM', W_OUT:'W_OUT',
         W_BLACK:'W_BLACK', W_IN:'W_IN', W_HOLD:'W_HOLD'}

def decode(mode):
    m1, m0 = (mode >> 1) & 1, mode & 1
    return (m1 ^ m0), (m1 & (~m0 & 1))

def cover_txt(hide_frac, w_st):
    if w_st in (W_IDLE, W_ARM): return "旧图 100%"
    if w_st == W_OUT:   return "旧图 遮%d%%" % (hide_frac * 100)
    if w_st == W_BLACK: return "旧图 全遮"
    if w_st == W_IN:    return "新图 露%d%%" % ((1 - hide_frac) * 100)
    return "新图 100%"

def run(mode=2, frames=110):
    mode_fade, mode_wipe = decode(mode)
    fs_d1 = 1# 帧0 之前 fade_req 已到达并完成两级同步
    f_st, alpha, half, arm_c, hold_c, swap_c, fade_done = F_IDLE, ALPHA_MAX, 0, 0, 0, 0, 0
    w_st, wpos, w_c, wipe_done = W_IDLE, 0, 0, 0
    buf_swapped = 0
    log = []
    for f in range(frames):
        fd_pulse, wd_pulse = fade_done, wipe_done
        if (fd_pulse or wd_pulse) and not buf_swapped:
            buf_swapped = 1# sd_card 域: 翻转 + fade_req 拉低
            fs_d1 = 0
        if w_st in (W_OUT, W_BLACK):
            hide_frac = wpos / WIPE_W
        elif w_st in (W_IN, W_HOLD):
            hide_frac = 1.0 - wpos / WIPE_W
        else:
            hide_frac = 0.0
        fade_on = (f_st == F_RUN)
        a = alpha if fade_on else 255
        base = cover_txt(hide_frac, w_st)
        if a == 0:
            cover = "全黑(alpha=0)"
        elif a < 255:
            cover = "%s x %d%%" % (base, round(a / 255 * 100))
        else:
            cover = base
        log.append(dict(f=f, f_st=f_st, w_st=w_st, wpos=wpos, alpha=alpha,
                        fade_on=fade_on, cover=cover, buf=buf_swapped,
                        fd=fd_pulse, wd=wd_pulse, fs=fs_d1))
        if f == frames - 1:
            break
        fade_done = 0
        wipe_done = 0
        # ---- 淡化 FSM ----
        if f_st == F_IDLE:
            if fs_d1 and mode_fade:
                f_st, arm_c, swap_c = F_ARM, 0, 0
        elif f_st == F_ARM:
            if arm_c >= 1:
                f_st, alpha, half = F_RUN, ALPHA_MAX, 0
            else:
                arm_c += 1
        elif f_st == F_RUN:
            if mode_fade:
                if not half:
                    if alpha == 0:
                        half = 1; fade_done = 1; swap_c = SWAP_WAIT_FRAMES
                    elif alpha <= ALPHA_STEP:
                        alpha = 0
                    else:
                        alpha -= ALPHA_STEP
                else:
                    if swap_c != 0:
                        swap_c -= 1; alpha = 0
                    elif alpha >= ALPHA_MAX:
                        f_st, hold_c = F_HOLD, 0
                    elif alpha + ALPHA_STEP >= ALPHA_MAX:
                        alpha = ALPHA_MAX
                    else:
                        alpha += ALPHA_STEP
            else:
                f_st, hold_c, fade_done = F_HOLD, 0, 1
        elif f_st == F_HOLD:
            if hold_c >= HOLD_FRAMES - 1:
                f_st = F_IDLE
            else:
                hold_c += 1
        # ---- 黑幕 FSM ----
        if w_st == W_IDLE:
            if fs_d1 and mode_wipe:
                w_st, wpos, w_c = W_ARM, 0, 0
        elif w_st == W_ARM:
            if w_c >= 1:
                w_st, wpos, w_c = W_OUT, 0, 0
            else:
                w_c += 1
        elif w_st == W_OUT:
            if wpos >= WIPE_W - WIPE_STEP:
                w_st, wpos, w_c = W_BLACK, WIPE_W, 0
            else:
                wpos += WIPE_STEP
        elif w_st == W_BLACK:
            if w_c == 0:
                wipe_done = 1
            if w_c + 1 >= W_SWITCH_HOLD:
                w_st, wpos, w_c = W_IN, 0, 0
            else:
                w_c += 1
        elif w_st == W_IN:
            if wpos >= WIPE_W - WIPE_STEP:
                w_st, wpos, w_c = W_HOLD, WIPE_W, 0
            else:
                wpos += WIPE_STEP
        elif w_st == W_HOLD:
            if w_c + 1 >= WIPE_HOLD_F:
                w_st, w_c = W_IDLE, 0
            else:
                w_c += 1
    return log, mode_fade, mode_wipe

if __name__ == '__main__':
    print("=== 模式译码真值表(osd_engine L182-183 实际表达式) ===")
    print(f"  {'mode':>7} {'sw2':>4}{'sw1':>4} {'mode_fade':>10} {'mode_wipe':>10}  实际启动的 FSM")
    for m in range(4):
        mf, mw = decode(m)
        acts = ([ "淡化FSM"] if mf else []) + ([ "黑幕FSM"] if mw else [])
        mstr = "2'b%02d" % m
        print(f"  {mstr:>7} {(m>>1)&1:>4}{m&1:>4} {str(mf):>10} {str(mw):>10}  "
              f"{' + '.join(acts) if acts else '都不启动 -> 纯硬切'}")

    log, mf, mw = run(2)
    print("\n=== mode=2'b10 逐帧真实画面(只列变化帧) ===")
    print(f"  mode_fade={mf}  mode_wipe={mw}   *** 两个 FSM 同时跑 ***\n")
    print(f"  {'F':>3} {'淡化状态':>10} {'黑幕状态':>9} {'pos':>4} {'alpha':>5}  "
          f"{'实际画面':>26}  事件")
    prev = None
    for r in log:
        key = (r['f_st'], r['w_st'], r['wpos'], r['alpha'])
        ev = []
        if r['fd']: ev.append("<<fade_done 切缓冲>>")
        if r['wd']: ev.append("<<wipe_done>>")
        if key == prev and not ev:
            continue
        prev = key
        print(f"  {r['f']:>3} {FNAME[r['f_st']]:>10} {WNAME[r['w_st']]:>9} "
              f"{r['wpos']:>4} {r['alpha']:>5}  {r['cover']:>26}  {' '.join(ev)}")

    fd = [r['f'] for r in log if r['fd']]
    wd = [r['f'] for r in log if r['wd']]
    az = [r['f'] for r in log if r['alpha'] == 0]
    af = [r['f'] for r in log if r['fade_on'] and r['alpha'] == ALPHA_MAX]
    fend = [r['f'] for r in log if r['f_st'] == F_IDLE and r['f'] > 3]
    wend = [r['f'] for r in log if r['w_st'] == W_IDLE and r['f'] > 3]
    print("\n=== 关键事件帧 ===")
    if fd:
        r = log[fd[0]]
        print(f"  淡化 fade_done → 真正翻转缓冲 : F{fd[0]}  "
              f"(此刻黑幕 pos={r['wpos']}, 仅遮 {r['wpos']*100//WIPE_W}%, "
              f"alpha={r['alpha']} → 不是整黑帧!)")
    print(f"  黑幕 wipe_done → 已被忽略      : F{wd[0] if wd else '-'}")
    print(f"  alpha 首次为 0(画面全黑)      : F{az[0] if az else '-'}")
    print(f"  alpha 回到 255                : F{af[0] if af else '-'}")
    print(f"  淡化 FSM 回 IDLE              : F{fend[0] if fend else '-'}")
    print(f"  黑幕 FSM 回 IDLE              : F{wend[0] if wend else '-'}")
    if fend and wend:
        gap = wend[0] - fend[0]
        print(f"\n  ★ 整段动画长度由黑幕决定: {wend[0]} 帧 = {wend[0]*FRAME_MS:.1f} ms")
        print(f"  ★ 淡化比黑幕早结束 {gap} 帧 ({gap*FRAME_MS:.1f} ms)")
        print(f"    → 最后 {gap} 帧是「纯黑幕揭开、亮度已恒为 255」，"
              f"两套动画进度条时基不一致")
    print(f"\n  ★ mode=10 名义上是「黑幕擦除」, 实际叠加了淡化, 视觉上是")
    print(f"    「幕布推进中画面同时变暗」→ 屏幕出现两次「黑→亮」, 且亮度")
    print(f"    恢复点(F{af[0] if af else '-'})远早于幕布揭开完成点(F{wend[0] if wend else '-'})")

    log1, _, _ = run(1, frames=90)
    f1 = [r['f'] for r in log1 if r['f_st'] == F_IDLE and r['f'] > 3]
    print(f"\n=== 对照: mode=2'b01 纯淡化 ===")
    print(f"  总帧数 ≈ {f1[0] if f1 else '-'} 帧 = {(f1[0] if f1 else 0)*FRAME_MS:.1f} ms")
    print(f"  auto_tick=1000 ms  vs  mode01 {f1[0]*FRAME_MS:.0f} ms / mode10 "
          f"{wend[0]*FRAME_MS:.0f} ms")

# ============ 追加: 修复 P0 后的验证 ============
if __name__ == '__main__' and len(sys.argv) > 1 and sys.argv[1] == 'fix':
    import sys
    print("\n" + "="*66)
    print("=== 修复 P0 (mode_fade 只在 01 生效) 后的纯黑幕时间轴 ===")
    print("="*66)
    #纯黑幕模型: 只跑 wipe FSM
    def wipe_only(step=WIPE_STEP, sh=W_SWITCH_HOLD, hf=WIPE_HOLD_F, n=200):
        st, pos, cnt = W_ARM, 0, 0
        rows = []
        f = 0
        while f < n:
            rows.append((f, st, pos))
            nst, npos, ncnt = st, pos, cnt
            if st == W_ARM:
                if cnt >= 1: nst, npos, ncnt = W_OUT, 0, 0
                else: ncnt = cnt + 1
            elif st == W_OUT:
                if pos >= WIPE_W - step: nst, npos, ncnt = W_BLACK, WIPE_W, 0
                else: npos = pos + step
            elif st == W_BLACK:
                if cnt + 1 >= sh: nst, npos, ncnt = W_IN, 0, 0
                else: ncnt = cnt + 1
            elif st == W_IN:
                if pos >= WIPE_W - step: nst, npos, ncnt = W_HOLD, WIPE_W, 0
                else: npos = pos + step
            elif st == W_HOLD:
                if cnt + 1 >= hf: nst, ncnt = W_IDLE, 0
                else: ncnt = cnt + 1
            st, pos, cnt = nst, npos, ncnt
            f += 1
            if st == W_IDLE and f > 3: break
        return rows
    rows = wipe_only()
    total = len(rows)
    first_new = [f for f, s, p in rows if s == W_IN and p > 0]
    full_new = [f for f, s, p in rows if s == W_HOLD]
    blacks = [f for f, s, p in rows if s == W_BLACK or (s == W_IN and p == 0)]
    print(f"  总帧数     : {total} 帧 = {total*FRAME_MS:.1f} ms")
    print(f"  整屏全黑帧 : F{blacks[0]}~F{blacks[-1]} 共 {len(blacks)} 帧 = {len(blacks)*FRAME_MS:.1f} ms")
    print(f"  新图首像素 : F{first_new[0]}")
    print(f"  整屏新图   : F{full_new[0]}")
    print(f"  切缓冲脉冲 : F{[f for f,s,p in rows if s==W_BLACK][0]}(W_BLACK 首帧)")
    print(f"\n  auto_tick 必须 > {total*FRAME_MS:.0f} ms, 建议 2000 ms")
    print(f"  当前 auto_tick = 1000 ms -> 积压速率 "
          f"{(1000/(total*FRAME_MS) - 1)*-1:+.3f} 请求/秒")
