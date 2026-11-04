#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自动轮播"停止不及时"参考模型（与 sd_card_bmp.v 当前实现逐条对齐）。

现象:
  SW1=1(淡入淡出)下按 key2 停止自动轮播后, 图片仍继续切换约 2 张才停。

根因(模型要复现的三件事):
  1) auto_play_en 只门控 auto_tick 的"汇入"(req_cnt++), 不控制已排队的存量;
  2) 排队速度 1 个 / 60 帧(1s), 消化速度 1 个 / 73 帧(≈1.22s) —— 一次完整转场
     比 tick 周期长, 于是 req_cnt 缓慢积压(上限 7);
  3) key2 关闭时 RTL 只清 auto_cnt, 不清 req_cnt → 存量请求继续逐个执行。

本模型验证四件事:
  A) 排队速度 > 消化速度 → req_cnt 单调积压(复现现象, 与轮播时长成正比)
  B) 停止不及时的张数 = OFF 时刻的 req_cnt(改动前)
  C) 方案 B(关闭当拍 req_cnt<=0)后, 停止后剩余切换数 ≤ 1
     —— 恰在转场前半段(缓冲未翻)按停止 = 再切 1 张; 后半段按 = 0 张(已提交)
  D) 方案 B 不影响在途转场的收尾(FSM 仍能正常回 IDLE, 不残留)

说明:
  * 时间以"帧"为单位(60Hz): 1s = 60 帧; 一次完整转场 = 73 帧
    (ARM 2 + 变暗 32 + 全黑帧发 fade_done + SWAP_WAIT 4 + 变亮 32 + HOLD 3),
    与 fade_ref_check.py 的时长结论一致。
  * 提交(切图)发生在 fade_done 那一帧(全黑), 不是转场结束那一帧 —— 这是
    "在途转场会被切完"的直接原因。
  * 预取延时 PREFETCH_FRAMES 模拟 SD 读卡+整帧写入, 只影响节拍不影响结论,
    脚本末尾对 5/10/30 帧做敏感性检查。
"""

FPS = 60                      # 视频帧率
TICK_FRAMES = 1 * FPS         # auto_cnt 定时器: 1s
REQ_CNT_MAX = 7               # req_cnt 饱和上限(sd_card_bmp: 3 位饱和)
FADE_TOTAL_FRAMES = 73        # 一次完整转场(ARM→HOLD)
FADE_DONE_FRAME = 35          # 第 35 帧 = 全黑帧, 发 fade_done → 提交切图
SWAP_WAIT_FRAMES = 4
HOLD_FRAMES = 3
PREFETCH_FRAMES = 10          # 预取耗时(提交后到 pfb_valid 拉高)


def simulate(total_frames, stop_frame=None, fix_b=False, prefetch=PREFETCH_FRAMES):
    """按 RTL 语义逐帧推进, 返回统计结果。

    stop_frame=None 表示全程自动轮播; 否则在该帧模拟按下 key2 关闭。
    fix_b=True 复现"方案 B": 关闭当拍 req_cnt 清零(不动 fade_req/fade_pending)。
    """
    auto_en = 1
    auto_cnt = 0
    req_cnt = 0
    fade_pending = 0
    fsm = "IDLE"              # IDLE / ARM / RUN_OUT / RUN_IN / HOLD
    fsm_cnt = 0
    pfb_valid = 1
    prefetch_left = 0

    commits = []              # 每次切图的帧号
    req_at_stop = None
    paused_at_stop = None

    for f in range(total_frames):
        # ---- key2 关闭(方案 B 在此清 req_cnt) ----
        if stop_frame is not None and f == stop_frame and auto_en:
            auto_en = 0
            auto_cnt = 0
            req_at_stop = req_cnt
            paused_at_stop = 1 if fade_pending else 0
            if fix_b:
                req_cnt = 0

        # ---- 定时器: 仅 auto_play_en=1 时计数 ----
        if auto_en:
            auto_cnt += 1
            if auto_cnt >= TICK_FRAMES:
                auto_cnt = 0
                if req_cnt < REQ_CNT_MAX:
                    req_cnt += 1

        # ---- 预取 ----
        if not pfb_valid:
            if prefetch_left > 0:
                prefetch_left -= 1
            else:
                pfb_valid = 1

        # ---- 转场请求(保持型, 对应 RTL L363):
        #      req_cnt≠0 && pfb_valid && !fade_pending → fade_req=1 并保持
        #      (RTL 里 fade_req 在整个转场期间一直为 1, 直到 fade_done 才拉低,
        #       所以"有未提交的在途请求"与 fade_pending=1 完全等价) ---
        if req_cnt > 0 and pfb_valid and not fade_pending:
            fade_pending = 1

        # ---- osd FSM 只在 IDLE 采样请求电平(fs_d1);
        #      转场期间(ARM/RUN/HOLD)即使 fade_req 已重新拉高也不理会 ---
        if fsm == "IDLE" and fade_pending:
            fsm = "ARM"
            fsm_cnt = 0

        # ---- 转场推进(每帧一步) ----
        if fsm == "ARM":
            fsm_cnt += 1
            if fsm_cnt >= 2:
                fsm = "RUN_OUT"
                fsm_cnt = 0
        elif fsm == "RUN_OUT":
            fsm_cnt += 1
            if fsm_cnt >= FADE_DONE_FRAME - 2:        # 到达全黑帧
                commits.append(f)                     # ★ 提交切图, 缓冲翻转
                req_cnt = max(0, req_cnt - 1)
                fade_pending = 0
                pfb_valid = 0
                prefetch_left = prefetch
                fsm = "RUN_IN"
                fsm_cnt = 0
        elif fsm == "RUN_IN":
            fsm_cnt += 1
            if fsm_cnt >= SWAP_WAIT_FRAMES + 32:
                fsm = "HOLD"
                fsm_cnt = 0
        elif fsm == "HOLD":
            fsm_cnt += 1
            if fsm_cnt >= HOLD_FRAMES:
                fsm = "IDLE"
                fsm_cnt = 0

    return {
        "req_cnt": req_cnt,
        "fade_pending": fade_pending,
        "fsm": fsm,
        "commits": commits,
        "req_at_stop": req_at_stop,
        "paused_at_stop": paused_at_stop,
    }


def after_stop_commits(res, stop_frame):
    return [f for f in res["commits"] if f >= stop_frame]


def check_buildup() -> bool:
    print("-- A) 复现现象: 排队 1 个/60 帧, 消化 1 个/73 帧 → req_cnt 积压 --")
    ok = True
    rows = []
    for sec in (10, 20, 30, 40, 60):
        r = simulate(sec * FPS)
        rows.append((sec, r["req_cnt"], len(r["commits"])))
        print("   轮播 %2d s: 已切 %2d 张, 停止时刻队列存量 req_cnt = %d"
              % (sec, len(r["commits"]), r["req_cnt"]))
    growth = rows[-1][1] >= rows[0][1]
    capped = all(v <= REQ_CNT_MAX for _, v, _ in rows)
    print("   队列随时长单调增长 = %s; 未超过饱和上限 %d = %s"
          % (growth, REQ_CNT_MAX, capped))
    ok = growth and capped and rows[-1][1] > 0
    return ok


def check_before_fix() -> bool:
    print()
    print("-- B) 改动前: 停止后仍会执行 req_cnt 张存量请求 --")
    ok = True
    for sec in (10, 20, 30, 40):
        stop = sec * FPS
        r = simulate(stop + 40 * FPS, stop_frame=stop, fix_b=False)
        extra = after_stop_commits(r, stop)
        print("   第 %2d s 按 key2 停止: 存量 req_cnt = %d → 停止后又切 %d 张"
              % (sec, r["req_at_stop"], len(extra)))
        if len(extra) != r["req_at_stop"]:
            ok = False
    print("   \"停止后切图张数 == 存量 req_cnt\" = %s" % ok)
    return ok


def check_fix_b() -> bool:
    print()
    print("-- C) 方案 B: 关闭当拍 req_cnt<=0 → 停止后剩余切换 ≤ 1 张 --")
    ok = True
    worst = 0
    for sec in range(1, 61):
        stop = sec * FPS
        r = simulate(stop + 40 * FPS, stop_frame=stop, fix_b=True)
        extra = after_stop_commits(r, stop)
        worst = max(worst, len(extra))
        if len(extra) > 1:
            ok = False
            print("   ★ 第 %d s 停止后仍切了 %d 张(超过 1)" % (sec, len(extra)))
    print("   1~60 s 逐秒抽样: 停止后剩余切换张数最大值 = %d (≤1 = %s)"
          % (worst, ok))
    # 区分两种情形
    r1 = None
    for sec in range(1, 61):
        stop = sec * FPS
        r = simulate(stop + 40 * FPS, stop_frame=stop, fix_b=True)
        if len(after_stop_commits(r, stop)) == 1:
            r1 = sec
            break
    if r1 is not None:
        stop = r1 * FPS
        r = simulate(stop + 40 * FPS, stop_frame=stop, fix_b=True)
        print("   例: 第 %d s 停止(在途转场前半段, fade_pending=1) → 再切 1 张后停住"
              % r1)
        print("       该张来自\"在途转场走完全黑帧\", 方案 B 有意保留;")
        print("       若需连这一张也不切(屏幕在全黑帧后淡回当前图), 见方案 A(未采用)。")
    print("   FSM 停止后能正常回到 IDLE(无残留) = %s"
          % all(simulate(s * FPS + 40 * FPS, stop_frame=s * FPS, fix_b=True)["fsm"] == "IDLE"
                for s in range(1, 61)))
    ok = ok and all(simulate(s * FPS + 40 * FPS, stop_frame=s * FPS,
                             fix_b=True)["fsm"] == "IDLE" for s in range(1, 61))
    return ok


def check_prefetch_sensitivity() -> bool:
    print()
    print("-- D) 预取耗时敏感性: 结论不随 SD 读卡快慢变化 --")
    ok = True
    for p in (5, 10, 30):
        worst = 0
        for sec in (10, 20, 30, 40):
            stop = sec * FPS
            r = simulate(stop + 60 * FPS, stop_frame=stop, fix_b=True, prefetch=p)
            worst = max(worst, len(after_stop_commits(r, stop)))
        print("   预取 %2d 帧: 停止后剩余切换张数最大值 = %d" % (p, worst))
        ok = ok and worst <= 1
    return ok


def main() -> int:
    print("== 自动轮播停止不及时 参考模型(帧单位, 60Hz) ==")
    print("   1 s = 60 帧; 一次完整转场 = %d 帧 ≈ %.2f s; 提交(切图)在第 %d 帧"
          % (FADE_TOTAL_FRAMES, FADE_TOTAL_FRAMES / FPS, FADE_DONE_FRAME))
    print()
    a = check_buildup()
    b = check_before_fix()
    c = check_fix_b()
    d = check_prefetch_sensitivity()
    ok = a and b and c and d
    print()
    print("结论:")
    print("   队列积压可复现(根因)          = %s" % a)
    print("   改动前停止后多切 req_cnt 张    = %s" % b)
    print("   方案 B 后剩余切换 ≤ 1 张       = %s" % c)
    print("   结论不随预取快慢变化          = %s" % d)
    print("   总结: %s" % ("通过" if ok else "不通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
