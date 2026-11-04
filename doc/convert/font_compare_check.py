#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""新旧字模对比测试(旧 font_rom.v vs 新版重生成后的 font_rom.v)。

对比对象: 字幕串 "2026FPGA创新设计竞赛" 用到的 13 套字模(14 个字符位, '2' 复用两次)。

统计项(每套字模):
  * 笔画像素数 旧→新, 变化量与百分比          → 判断是否"过度膨胀"
  * 8 邻域连通块数(断块)                       → 判断是否"断笔连通"
  * 1px 空洞数(左右或上下被笔画夹住的空白点)   → 用户看到的"缺几个像素点"
  * 内孔像素数(字内部封闭空白, 如 '0' 的中孔)  → 判断是否被膨胀糊死
  * 包围盒(行/列范围)                          → 判断是否仍适配 RTL 的 12/16px 格

判定:
  * 过度膨胀: 像素增幅 > 40%, 或一个 ≥4px 的内孔被填死
  * 改善:     1px 空洞减少, 或断块减少, 或笔画增加而无内孔损失

用法:
    python font_compare_check.py                # 用默认路径
    python font_compare_check.py 旧.v 新.v
"""

import sys
from pathlib import Path
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from osd_text_ref_check import (                     # noqa: E402
    parse_font_all, glyph_pixels, bbox, components, holes, FONT_NAME,
)

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_OLD = os.path.join(HERE, "font_rom_before_regen_20261005.v")
DEFAULT_NEW = os.path.join(PROJ, "src", "user_source", "hdl_source", "font_rom.v")

# 字幕串 14 个字符位 → 13 套字模编号(与 font_rom.v 的 pos_to_font 一致)
STR = "2026FPGA创新设计竞赛"
POS_TO_FONT = [0, 1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
DIGITS = set(range(0, 7))          # 0~6 号 = 数字/字母(12px 格)

# RTL 采样盒(必须满足, 否则字符会被裁或串到相邻格)
BOX = {True: (11, 12), False: (15, 15)}   # digit: 列≤11, 行≤12 ; han: 列≤15, 行≤15


def stat(rows):
    px = glyph_pixels(rows)
    lin, inner = holes(px)
    bb = bbox(px)
    n = sum(sum(1 for v in r if v) for r in px)
    return {
        "n": n, "bb": bb, "cc": components(px),
        "holes": len(lin), "inner": inner,
        "w": bb[3] - bb[2] + 1, "h": bb[1] - bb[0] + 1,
        "rows": (bb[0], bb[1]), "cols": (bb[2], bb[3]),
    }


def main():
    old_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OLD
    new_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_NEW
    print("== 新旧字模对比测试 ==")
    print("   旧: %s" % os.path.basename(old_path))
    print("   新: %s" % os.path.basename(new_path))

    old = parse_font_all(Path(old_path))
    new = parse_font_all(Path(new_path))
    if len(old) != 13 or len(new) != 13:
        raise SystemExit("字模数量异常: old=%d new=%d" % (len(old), len(new)))
    print("   解包: 各 13 套 x 16 行 x 16 位")

    print()
    print("-- 逐套字模统计 --")
    print("   %-4s %-6s %-6s %-7s %-6s %-6s %-6s %-7s %-6s %s"
          % ("字", "笔画旧", "笔画新", "变化", "增幅", "断块旧", "断块新", "空洞旧", "空洞新", "内孔旧→新"))
    rows_out = []
    total_old = total_new = 0
    over_inflate = []
    improved = []
    box_bad = []
    for i, name in enumerate(FONT_NAME):
        so, sn = stat(old[i]), stat(new[i])
        total_old += so["n"]
        total_new += sn["n"]
        d = sn["n"] - so["n"]
        pct = (100.0 * d / so["n"]) if so["n"] else 0.0
        rows_out.append((i, name, so, sn, d, pct))
        print("   %-4s %-6d %-6d %+7d %+5.1f%% %-6d %-6d %-7d %-6d %d→%d"
              % (name, so["n"], sn["n"], d, pct, so["cc"], sn["cc"],
                 so["holes"], sn["holes"], so["inner"], sn["inner"]))
        # 过度膨胀判定: 增幅 >40% 且 没有修复断笔(断块/空洞都没减少), 或内孔被填死
        if (pct > 40.0 and sn["cc"] >= so["cc"] and sn["holes"] >= so["holes"]) \
           or (so["inner"] >= 4 and sn["inner"] == 0):
            over_inflate.append(name)
        # 改善判定
        if sn["holes"] < so["holes"] or sn["cc"] < so["cc"]:
            improved.append(name)
        # RTL 盒适配(新版必须满足)
        w_lim, h_lim = BOX[i in DIGITS]
        if sn["w"] > w_lim or sn["h"] > h_lim:
            box_bad.append((name, sn["w"], sn["h"], w_lim, h_lim))

    print()
    print("-- 字幕串 \"%s\"(14 个字符位) --" % STR)
    s_old = sum(stat(old[POS_TO_FONT[k]])["n"] for k in range(14))
    s_new = sum(stat(new[POS_TO_FONT[k]])["n"] for k in range(14))
    print("   整串笔画像素: 旧 %d → 新 %d (%+d, %+.1f%%)"
          % (s_old, s_new, s_new - s_old, 100.0 * (s_new - s_old) / s_old))
    print("   13 套字模合计: 旧 %d → 新 %d (%+.1f%%)"
          % (total_old, total_new, 100.0 * (total_new - total_old) / total_old))
    print("   位置级: 数字/字母(0~7) %s"
          % "/".join("%d" % stat(old[POS_TO_FONT[k]])["n"] for k in range(8))
          + " → " + "/".join("%d" % stat(new[POS_TO_FONT[k]])["n"] for k in range(8)))

    print()
    print("-- 判定 --")
    print("   仍适配 RTL 采样盒(数字 %dx%d / 汉字 %dx%d) = %s"
          % (BOX[True][0], BOX[True][1], BOX[False][0], BOX[False][1],
             "是" if not box_bad else "否 %s" % box_bad))
    print("   存在过度膨胀的字模 = %s" % (over_inflate if over_inflate else "无"))
    print("   断笔/空洞得到改善的字模 = %s" % (improved if improved else "无"))

    # 竖向几何(必须保持旧的排布: 数字 12 行、汉字 15 行, 均顶对齐)
    print()
    print("-- 竖向几何(应保持与旧版一致: 顶对齐) --")
    for i, name, so, sn, d, pct in rows_out:
        tag = "数字/字母" if i in DIGITS else "汉字"
        print("   %-4s %-6s 行 旧%s → 新%s   列 旧%s → 新%s"
              % (name, tag, so["rows"], sn["rows"], so["cols"], sn["cols"]))

    ok = (not box_bad) and (not over_inflate)
    print()
    print("   总结: %s" % ("通过(可用)" if ok else "不通过(需调整参数)"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
