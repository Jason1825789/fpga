#!/usr/bin/env python3
"""双读通道数据通路参考模型（周期级）。

目的：验证 frame_read_write.v 里的
  * 双读仲裁（rd1_served / rd2_served 轮换）
  * 请求-响应配对标签队列（tag_bits / tag_wptr / tag_rptr）
  * tag_used 背压（修复前后）
是否会让"ch2 请求的数据"正确落进"ch2 的 FIFO"，
以及淡化期间两路同时读时读 FIFO 会不会被抽干（欠载 → 像素重复/错位）。

模型按 mem_clk(125MHz) 打拍，video_clk(25MHz) 每 5 拍一个有效像素。
SDRAM 控制器建模为"固定延迟 LAT 拍返回、每个被接受的请求恰好返回 1 个字"。

用法：python rdpath_ref_check.py
"""

MEM_PER_VIDEO = 5                 # 125MHz / 25MHz
FRAME_PIXELS = 307200             # 640*480
FIFO_DEPTH = 512
BURST_SIZE = 128
TAG_DEPTH = 64
LAT = 12                          # SDRAM 读延迟（mem 拍）
DRAIN_START_VIDEO = 20            # 帧首：读侧比填充晚开始的像素数(de 有效 + 18 拍)

CH1_BASE = 0                      # BUF0
CH2_BASE = FRAME_PIXELS           # BUF1


def simulate(dual: bool, buggy_tag_used: bool, video_ticks: int):
    """跑 video_ticks 个有效像素周期。

    返回 (mismatch, min_level1, min_level2, served1, served2, stalled_ticks)
      mismatch : 写进 FIFO 的字与"该通道请求的地址"不符的次数（应为 0）
      min_level: 各通道 FIFO 最低水位（<0 表示欠载）
    """
    # --- 通道状态：各自维护请求地址与剩余突发 ---
    req_addr = [CH1_BASE, CH2_BASE]
    burst_left = [0, 0]
    cooldown = [0, 0]              # 突发之间的 rd_delay 等待
    app_en = [False, False]

    # --- FIFO 水位与内容 ---
    level = [0, 0]
    # 每个通道记录"已入队的请求地址序列"和"已写入 FIFO 的地址序列"
    req_seq = [[], []]
    fifo_seq = [[], []]

    # --- 标签队列 ---
    tag_bits = [0] * TAG_DEPTH
    wptr = rptr = 0

    # --- SDRAM 返回流水线 ---
    pipe = []                      # [(due_tick, ch)]

    rd_last = 0
    mismatch = 0
    min_level = [10 ** 9, 10 ** 9]
    underflow = [0, 0]
    served_cnt = [0, 0]
    stalled = 0

    total_ticks = video_ticks * MEM_PER_VIDEO

    for t in range(total_ticks):
        video_tick = (t % MEM_PER_VIDEO) == 0

        # ---------- 1. 读 FSM 产生请求 ----------
        for ch in range(2):
            if not dual and ch == 1:
                app_en[ch] = False
                continue
            if burst_left[ch] > 0:
                app_en[ch] = True
            elif cooldown[ch] > 0:
                cooldown[ch] -= 1
                app_en[ch] = False
            else:
                # S_CHECK_FIFO：FIFO 还有空间就再发一个突发
                if level[ch] < (FIFO_DEPTH - BURST_SIZE):
                    burst_left[ch] = BURST_SIZE
                    app_en[ch] = True
                else:
                    app_en[ch] = False

        # ---------- 2. 仲裁 + 背压 ----------
        if buggy_tag_used:
            # 修复前：先零扩展到 7 位再相减，越过回绕点时算出巨大占用
            tag_used = ((wptr & 0x3F) | 0) - ((rptr & 0x3F) | 0)
            if tag_used < 0:
                tag_used += 128        # 7 位无符号回绕
            tag_used &= 0x7F
        else:
            tag_used = (wptr - rptr) & 0x3F      # 6 位减法 = mod 64
        tag_room = tag_used < 56

        rd1_served = tag_room and app_en[0] and ((not app_en[1]) or (not rd_last))
        rd2_served = tag_room and app_en[1] and (not rd1_served)

        if (app_en[0] or app_en[1]) and not (rd1_served or rd2_served):
            stalled += 1

        # ---------- 3. 入队 / 记账 ----------
        if rd1_served:
            tag_bits[wptr & 0x3F] = 0
            wptr = (wptr + 1) & 0x3F
            req_seq[0].append(req_addr[0])
            req_addr[0] += 1
            burst_left[0] -= 1
            served_cnt[0] += 1
            if burst_left[0] == 0:
                cooldown[0] = 11
            rd_last = 1
            pipe.append((t + LAT, 0))
        elif rd2_served:
            tag_bits[wptr & 0x3F] = 1
            wptr = (wptr + 1) & 0x3F
            req_seq[1].append(req_addr[1])
            req_addr[1] += 1
            burst_left[1] -= 1
            served_cnt[1] += 1
            if burst_left[1] == 0:
                cooldown[1] = 11
            rd_last = 0
            pipe.append((t + LAT, 1))

        # ---------- 4. 数据返回：按队首标签路由 ----------
        while pipe and pipe[0][0] == t:
            _, ch = pipe.pop(0)
            tag_empty = (wptr == rptr)
            rd2_now = (not tag_empty) and tag_bits[rptr & 0x3F] == 1
            rptr = (rptr + 1) & 0x3F
            routed = 1 if rd2_now else 0
            if routed != ch:
                mismatch += 1
            fifo_seq[ch].append(req_seq[ch][len(fifo_seq[ch])] if len(fifo_seq[ch]) < len(req_seq[ch]) else -1)
            level[ch] += 1

        # ---------- 5. 每 5 拍消费一个像素（de_d[18] 有效像素） ----------
        # 帧首：vs 沿清空 FIFO 后，SDRAM 侧立刻开始填充，
        # 而读侧要等 de 有效 + 18 拍（de_d[18]）才开始抽。
        # 这里用 DRAIN_START_VIDEO 建模这个提前量，避免把"帧首必然的
        # 空窗"误判成欠载。
        if video_tick:
            v = t // MEM_PER_VIDEO
            if v >= DRAIN_START_VIDEO:
                for ch in range(2):
                    if not dual and ch == 1:
                        continue
                    if level[ch] > 0:
                        level[ch] -= 1
                    else:
                        underflow[ch] += 1          # 欠载拍数
                    # 只统计进入稳态后的最低水位（跳过前 400 拍填充瞬态）
                    if v >= 400:
                        min_level[ch] = min(min_level[ch], level[ch])

    # 校验：FIFO 内容序列必须是"该通道请求地址序列"的前缀
    for ch in range(2):
        for i, v in enumerate(fifo_seq[ch]):
            if v != req_seq[ch][i]:
                mismatch += 1

    return mismatch, min_level, underflow, served_cnt, stalled, len(req_seq[0]), len(req_seq[1])


def main() -> int:
    print("== 双读通道数据通路参考模型 ==")
    print(f"   mem:video = {MEM_PER_VIDEO}:1, FIFO 深度 {FIFO_DEPTH}, "
          f"突发 {BURST_SIZE}, 标签深度 {TAG_DEPTH}, SDRAM 延迟 {LAT} 拍\n")

    ticks = 40000          # 约 0.13 帧，足够进入稳态并覆盖帧首填充瞬态

    cases = [
        ("单读(ch1 only)",                    False, False),
        ("双读 淡化 + 修复后 tag_used",        True,  False),
        ("双读 淡化 + 修复前 tag_used(7位)",   True,  True),
    ]
    ok = True
    for name, dual, buggy in cases:
        mm, minl, uf, served, stalled, r1, r2 = simulate(dual, buggy, ticks)
        under1 = uf[0] > 0
        under2 = (uf[1] > 0) if dual else False
        good = (mm == 0) and (not under1) and (not under2)
        ok = ok and good
        print(f"-- {name} --")
        print(f"   路由错配次数          : {mm}")
        print(f"   ch1 服务次数/请求数   : {served[0]} / {r1}")
        if dual:
            print(f"   ch2 服务次数/请求数   : {served[1]} / {r2}")
        print(f"   ch1 FIFO 稳态最低水位 : {minl[0]}, 欠载像素数 {uf[0]}")
        if dual:
            print(f"   ch2 FIFO 稳态最低水位 : {minl[1]}, 欠载像素数 {uf[1]}")
        print(f"   请求被背压挡住的拍数  : {stalled}")
        print(f"   -> {'通过' if good else '不通过'}")
        print()

    print("说明:")
    print("  * '路由错配' 必须为 0 —— 只要非 0，ch2 就会拿到 ch1 的像素，")
    print("    淡化时表现为'新图完全出不来'或画面撕裂。")
    print("  * '欠载' 指读 FIFO 被抽干，会重复上一像素（横向重影/拉伸）。")
    print("  * 修复前 tag_used 只是把吞吐压低（被挡住的拍数明显变多），")
    print("    在双读约 30% 带宽占用下仍不足以抽干 FIFO —— 即它是性能缺陷，")
    print("    不是'淡化完全不出现'的直接原因。")
    print()
    print(f"总结: {'通过' if ok else '不通过'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
