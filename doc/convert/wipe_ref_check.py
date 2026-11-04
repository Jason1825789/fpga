#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mode=2'b10 横向黑幕擦除 参考模型(与 osd_engine.v 新增逻辑逐条对齐)。

对应 RTL:
  osd_engine.v  W_IDLE/W_ARM/W_OUT/W_BLACK/W_IN/W_HOLD + wipe_pos + wipe_done_r
  sd_card_bmp.v trans_mode = sw_fade_sync ^ sw2_sync  (1 → 路径 A 转场)

检查项:
  1) 正常流程:状态序列、wipe_pos 轨迹、done 脉冲恰好 1 次且落在整黑帧
  2) 时长:总帧数必须 < sd_card_bmp 的 5s 超时(300 帧 @60Hz)
  3) wipe_pos 只在帧边界(vs_fall)变化 → 整帧内画面不撕裂(逐帧比较器输入恒定)
  4) 像素级:每帧"可见图像宽度"与状态一致(W_OUT 右侧露旧图 / W_IN 左侧露新图)
  5) 模式隔离:mode=01 时黑幕 FSM 全程不动;mode=00/11 时 trans_mode=0(走硬切)
  6) 中途改模式:必须补 1 个 done 脉冲再回 IDLE(否则 sd 侧会挂到 5s 超时)
  7) trans_state 调试码输出正确
"""

FPS = 60
WIDTH = 640
WIPE_STEP = 16
W_SWITCH_HOLD = 4
WIPE_HOLD_F = 2
FADE_TIMEOUT_FRAMES = 5 * FPS          # sd_card_bmp 的 FADE_TIMEOUT_CYCLES = 5s

W_IDLE, W_ARM, W_OUT, W_BLACK, W_IN, W_HOLD = range(6)
NAME = {W_IDLE: "W_IDLE", W_ARM: "W_ARM", W_OUT: "W_OUT",
        W_BLACK: "W_BLACK", W_IN: "W_IN", W_HOLD: "W_HOLD"}


class Wipe:
    """逐帧推进的 wipe FSM(帧边界 = vs_fall)。"""

    def __init__(self, mode=0b10, req=True):
        self.mode = mode
        self.req = req                 # fs_d1:保持型请求电平
        self.st = W_IDLE
        self.pos = 0
        self.cnt = 0
        self.done = 0                  # 本帧的 done 脉冲

    def mode_wipe(self):
        return self.mode == 0b10

    def step(self):
        """推进一帧(= 一次 vs_fall),返回本帧输出快照。"""
        self.done = 0
        act = (self.st, self.pos)
        if self.st == W_IDLE:
            if self.req and self.mode_wipe():
                self.st, self.pos, self.cnt = W_ARM, 0, 0
        elif self.st == W_ARM:
            if self.cnt >= 1:
                self.st, self.pos, self.cnt = W_OUT, 0, 0
            else:
                self.cnt += 1
        elif self.st == W_OUT:
            if self.pos >= WIDTH - WIPE_STEP:
                self.pos, self.st, self.cnt = WIDTH, W_BLACK, 0
            else:
                self.pos += WIPE_STEP
        elif self.st == W_BLACK:
            if self.cnt == 0:
                self.done = 1
            if self.cnt + 1 >= W_SWITCH_HOLD:
                self.st, self.pos, self.cnt = W_IN, 0, 0
            else:
                self.cnt += 1
        elif self.st == W_IN:
            if self.pos >= WIDTH - WIPE_STEP:
                self.pos, self.st, self.cnt = WIDTH, W_HOLD, 0
            else:
                self.pos += WIPE_STEP
        elif self.st == W_HOLD:
            if self.cnt + 1 >= WIPE_HOLD_F:
                self.st, self.cnt = W_IDLE, 0
            else:
                self.cnt += 1
        # 模式中途变化:先补一个 done 脉冲再回 IDLE
        if self.st != W_IDLE and not self.mode_wipe():
            self.done = 1
            self.st, self.pos, self.cnt = W_IDLE, 0, 0
        return act                       # 帧内恒定的 (state, pos)

    def visible(self, x):
        """该状态下像素 x 是否显示图像(False = 被黑幕遮住)。"""
        if self.st in (W_IDLE, W_ARM):
            return True
        if self.st in (W_OUT, W_BLACK):
            return x >= self.pos
        return x < self.pos              # W_IN / W_HOLD


def trans_state(mode, wipe_st, fade_state=0):
    if mode == 0b10:
        return 0 if wipe_st == W_IDLE else 3 + wipe_st
    return fade_state


def run(mode=0b10, max_frames=400, switch_frame=None, new_mode=None, second_req=None):
    """逐帧跑一遍。

    关键:fs_d1(=sd_card_bmp 的 fade_req)是**保持型电平**,收到 done 脉冲后
    sd_card_bmp 会把它拉低(见 sd_card_bmp 提交块里的 `fade_req <= 1'b0`),
    所以这里在 done 帧把 req 清掉,否则会一直重复触发下一次转场。
    second_req: 在第 N 帧再给一次请求(模拟连按/自动轮播的排队请求)。
    """
    w = Wipe(mode=mode)
    trace = []
    for f in range(max_frames):
        if second_req is not None and f == second_req:
            w.req = True
        if switch_frame is not None and f == switch_frame and new_mode is not None:
            w.mode = new_mode
        act = w.step()
        trace.append((f, act[0], act[1], w.done, trans_state(w.mode, act[0])))
        if w.done:
            w.req = False            # 模拟 sd_card_bmp 收到 done 后释放请求
        if w.st == W_IDLE and f > 4 and not w.req and \
           (second_req is None or f >= second_req):
            break
    return trace, w.st, w.pos       # 帧内轨迹 + 结束时的(状态, wipe_pos)


def main() -> int:
    print("== mode10 横向黑幕擦除 参考模型 ==")
    print("   WIDTH=%d WIPE_STEP=%d(px/帧) W_SWITCH_HOLD=%d WIPE_HOLD_F=%d"
          % (WIDTH, WIPE_STEP, W_SWITCH_HOLD, WIPE_HOLD_F))

    # 1) 正常流程
    tr, fin_st, fin_pos = run()
    states = [t[1] for t in tr]
    seq_ok = (states[0] == W_IDLE and states[1] == W_ARM and fin_st == W_IDLE
              and all(s in states for s in (W_OUT, W_BLACK, W_IN, W_HOLD)))
    print()
    print("-- 1) 状态序列 --")
    print("   %s" % " → ".join(
        [NAME[s] for i, s in enumerate(states) if i == 0 or s != states[i - 1]]
        + [NAME[fin_st]]))
    print("   序列完整(IDLE→ARM→OUT→BLACK→IN→HOLD→IDLE) = %s" % seq_ok)

    # 2) done 脉冲:恰好一次, 且发生在 wipe_pos==640 的整黑帧
    dones = [t[0] for t in tr if t[3]]
    ok_done = (len(dones) == 1)
    dpos = [t[2] for t in tr if t[0] == dones[0]] if ok_done else []
    print()
    print("-- 2) 切缓冲脉冲 --")
    print("   done 脉冲帧 = %s (共 %d 次)" % (dones, len(dones)))
    print("   发生在整黑帧(wipe_pos=%s, 640=全黑) = %s"
          % (dpos[0] if ok_done else "-", ok_done and dpos[0] == WIDTH))

    # 3) 时长 vs 5s 超时
    total = tr[-1][0] + 1
    print()
    print("-- 3) 时长 --")
    print("   总帧数 = %d 帧 ≈ %.2f s;5s 超时阈值 = %d 帧 → 不触发兜底 = %s"
          % (total, total / FPS, FADE_TIMEOUT_FRAMES, total < FADE_TIMEOUT_FRAMES))

    # 4) wipe_pos 只在帧边界变化 → 帧内无撕裂(只在"同一状态连续两帧"之间比较)
    same_state = [(f, states[f - 1], tr[f - 1][2], tr[f][2]) for f in range(1, len(tr))
                  if states[f] == states[f - 1] and states[f] in (W_OUT, W_IN)]
    tear = [x for x in same_state if x[3] - x[2] != WIPE_STEP]
    print()
    print("-- 4) 帧内稳定性 --")
    print("   W_OUT/W_IN 内连续帧的 wipe_pos 增量恒为 +%d(共比对 %d 帧, 无半帧撕裂) = %s"
          % (WIPE_STEP, len(same_state), not tear))

    # 5) 像素级抽查:每帧"可见图像总宽度"应与状态一致
    ok_px = True
    for f, st, pos, _d, _ts in tr:
        w2 = Wipe()
        w2.st, w2.pos = st, pos
        vis = sum(1 for x in range(WIDTH) if w2.visible(x))
        exp = {W_IDLE: WIDTH, W_ARM: WIDTH, W_OUT: WIDTH - pos,
               W_BLACK: 0, W_IN: pos, W_HOLD: WIDTH}[st]
        if vis != exp:
            ok_px = False
            print("   ★ 帧 %d 状态 %s 可见宽 %d ≠ 期望 %d" % (f, NAME[st], vis, exp))
    print()
    print("-- 5) 像素级(W_OUT 右侧露旧图 / W_IN 左侧露新图 / BLACK 全黑) = %s" % ok_px)

    # 6) 模式隔离
    print()
    print("-- 6) 模式隔离 --")
    iso = []
    for m, desc, expect_trans in ((0b01, "淡入淡出", True), (0b00, "硬切", False),
                                  (0b11, "预留", False)):
        t2, _, _ = run(mode=m, max_frames=120)
        stayed = all(s == W_IDLE for _, s, _, _, _ in t2)
        trans = bool(m & 1) ^ bool((m >> 1) & 1)     # trans_mode = sw1 ^ sw2
        iso.append(stayed and trans == expect_trans)
        print("   mode=%s(%s): 黑幕 FSM 全程 IDLE = %s, sd 侧 trans_mode=%s(期望 %s)"
              % (format(m, "02b"), desc, stayed, trans, expect_trans))
    iso_ok = all(iso)

    # 7) 中途改模式
    tr3, fin3, pos3 = run(mode=0b10, switch_frame=30, new_mode=0b00, max_frames=200)
    ab = [t[0] for t in tr3 if t[3]]
    print()
    print("-- 7) 黑幕中途切到硬切(mode 10→00,第 30 帧) --")
    print("   补发的 done 脉冲帧 = %s(恰好 1 次 = %s)" % (ab, len(ab) == 1))
    print("   结束状态 = %s, wipe_pos = %d(归零) = %s"
          % (NAME[fin3], pos3, fin3 == W_IDLE and pos3 == 0))
    abort_ok = (len(ab) == 1 and fin3 == W_IDLE and pos3 == 0)

    # 8) trans_state 调试码
    codes = {W_IDLE: 0, W_ARM: 4, W_OUT: 5, W_BLACK: 6, W_IN: 7, W_HOLD: 8}
    ts_ok = all(t[4] == codes[st] for t, st in zip(tr, states))
    print()
    print("-- 8) 数码管状态码 --")
    print("   %s" % ", ".join("%s=%d" % (NAME[k], v) for k, v in codes.items()))
    print("   实际输出与编码表一致 = %s" % ts_ok)

    # 9) 连续两个请求(自动轮播/连按): 第二次必须从 wipe_pos=0 重新开始,
    #    并且也有且只有一次 done 脉冲(否则 sd_card_bmp 的 req_cnt 会对不上)
    tr9, fin9, _ = run(mode=0b10, second_req=100, max_frames=400)
    d9 = [t[0] for t in tr9 if t[3]]
    gap9 = (d9[1] - d9[0]) if len(d9) == 2 else -1
    second_ok = len(d9) == 2 and gap9 >= 86
    print()
    print("-- 9) 连续两次请求(第 100 帧再给一次) --")
    print("   done 脉冲帧 = %s(2 次 = %s, 间隔 %d 帧)" % (d9, len(d9) == 2, gap9))
    print("   第二次从 wipe_pos=0 重新擦除、互不干扰 = %s" % second_ok)

    ok = seq_ok and ok_done and total < FADE_TIMEOUT_FRAMES and not tear \
        and ok_px and iso_ok and abort_ok and ts_ok and second_ok
    print()
    print("结论: %s" % ("通过" if ok else "不通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
