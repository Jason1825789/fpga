#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""render_seg_preview.py — 按真实段码渲染数码管"播放进度"视图

段码约定与 fpga 端完全一致（与 seg_decoder.v 对照）：
    7 位，bit0=a, bit1=b, bit2=c, bit3=d, bit4=e, bit5=f, bit6=g
    **0 = 点亮**（共阳/低有效）
        a
      f   b
        g
      e   c
        d
本脚本只是把即将上板的段码画出来，不参与综合。
"""
from PIL import Image, ImageDraw

# 与 seg_decoder.v 完全相同的表
SEG_TABLE = {
    0: 0b100_0000, 1: 0b111_1001, 2: 0b010_0100, 3: 0b011_0000,
    4: 0b001_1001, 5: 0b001_0010, 6: 0b000_0010, 7: 0b111_1000,
    8: 0b000_0000, 9: 0b001_0000,
}
SEG_DASH  = 0b011_1111
SEG_BLANK = 0b111_1111


def seg_codes(img_idx, total):
    """复现 seg_progress_view 的 6 路段码（第3~8位，左→右）。"""
    cur = img_idx + 1
    zeros = cur // 10          # 恒 0
    ones = cur % 10
    t_tens = total // 10       # 恒 0
    t_ones = total % 10
    return [
        SEG_TABLE[zeros],      # 第3位 当前张号十位
        SEG_TABLE[ones],       # 第4位 当前张号个位
        SEG_DASH,              # 第5位 '-'
        SEG_TABLE[t_tens],     # 第6位 总张数十位
        SEG_TABLE[t_ones],     # 第7位 总张数个位
        SEG_BLANK,             # 第8位 留空
    ]


def draw_digit(d, x, y, w, h, t, code, on=(255, 48, 48), off=(38, 16, 16)):
    """画一位七段数码管。code 里 0 = 点亮。"""
    def lit(i):
        return ((code >> i) & 1) == 0

    m = t // 2                       # 斜角切量
    hy = h // 2
    # 水平段：a 顶, g 中, d 底
    seg_a = [(x + m, y), (x + w - m, y)]
    seg_g = [(x + m, y + hy), (x + w - m, y + hy)]
    seg_d = [(x + m, y + h), (x + w - m, y + h)]
    # 竖段：f 左上, b 右上, e 左下, c 右下
    seg_f = [(x, y + m), (x, y + hy - m)]
    seg_b = [(x + w, y + m), (x + w, y + hy - m)]
    seg_e = [(x, y + hy + m), (x, y + h - m)]
    seg_c = [(x + w, y + hy + m), (x + w, y + h - m)]

    pairs = [(0, seg_a), (1, seg_b), (2, seg_c), (3, seg_d),
             (4, seg_e), (5, seg_f), (6, seg_g)]
    for idx, (p0, p1) in pairs:
        col = on if lit(idx) else off
        d.line([p0, p1], fill=col, width=t)
        for p in (p0, p1):
            d.ellipse([p[0] - t // 2, p[1] - t // 2,
                       p[0] + t // 2, p[1] + t // 2], fill=col)


def render(rows, out_png):
    DIG_W, DIG_H, THICK, GAP = 58, 108, 10, 30
    PAD, LBL_H, IDX_H, ROW_H = 34, 30, 26, 190
    W = PAD * 2 + 6 * DIG_W + 5 * GAP
    H = PAD * 2 + len(rows) * ROW_H
    im = Image.new("RGB", (W, H), (16, 16, 16))
    d = ImageDraw.Draw(im)

    from PIL import ImageFont
    try:
        f = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 14)
    except Exception:
        f = ImageFont.load_default()

    for r, (label, codes) in enumerate(rows):
        y0 = PAD + r * ROW_H
        d.text((PAD, y0), label, font=f, fill=(180, 180, 180))
        for i, code in enumerate(codes):
            x = PAD + i * (DIG_W + GAP)
            draw_digit(d, x, y0 + LBL_H, DIG_W, DIG_H, THICK, code)
            # 位号标注：物理第 3~8 位
            d.text((x + DIG_W // 2 - 10, y0 + LBL_H + DIG_H + 6),
                   "D%d" % (i + 3), font=f, fill=(120, 200, 120))

    im.save(out_png)
    return out_png


if __name__ == "__main__":
    rows = [
        ("开机扫描中 / 第1张 (img_idx=0, total=0→8)",  seg_codes(0, 0)),
        ("第1张 / 共8张 (img_idx=0)",                  seg_codes(0, 8)),
        ("第3张 / 共8张 (img_idx=2)",                  seg_codes(2, 8)),
        ("第8张 / 共8张 (img_idx=7)",                  seg_codes(7, 8)),
    ]
    p = render(rows, r"E:\workbuddy\6\doc\seg_progress_preview.png")
    print("已输出", p)
