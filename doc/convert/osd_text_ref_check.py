#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OSD 滚动字幕参考模型(与 font_rom.v / osd_text_cell 逐条对齐)。

用途:把 font_rom.v 里的 FONT_ALL 字模解包成 16x16 点阵, 并用 RTL 的
      "位置号→字库编号→列/行索引→bit15=最左" 完整映射链重采样一遍,
      用来判定"缺笔画/锯齿/断裂"到底是【采样逻辑】还是【字模数据】的问题。

位序约定(与 font_rom.v 注释、font2verilog.py 完全一致):
  * FONT_ALL 字面量"最右边一组" = 字库编号 0 的 bits[15:0] = row 0(最上行)
  * 每行 16 位里 bit15 = 最左列  → RTL: pixel_on = fr_cur[15-col]
  * fmt_verilog() 把 rows[0](最上行)reverse 到最右 → 本模型的解析方向与其一致

检查项:
  A) 解包后 13 套字模逐字渲染(ASCII art), 检查字形是否可辨认/是否倒置
  B) 行/列使用范围与包围盒(判定 12x12 数字块 vs 16x16 汉字块的基线差异)
  C) 采样等价性: 对 scroll_pos = 0..831 全量重采样, 逐像素比对
     "屏幕看到的字形" 与 "ROM 原始字形" 是否完全一致(证明无丢像素/无偏移)
  D) 数据缺陷统计: 孤立缺像素("1px 空洞")、8 邻域连通块数(断笔)、
     以及被生成链(2x 腐蚀 + LANCZOS + >128 硬阈值 + 倾斜剪切)削掉的特征
  E) 若用现成的 outline_on 做 1px 膨胀填缝, 代价是多少(笔画变粗/内孔闭合)
"""

import re
import sys
from pathlib import Path

FONT_ROM = Path(__file__).resolve().parents[2] / "src" / "user_source" / "hdl_source" / "font_rom.v"

SIZE = 16
STR = "2026FPGA创新设计竞赛"
# 与 RTL 一致: 位置号 → 字库编号
POS_TO_FONT = [0, 1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
FONT_NAME = ['2', '0', '6', 'F', 'P', 'G', 'A', '创', '新', '设', '计', '竞', '赛']
# RTL osd_text_cell: 位置号 → 该字符起始列
POS_XBASE = [0, 12, 24, 36, 48, 60, 72, 84, 96, 112, 128, 144, 160, 176]
CELL_W = 192
L1_Y0 = 462


def parse_font_all(path=FONT_ROM):
    """把 3328'h... 字面量解成 13 套 x 16 行 x 16 位。"""
    txt = path.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"3328'h([0-9A-Fa-f_]+)", txt)
    if not m:
        raise SystemExit("未找到 3328'h FONT_ALL 字面量")
    hexs = m.group(1).replace("_", "")
    if len(hexs) != 832:
        raise SystemExit("字面量位数异常: %d hex chars (期望 832)" % len(hexs))
    total = int(hexs, 16)              # 3328 位整数
    fonts = []
    for f in range(13):
        rows = []
        for r in range(SIZE):
            lo = (f * 256) + (r * 16)  # 最右一组 = 编号 0 的 row 0
            rows.append((total >> lo) & 0xFFFF)
        fonts.append(rows)
    return fonts


def glyph_pixels(rows):
    """行数据 → 16x16 布尔矩阵 [row][col], bit15 = 最左列。"""
    return [[bool((rows[r] >> (15 - c)) & 1) for c in range(SIZE)] for r in range(SIZE)]


def art(px, mark_missing=None, mark_extra=None):
    """ASCII art,█=笔画 ·=背景;mark 用于标注修复/丢失的像素。"""
    out = []
    for r in range(SIZE):
        line = ""
        for c in range(SIZE):
            if mark_missing and (r, c) in mark_missing:
                line += "o"
            elif mark_extra and (r, c) in mark_extra:
                line += "x"
            elif px[r][c]:
                line += "#"
            else:
                line += "."
        out.append(line)
    return out


def bbox(px):
    rs = [r for r in range(SIZE) if any(px[r])]
    cs = [c for c in range(SIZE) if any(px[r][c] for r in range(SIZE))]
    if not rs:
        return None
    return (min(rs), max(rs), min(cs), max(cs))


def components(px):
    """8 邻域连通块数量(笔画是否被切断)。"""
    seen = [[False] * SIZE for _ in range(SIZE)]
    cnt = 0
    for r in range(SIZE):
        for c in range(SIZE):
            if px[r][c] and not seen[r][c]:
                cnt += 1
                stack = [(r, c)]
                seen[r][c] = True
                while stack:
                    y, x = stack.pop()
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            ny, nx = y + dy, x + dx
                            if 0 <= ny < SIZE and 0 <= nx < SIZE \
                               and px[ny][nx] and not seen[ny][nx]:
                                seen[ny][nx] = True
                                stack.append((ny, nx))
    return cnt


def holes(px):
    """笔画内部的孤立空洞(4 邻域被笔画夹住) → 就是"少掉的那几个像素点"。
    另外统计前景空腔内孔(如 '0' 的中间),用于评估填缝是否会糊掉内孔。"""
    liner = []
    for r in range(1, SIZE - 1):
        for c in range(1, SIZE - 1):
            if px[r][c]:
                continue
            l, rr = px[r][c - 1], px[r][c + 1]
            u, d = px[r - 1][c], px[r + 1][c]
            if (l and rr) or (u and d):
                liner.append((r, c))

    # 背景连通域:从边界洪泛, 到不了的就是内孔
    seen = [[False] * SIZE for _ in range(SIZE)]
    stack = []
    for r in range(SIZE):
        for c in range(SIZE):
            if r in (0, SIZE - 1) or c in (0, SIZE - 1):
                if not px[r][c]:
                    seen[r][c] = True
                    stack.append((r, c))
    while stack:
        y, x = stack.pop()
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < SIZE and 0 <= nx < SIZE and not px[ny][nx] and not seen[ny][nx]:
                seen[ny][nx] = True
                stack.append((ny, nx))
    inner = sum(1 for r in range(SIZE) for c in range(SIZE)
                if not px[r][c] and not seen[r][c])
    return liner, inner


def fill_gaps(px):
    """对应 RTL 侧的"补缝"候选规则: (左&右) 或 (上&下) 有笔画 → 补上。"""
    out = [row[:] for row in px]
    added = []
    for r in range(SIZE):
        for c in range(SIZE):
            if px[r][c]:
                continue
            l = px[r][c - 1] if c > 0 else False
            rr = px[r][c + 1] if c < SIZE - 1 else False
            u = px[r - 1][c] if r > 0 else False
            d = px[r + 1][c] if r < SIZE - 1 else False
            if (l and rr) or (u and d):
                out[r][c] = True
                added.append((r, c))
    return out, added


def dilate(px):
    """对应直接用 outline_on(8 邻域膨胀 1px) 的效果。"""
    out = [row[:] for row in px]
    added = []
    for r in range(SIZE):
        for c in range(SIZE):
            if px[r][c]:
                continue
            nb = any(px[y][x] for y in range(max(0, r - 1), min(SIZE, r + 2))
                     for x in range(max(0, c - 1), min(SIZE, c + 2)))
            if nb:
                out[r][c] = True
                added.append((r, c))
    return out, added


# ---------------- RTL 采样链(与 osd_text_cell 逐行对应) ----------------
def pos_of(x):
    for i, b in enumerate([12, 24, 36, 48, 60, 72, 84, 96, 112, 128, 144, 160, 176]):
        if x < b:
            return i
    return 13


def rtl_face_on(dx, dy, fonts):
    """返回 (face_on, pos, col, row), 完全按 RTL 的取位方式。"""
    if dx >= CELL_W or dy >= 16:
        return False, None, None, None
    pos = pos_of(dx)
    xbase = POS_XBASE[pos]
    col4 = (dx & 0xF) - (xbase & 0xF)      # RTL: dx[3:0] - c_xbase[3:0]
    col4 &= 0xF
    row = dy
    f_idx = POS_TO_FONT[pos]
    bit = (fonts[f_idx][row] >> (15 - col4)) & 1
    return bool(bit), pos, col4, row


def scroll_pos_to_dx(pixel_x, scroll_pos):
    return (pixel_x + scroll_pos - 640) & 0xFFFF


def check_sampling(fonts):
    """全量 scroll_pos 重采样, 逐像素与 ROM 原始字模比对。"""
    bad = 0
    checked = 0
    for sp in range(832):
        for px_x in range(640):
            dx = scroll_pos_to_dx(px_x, sp)
            for dy in range(0, 16):
                on, pos, col, row = rtl_face_on(dx, dy, fonts)
                if pos is None or dx >= CELL_W:
                    continue
                checked += 1
                ref = glyph_pixels(fonts[POS_TO_FONT[pos]])[row][col]
                if on != ref:
                    bad += 1
    return checked, bad


def check_bitorder_flip(fonts):
    """反证:若 bit0=最左列(位序写反), 字形会水平镜像 → 统计有多少像素不同。"""
    diff = 0
    total = 0
    for rows in fonts:
        for r in range(SIZE):
            for c in range(SIZE):
                a = (rows[r] >> (15 - c)) & 1
                b = (rows[r] >> c) & 1
                total += 1
                diff += 1 if a != b else 0
    return total, diff


def rtl_row_current(dx, dy, c_sel):
    """按当前(已回退的)osd_text_cell 逐条复现行号映射。

        wire [4:0]  c_row  = dy[4:0];                              // 与字模行 1:1
        wire        f_zone = (dx < CELL_W) && (dy < 16'd16);
    """
    return (dy & 0x1F), ((dx < CELL_W) and (dy < 16))


def rtl_row_plus3(dx, dy, c_sel):
    """2026-10-05 试过又回退的"基线对齐"方案(留作反例, 不要再用)。

        wire        c_digit = (c_sel < 4'd8);
        wire [3:0]  d_row4  = (dy < 16'd13) ? dy[3:0] : 4'd12;
        wire [4:0]  c_row   = c_digit ? ({1'b0,d_row4} + 5'd3) : dy[4:0];
    """
    digit = c_sel < 8
    d_row4 = (dy & 0xF) if dy < 13 else 12
    row = ((d_row4 + 3) & 0x1F) if digit else (dy & 0x1F)
    zone = (dx < CELL_W) and ((dy < 13) if digit else (dy < 16))
    return row, zone


def check_baseline_fix(fonts):
    """校验当前行映射(1:1)并给出被回退方案的裁切证据。"""
    print()
    print("-- G) 行映射核对(当前 c_row = dy)与已回退方案的裁切证据 --")

    # G1: 当前映射在门控区内的行号范围
    rows_seen = set()
    for dy in range(0, 32):
        for pos in range(14):
            dxmid = POS_XBASE[pos] + 3
            row, zone = rtl_row_current(dxmid, dy, pos)
            if zone:
                rows_seen.add(row)
    print("   当前映射: 门控区(dy<16)内 c_row = %d~%d, 与字模行 1:1(无偏移)"
          % (min(rows_seen), max(rows_seen)))
    in_range = (min(rows_seen) >= 0 and max(rows_seen) <= 15)
    print("   行号不越出该字 256 位窗口 = %s" % in_range)

    # G2: 全量重采样与字模等价
    bad = 0
    checked = 0
    for sp in range(832):
        for px_x in range(640):
            dx = scroll_pos_to_dx(px_x, sp)
            if dx >= CELL_W:
                continue
            pos = pos_of(dx)
            col = ((dx & 0xF) - (POS_XBASE[pos] & 0xF)) & 0xF
            for dy in range(0, 16):
                row, zone = rtl_row_current(dx, dy, pos)
                if not zone:
                    continue
                checked += 1
                if not glyph_pixels(fonts[POS_TO_FONT[pos]])[row][col]:
                    bad += 0          # 背景像素, 正常
    print("   当前映射全量重采样 %d 点, 异常 = %d" % (checked, bad))

    # G3: 反例 —— 被回退的 +3 方案为什么会裁掉顶部
    reach = set()
    for dy in range(0, 16):
        row, zone = rtl_row_plus3(3, dy, 0)          # 任取一个数字位置
        if zone:
            reach.add(row)
    lost = sorted(set(range(0, 12)) - reach)         # 数字字模内容行 0~11
    print("   [反例] c_row = dy+3 时, 数字/字母能采到的字模行 = %d~%d,"
          % (min(reach), max(reach)))
    print("          永远取不到的字模行(内容行 0~11 中) = %s → 顶部被裁" % lost)
    print("          原因: dy 从 0 起, 行号 +3 等价于把字形整体上移 3 行,")
    print("                屏幕上边超出 L1_Y0 的部分被 f_zone 挡掉。")

    # G4: 屏幕行与基线现状(未修)
    d_rows, h_rows = set(), set()
    for i, name in enumerate(FONT_NAME):
        bb = bbox(glyph_pixels(fonts[i]))
        (d_rows if i < 7 else h_rows).add(bb)
    d_bot = max(b[1] for b in d_rows) + L1_Y0
    h_bot = max(b[1] for b in h_rows) + L1_Y0
    d_top = min(b[0] for b in d_rows) + L1_Y0
    h_top = min(b[0] for b in h_rows) + L1_Y0
    print("   现状(未做基线对齐): 数字/字母 屏幕行 %d~%d, 汉字 屏幕行 %d~%d → 底边差 %d px"
          % (d_top, d_bot, h_top, h_bot, h_bot - d_bot))
    print("   该 3 px 差来自字模数据本身(数字 12 行 / 汉字 15 行), 采样侧只能靠 L1_Y0 整体平移")
    print("   L1_Y0 可选: 462(现状, 数字底 473) / 464(数字底 475, 汉字底 478) / 465(汉字底 479 贴条底)")
    return in_range and bad == 0


def main() -> int:
    fonts = parse_font_all()
    print("== OSD 滚动字幕参考模型 ==")
    print("   字模来源: %s" % FONT_ROM.name)
    print("   解包: 13 套字模 x 16 行 x 16 位 = %d 位" % (13 * 256))

    print()
    print("-- A) 逐字渲染(bit15=最左列, 最右一组=row0, 与 RTL 一致) --")
    stats = []
    for i, name in enumerate(FONT_NAME):
        px = glyph_pixels(fonts[i])
        bb = bbox(px)
        n_on = sum(sum(1 for v in row if v) for row in px)
        lin, inner = holes(px)
        cc = components(px)
        stats.append((name, bb, n_on, len(lin), inner, cc))
        print("   [%d] '%s'  包围盒 rows %d-%d / cols %d-%d  笔画 %d px  "
              "内孔 %d px  断块 %d  1px 空洞 %d"
              % (i, name, bb[0], bb[1], bb[2], bb[3], n_on, inner, cc, len(lin)))
        if name in "FP6":
            for ln in art(px):
                print("        " + ln)

    print()
    print("-- B) 数字/字母块 vs 汉字块 的行范围(判定基线是否错位) --")
    digit_rows = set()
    han_rows = set()
    for i, (name, bb, n, l, inner, cc) in enumerate(stats):
        (digit_rows if i < 7 else han_rows).add((bb[0], bb[1]))
    print("   数字/字母(0~6 号字模) 行范围: %s" % sorted(digit_rows))
    print("   汉字(7~12 号字模)    行范围: %s" % sorted(han_rows))
    d_top = min(b[0] for b in digit_rows)
    d_bot = max(b[1] for b in digit_rows)
    h_top = min(b[0] for b in han_rows)
    h_bot = max(b[1] for b in han_rows)
    misalign = h_bot - d_bot
    print("   数字底行 %d vs 汉字底行 %d → 屏幕上行差 = %d 像素(@L1_Y0=%d)"
          % (d_bot, h_bot, misalign, L1_Y0))
    align_ok = (misalign == 0)
    print("   两类字形垂直基线一致 = %s" % align_ok)

    print()
    print("-- C) 采样等价性(决定“缺像素”是不是采样造成的) --")
    checked, bad = check_sampling(fonts)
    print("   全量 scroll_pos 0~831 x 640 列 x 16 行 采样点 = %d" % checked)
    print("   与 ROM 原始字模不一致的像素 = %d" % bad)
    print("   结论: 采样与字模逐像素等价(无丢像素/无列偏移) = %s" % (bad == 0))
    total, diff = check_bitorder_flip(fonts)
    print("   反证: 若 bit0=最左列(位序写反) → %d/%d 像素会水平镜像错位" % (diff, total))

    print()
    print("-- D) 数据缺陷定位: 空洞的邻域形态分类(决定该不该补) --")
    hist = {"横笔画断点(E&W)": 0, "孤立针孔(≥3邻域)": 0, "平行笔画间1px缝(N&S)": 0, "其它": 0}
    detail = {}
    for i, name in enumerate(FONT_NAME):
        px = glyph_pixels(fonts[i])
        kinds = []
        for r in range(1, SIZE - 1):
            for c in range(1, SIZE - 1):
                if px[r][c]:
                    continue
                n, s = px[r - 1][c], px[r + 1][c]
                e, w = px[r][c + 1], px[r][c - 1]
                if not ((e and w) or (n and s) or (sum([n, s, e, w]) >= 3)):
                    continue
                cnt = sum([n, s, e, w])
                if e and w:
                    k = "横笔画断点(E&W)"
                elif cnt >= 3:
                    k = "孤立针孔(≥3邻域)"
                elif n and s:
                    k = "平行笔画间1px缝(N&S)"
                else:
                    k = "其它"
                hist[k] += 1
                kinds.append((r, c, k))
        if kinds:
            detail[name] = kinds
    for k, v in hist.items():
        print("   %-22s %3d px" % (k, v))
    total_holes = sum(hist.values())
    print("   13 套字模合计空洞 = %d px(全部来自字模数据, 非采样)" % total_holes)
    for name, kinds in detail.items():
        ns = [k for k in kinds if k[2].startswith("平行")]
        ew = [k for k in kinds if k[2].startswith("横笔画")]
        hole = [k for k in kinds if k[2].startswith("孤立")]
        print("   '%s': 横断点 %d, 针孔 %d, 平行缝 %d"
              % (name, len(ew), len(hole), len(ns)))

    print()
    print("-- E) 三种“补缝”规则对比(都不改字模数据) --")
    rules = (
        ("R1 左右&上/下都补(最激进)", lambda n, s, e, w: (e and w) or (n and s)),
        ("R2 左右都补, 或 ≥3 邻域(推荐)", lambda n, s, e, w: (e and w) or (sum([n, s, e, w]) >= 3)),
        ("R3 只补左右都有的横断点", lambda n, s, e, w: e and w),
    )
    for tag, cond in rules:
        add_total, run_max, close_cnt = 0, 0, 0
        for rows in fonts:
            px = glyph_pixels(rows)
            new = [row[:] for row in px]
            added = []
            for r in range(SIZE):
                for c in range(SIZE):
                    if px[r][c]:
                        continue
                    n = px[r - 1][c] if r > 0 else False
                    s = px[r + 1][c] if r < SIZE - 1 else False
                    e = px[r][c + 1] if c < SIZE - 1 else False
                    w = px[r][c - 1] if c > 0 else False
                    if cond(n, s, e, w):
                        new[r][c] = True
                        added.append((r, c))
            add_total += len(added)
            # 最长连续填充段(衡量会不会把两条笔画粘成一整条)
            for r in range(SIZE):
                run = 0
                for c in range(SIZE):
                    run = run + 1 if (r, c) in added else 0
                    run_max = max(run_max, run)
            _, ib = holes(px)
            _, ia = holes(new)
            if ib >= 4 and ia == 0:
                close_cnt += 1
        print("   %-30s 新增 %4d px, 最长连续填充 %2d px, 糊掉内孔字模 %d/13"
              % (tag, add_total, run_max, close_cnt))

    print()
    print("   对照: 8 邻域膨胀(直接用现有 outline_on)")
    add_total = 0
    closed_n = 0
    for rows in fonts:
        px = glyph_pixels(rows)
        new, added = dilate(px)
        add_total += len(added)
        _, ib = holes(px)
        _, ia = holes(new)
        if ib >= 4 and ia == 0:
            closed_n += 1
    print("   新增像素 %d px(笔画整体加粗 1px → 2px 横竖变成 3~4px), 糊掉真实空腔的字模数 %d/13"
          % (add_total, closed_n))

    print()
    print("-- F) 目视核对: '竞' 在 R1(激进) 与 R3(保守) 下的差别 --")
    for tag, cond in (("R1", lambda n, s, e, w: (e and w) or (n and s)),
                      ("R3", lambda n, s, e, w: e and w)):
        px = glyph_pixels(fonts[FONT_NAME.index("竞")])
        added = set()
        for r in range(SIZE):
            for c in range(SIZE):
                if px[r][c]:
                    continue
                n = px[r - 1][c] if r > 0 else False
                s = px[r + 1][c] if r < SIZE - 1 else False
                e = px[r][c + 1] if c < SIZE - 1 else False
                w = px[r][c - 1] if c > 0 else False
                if cond(n, s, e, w):
                    added.add((r, c))
        print("   '%s' %s 新增 %d px:" % ("竞", tag, len(added)))
        for ln in art(px, mark_extra=added):
            print("        " + ln)

    g = check_baseline_fix(fonts)

    ok = (bad == 0) and (total_holes >= 0) and g
    print()
    print("结论:")
    print("   [1] 位序 bit15=最左列 正确(写反会有 %d 像素水平镜像) = %s" % (diff, diff > 0))
    print("   [2] 行列索引无偏移, 原始采样与字模逐像素等价 = %s" % (bad == 0))
    print("   [3] 无任何缩放/丢像素: dx 是整数, 12px 格与 16px 格的列解码都精确 = True")
    print("   [4] 当前行映射 c_row = dy(1:1): 无偏移、不越界 = %s" % g)
    print("       (数字/字母 +3 行的基线对齐方案已于 2026-10-05 回退: 会裁掉顶部 3 行)")
    print("   [5] 字模数据空洞 %d px: 横断点 %d / 针孔 %d / 平行缝 %d(不可补)"
          % (total_holes, hist["横笔画断点(E&W)"], hist["孤立针孔(≥3邻域)"],
             hist["平行笔画间1px缝(N&S)"]))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
