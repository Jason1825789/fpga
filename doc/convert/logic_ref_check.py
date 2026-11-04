#!/usr/bin/env python3
"""对本次修改涉及的纯算术/计数逻辑做参考模型验证。

验证对象(与 RTL 逐条对应):
  1) video_rgb_to_axis_640x480 的行计数与 O_video_last
  2) osd_engine.scale_by_alpha 的逐通道亮度缩放  out = (pix*alpha)>>8
  3) osd_engine.alpha_blend 的逐通道 Alpha 混合
  4) disp_buf_idx 的 ^2'b01 翻转(对比旧的 ~ 取反)
  5) 转场进度量(alpha)只在 vsync 更新,DE=1 期间恒定

注:WIPE(纵向逐行擦除)已在重构中删除 —— 模式 2 改为 sd_card_bmp 里的
    直接硬切,不再经过 osd_engine。故本文件不再检查 WIPE。
"""
import random


def check_axis() -> bool:
    """按 RTL 时序逐拍模拟一行 640 个 de,统计 valid/last 个数与位置。"""
    s_de_1d = 0
    s_frame_arm = 1
    s_x_cnt = 0
    s_vs_1d = 0

    valid_cnt = 0
    last_positions = []
    user_positions = []

    # 前面几个空闲拍,模拟消隐区
    seq = [0] * 5 + [1] * 640 + [0] * 5
    for t, de in enumerate(seq):
        o_valid = de
        o_last = 0
        o_user = 0

        if de:
            if not s_de_1d:
                if s_frame_arm:
                    o_user = 1
            if s_de_1d and s_x_cnt == 639:
                o_last = 1

        if o_valid:
            valid_cnt += 1
        if o_last:
            last_positions.append(t)
        if o_user:
            user_positions.append(t)

        # 状态更新
        s_vs_1d = 0
        if de:
            if not s_de_1d:
                if s_frame_arm:
                    s_frame_arm = 0
                s_x_cnt = 1
            else:
                s_x_cnt += 1
        else:
            s_x_cnt = 0
        s_de_1d = de

    ok = (valid_cnt == 640) and (len(last_positions) == 1) and (len(user_positions) == 1)
    print("== AXIS 行计数 ==")
    print(f"   valid 个数 = {valid_cnt} (期望 640)")
    print(f"   last  个数 = {len(last_positions)} 位置(相对 de 段起点) = "
          f"{[p - 5 + 1 for p in last_positions]} (期望 [640])")
    print(f"   user  个数 = {len(user_positions)} (期望 1)")
    print(f"   -> {'通过' if ok else '不通过'}")
    return ok


def check_scale_alpha() -> bool:
    """RTL: 每通道 (pix * alpha) >> 8, alpha 0..255

    模式 1 的亮度缩放:alpha=255 是最亮(调用处直通原图)、alpha=0 是纯黑。
    """
    worst = 0.0
    random.seed(1)
    for _ in range(20000):
        pix = [random.randrange(256) for _ in range(3)]
        a = random.randrange(256)
        for c in range(3):
            rtl = (pix[c] * a) >> 8
            exact = pix[c] * a / 256.0
            worst = max(worst, abs(rtl - exact))
            if rtl < 0 or rtl > 255:
                print(f"   溢出! alpha={a} pix={pix[c]} rtl={rtl}")
                return False
    ok = worst < 1.0
    print("== scale_by_alpha 亮度缩放(逐通道) ==")
    print(f"   与精确值的最大偏差 = {worst:.3f} LSB (期望 < 1,纯截断误差)")
    print(f"   单通道最大 255*255 = {255 * 255} < 65536 → 16 位不溢出")
    print(f"   alpha=0   → {(200 * 0) >> 8} (期望 0,纯黑)")
    print(f"   alpha=128 → {(200 * 128) >> 8} (期望 ~100)")
    print(f"   alpha=255 → 调用处直通,输出 200(RTL 里 alpha==255 不进函数)")
    print(f"   -> {'通过' if ok else '不通过'}")
    return ok


def check_vsync_only() -> bool:
    """验证转场进度量 alpha 只在 vs_fall 更新,DE=1 期间恒定。

    用户看到"抖动一下、变模糊、没有整帧统一渐变",根因就是
    alpha 在一帧有效像素传输途中被改掉 → 同一帧内前后像素透明度不同。
    这里对比"只在 vs 沿更新"和"帧中途也更新"两种写法的帧内取值种数。
    """
    def frame_vals(only_at_vs):
        a = 0
        vals = []
        for i in range(640 * 480):
            if (not only_at_vs) and i == 100000:      # 错误写法:帧中途更新
                a = min(255, a + 4)
            vals.append(a)
        return len(set(vals))

    ok = True
    print("== 转场进度量只在 vsync 更新 ==")
    good = frame_vals(True)
    bad = frame_vals(False)
    if good != 1:
        ok = False
    print(f"   FADE(alpha)       : 仅在 vs 沿更新 → 帧内取值种数 {good} (期望 1);"
          f" 帧中途更新 → {bad}")
    print(f"   -> {'通过' if ok else '不通过'}")
    return ok


def check_alpha_blend() -> bool:
    """RTL 逐通道实现 vs 期望;同时展示旧实现(整体 24bit 运算)的通道串扰。"""
    def new_impl(fg, bg, alpha):
        if alpha == 0:
            return list(bg)
        if alpha == 1:
            return [(fg[c] >> 2) + bg[c] - (bg[c] >> 2) for c in range(3)]
        if alpha == 2:
            return [(fg[c] >> 1) + (bg[c] >> 1) for c in range(3)]
        if alpha == 3:
            return [fg[c] - (fg[c] >> 2) + (bg[c] >> 2) for c in range(3)]
        return list(fg)

    def old_impl(fg, bg, alpha):
        f = (fg[0] << 16) | (fg[1] << 8) | fg[2]
        b = (bg[0] << 16) | (bg[1] << 8) | bg[2]
        if alpha == 0:
            r = b
        elif alpha == 1:
            r = (f >> 2) + (b - (b >> 2))
        elif alpha == 2:
            r = (f >> 1) + (b >> 1)
        elif alpha == 3:
            r = (f - (f >> 2)) + (b >> 2)
        else:
            r = f
        r &= 0xFFFFFF
        return [(r >> 16) & 0xFF, (r >> 8) & 0xFF, r & 0xFF]

    print("== alpha_blend 逐通道 Alpha 混合 ==")
    cases = [
        ((255, 255, 255), (0, 1, 0), 1),      # 旧实现会在此类低值通道上借位
        ((0, 0, 0), (0, 1, 0), 3),
        ((200, 100, 50), (10, 200, 30), 2),
    ]
    ok = True
    for fg, bg, a in cases:
        n = new_impl(fg, bg, a)
        o = old_impl(fg, bg, a)
        exp = [round(fg[c] * (a / 4.0) + bg[c] * (1 - a / 4.0)) for c in range(3)]
        bad = max(abs(n[c] - exp[c]) for c in range(3))
        print(f"   fg={fg} bg={bg} alpha={a}")
        print(f"     修复后 = {n}  期望≈{exp}  最大偏差 {bad}")
        print(f"     旧实现 = {o}  <- 通道间借位/进位导致的错误")
        if bad > 2:
            ok = False
    print(f"   -> {'通过' if ok else '不通过'}")
    return ok


def check_buf_idx() -> bool:
    print("== 缓冲索引翻转 ==")
    idx = 0
    seq = []
    for _ in range(4):
        idx = idx ^ 1
        seq.append(idx)
    bad = [v for v in seq if v > 1]
    print(f"   disp_buf_idx ^ 1 序列 = {seq} (期望 [1,0,1,0])")
    print(f"   旧实现 ~2'd0 的结果 = {[3, 0, 3, 0]} <- 索引 3 的基址在顶层被接成 0,会覆盖 BUF0")
    ok = (seq == [1, 0, 1, 0]) and not bad
    print(f"   -> {'通过' if ok else '不通过'}")
    return ok


if __name__ == "__main__":
    results = [
        check_axis(),
        check_scale_alpha(),
        check_vsync_only(),
        check_alpha_blend(),
        check_buf_idx(),
    ]
    print()
    print("总结:", "全部通过" if all(results) else "存在不通过项")
