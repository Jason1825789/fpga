#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""font2verilog.py — 由文案生成 font_rom.v 的点阵字模

规格（沿用 2026-10-05 原版）:
  * 字体 NotoSansSC-VF.ttf，字重 500
  * 4 倍超采样(64x64) → LANCZOS 缩回 16x16 → 阈值 > 110 二值化
  * ASCII 盒 11x12，汉字盒 15x15，均 1px 左边距
  * ASCII 按**基线**对齐（这样冒号/减号落在正确高度，不会被顶到顶部）
  * 汉字按字框顶对齐

位序约定（写错字会上下颠倒，与原工程一致）:
  * 字面量里"最右边那一组"对应 bits[15:0]，即 row=0（字符最上行）
  * 每行 16 位里 bit15 = 最左列

用法:
    python font2verilog.py                 # 生成并写回 font_rom.v
    python font2verilog.py --preview       # 额外输出文案预览条 PNG
"""
import sys
import os
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = r"C:/Windows/Fonts/NotoSansSC-VF.ttf"
FONT_WEIGHT = 500
SS = 4                  # 超采样倍数
GRID = 16
THRESHOLD = 110
ASCII_BOX = (11, 12)    # 宽, 高
HANZI_BOX = (15, 15)

HERE = Path(__file__).resolve().parent
PROJ = HERE.parent.parent.parent
FONT_ROM = PROJ / "src" / "user_source" / "hdl_source" / "font_rom.v"

# ---------------- 文案定义 ----------------
# 两句共用同一套字库(txt_sel 选择)，由 SW3 现场切换:
#   txt_sel = 0 → 开园句 A（SW3 拨上）
#   txt_sel = 1 → 闭园句 B（SW3 拨下）
# 硬约束: 两句都必须是 10 ASCII + 6 汉字(=216px)，否则 osd_engine 的
#         pos_xbase / pos_of / SCROLL_W 要跟着改。build() 会检查并报错。
TEXT_A = "9:00-17:00颐和园欢迎您"      # 16 字符 = 10 ASCII + 6 汉字
TEXT_B = "17:00-9:00颐和园已闭园"      # 16 字符 = 10 ASCII + 6 汉字
TEXT_NAME = "颐和园导览屏"

_REF = ImageFont.truetype(FONT_PATH, 200)
try:
    _REF.set_variation_by_axes([FONT_WEIGHT])
except Exception:
    pass


def _ink(ch):
    """渲染单字符，返回 (墨迹图, 相对基线左端的偏移 bbox)。

    anchor='ls' 把绘制原点放在基线左端，因此 bbox[1]/bbox[3]
    就是墨迹顶/底相对基线的位置——冒号这类小字符靠这个才能对位。
    """
    canvas = Image.new("L", (800, 800), 0)
    ImageDraw.Draw(canvas).text((200, 400), ch, font=_REF, fill=255, anchor="ls")
    bb = canvas.getbbox()
    if not bb:
        return None, None
    return canvas.crop(bb), (bb[0] - 200, bb[1] - 400, bb[2] - 200, bb[3] - 400)


# ASCII 统一缩放比: 以 '0' 的墨迹高度 = 12 行为基准
_ink0, _bb0 = _ink("0")
ASCII_SCALE = (ASCII_BOX[1] * SS) / _ink0.height


def make_glyph(ch):
    """生成 16x16 二值位图 [[bool]*16]*16，索引 [row][col]，col=0 最左。"""
    ink, rel = _ink(ch)
    if ink is None:
        return [[False] * GRID for _ in range(GRID)]
    canvas = Image.new("L", (GRID * SS, GRID * SS), 0)

    if ord(ch) < 128:
        b = ASCII_BOX
        scale = ASCII_SCALE
        # 基线落在第 12 行上边界 → '0' 恰好占 row 0~11
        baseline = b[1] * SS
        top_from_baseline = -rel[1] * scale          # 墨迹顶到基线的距离(像素)
        paste_y = int(round(baseline - top_from_baseline))
    else:
        b = HANZI_BOX
        scale = (b[1] * SS) / ink.height             # 汉字各自归一到 15 行
        paste_y = 0                                  # 顶对齐

    nw = max(1, int(round(ink.width * scale)))
    nh = max(1, int(round(ink.height * scale)))
    if nw > b[0] * SS or nh > b[1] * SS:
        # 超框时等比再缩一次，保证不越界
        r = min(b[0] * SS / nw, b[1] * SS / nh)
        nw, nh = max(1, int(nw * r)), max(1, int(nh * r))

    # 横向定位: 窄字符(冒号/减号等标点)在格内居中, 否则左对齐 +1px 边距。
    # 标点若也左对齐, 格子右侧会空出一大片, 视觉上 "9:00" 的间隔忽大忽小。
    if nw < b[0] * SS * 0.55:
        paste_x = (b[0] * SS - nw) // 2
    else:
        paste_x = 1 * SS

    ink = ink.resize((nw, nh), Image.LANCZOS)
    canvas.paste(ink, (paste_x, max(0, paste_y)))

    small = canvas.resize((GRID, GRID), Image.LANCZOS)
    return [[small.getpixel((x, y)) > THRESHOLD for x in range(GRID)]
            for y in range(GRID)]


def pack(px):
    """16x16 布尔矩阵 → 16 个 16 位整数（bit15 = 最左列）。"""
    rows = []
    for y in range(GRID):
        v = 0
        for x in range(GRID):
            if px[y][x]:
                v |= 1 << (15 - x)
        rows.append(v)
    return rows


def build():
    chars_a = list(TEXT_A)
    chars_b = list(TEXT_B)
    for tag, chs in (("A", chars_a), ("B", chars_b)):
        if len(chs) > 16:
            raise SystemExit(f"文案 {tag} 有 {len(chs)} 字符，超过 16 上限（会导致索引位宽变化）")

    # 去重：同一字符共用一套字模。A 的字符先排，保证原有字模编号不变
    # (0..11 与原单句版本完全一致 → FONT_ALL 低 3072 位逐位不变)
    order = []
    for c in chars_a + chars_b:
        if c not in order:
            order.append(c)
    if len(order) > 16:
        raise SystemExit(f"两句合并共 {len(order)} 套字模，超过 16 上限（font_idx 是 4 位）")

    glyphs = {}
    meta = []
    for c in order:
        px = make_glyph(c)
        glyphs[c] = pack(px)
        meta.append((c, ord(c) < 128, sum(sum(r) for r in px)))

    # 位置 → 字模编号（每句一张表）
    pos_map_a = [order.index(c) for c in chars_a]
    pos_map_b = [order.index(c) for c in chars_b]

    # 排版必须一致，否则 osd_engine 的 pos_xbase / pos_of / SCROLL_W 要跟着改
    def layout(chs):
        na = sum(1 for c in chs if ord(c) < 128)
        return na, len(chs) - na, na * 12 + (len(chs) - na) * 16

    la, lb = layout(chars_a), layout(chars_b)
    if la != lb:
        raise SystemExit(
            f"两句排版不一致: A={la[0]}ASCII+{la[1]}汉字={la[2]}px, "
            f"B={lb[0]}ASCII+{lb[1]}汉字={lb[2]}px；必须同为 10+6=216px")

    # 打包 FONT_ALL: 编号 f 的 row r 位于 (f*256 + r*16)
    total = 0
    for f, c in enumerate(order):
        for r, rowbits in enumerate(glyphs[c]):
            total |= (rowbits & 0xFFFF) << (f * 256 + r * 16)

    nbits = len(order) * 256
    hexs = format(total, "0%dx" % (nbits // 4))
    # 每 4 个 hex（= 16 位 = 1 行）加一个下划线，与原文件风格一致
    groups = [hexs[i:i + 4] for i in range(0, len(hexs), 4)]
    font_literal = "_".join(groups)

    return dict(chars_a=chars_a, chars_b=chars_b, order=order,
                pos_map_a=pos_map_a, pos_map_b=pos_map_b, meta=meta,
                font_literal=font_literal, nbits=nbits,
                n_ascii=la[0], n_hanzi=la[1], total_w=la[2], glyphs=glyphs)


def gen_verilog(d):
    order, meta = d["order"], d["meta"]

    def posmap(chars):
        return "\n".join(f'//   {i}: {c!r}' for i, c in enumerate(chars))

    # 扁平化 case: {txt_sel, pos} 共 32 项，不用嵌套 case ——
    # TD 的 Verilog 解析器对嵌套 case / 合并项不稳，扁平写法是已验证过的形式
    case_lines = []
    for sel, chars, pos_map, tag in ((0, d["chars_a"], d["pos_map_a"], "A"),
                                     (1, d["chars_b"], d["pos_map_b"], "B")):
        case_lines.append(f"        // ---- txt_sel={sel}: 文案{tag} ----")
        for pos in range(16):
            case_lines.append(
                f"        5'd{sel * 16 + pos:<2}: pos_to_font = 4'd{pos_map[pos]};"
                f"   // {tag} 位置{pos} = {chars[pos]!r}")

    font_comment = []
    for i, (c, is_ascii, npx) in enumerate(meta):
        kind = "ASCII" if is_ascii else "汉字"
        font_comment.append(f"//   {i:2d} = {c!r} ({kind}, {npx} px)")

    return f'''//====================================================
// font_rom.v — OSD 字模 ROM(字幕引擎字库)
// 功能: 输入字符位置号 + 文案选择 + 字符内行列号(0~15), 输出笔画/描边
// 生成工具: python/font2verilog.py(由文案自动生成)
//           64x64 灰度渲染 → LANCZOS 缩回 16x16 → 阈值二值化
//           无腐蚀 / 无倾斜
//           ASCII 按基线对齐(标点位置正确), 汉字按字框顶对齐
// 【位序约定, 写错字会上下颠倒】
//   字面量里"最右边那一组"对应 bits[15:0], 也就是 row=0 的那一行(字符最上行);
//   每行 16 位里 bit15 = 最左列
//====================================================
module font_rom(
    input  wire [3:0]  char_sel,   // 字符位置号 0~15(见下方映射表)
    input  wire        txt_sel,    // 0 = 文案A(开园句), 1 = 文案B(闭园句)
    input  wire [4:0]  row,        // 字符内行号 0~15
    input  wire [4:0]  col,        // 字符内列号 0~15
    output wire        pixel_on,   // 1=笔画(显示字色) 0=空白
    output wire        outline_on  // 1=描边(笔画相邻 1 像素,8 邻域)
);

// 文案A(txt_sel=0): "{TEXT_A}"  {len(d["chars_a"])} 字符 = {d["n_ascii"]} ASCII + {d["n_hanzi"]} 汉字
// 文案B(txt_sel=1): "{TEXT_B}"  {len(d["chars_b"])} 字符 = {d["n_ascii"]} ASCII + {d["n_hanzi"]} 汉字
// 两句排版完全相同({d["n_ascii"]}x12 + {d["n_hanzi"]}x16 = {d["total_w"]}px)，共用同一套字库
//
// 位置号 → 字符(文案A):
{posmap(d["chars_a"])}
//
// 位置号 → 字符(文案B):
{posmap(d["chars_b"])}
//
// 独立字模 {len(order)} 套:
{chr(10).join(font_comment)}
function [3:0] pos_to_font;
    input [3:0] pos;
    input       txt_sel;
    begin
        case ({{txt_sel, pos}})
{chr(10).join(case_lines)}
        default: pos_to_font = 4'd{d["pos_map_b"][15]}; // B 位置15 = {d["chars_b"][15]!r}
        endcase
    end
endfunction

// ============ 备用字库(当前不显示,以后可调用) ============
localparam [255:0] FONT_WAN   = 256'h0000_4000_61F0_3018_1808_0808_0C08_0408_040C_040C_07FC_0400_0600_0600_FFFF_0000;   // '万'
localparam [255:0] FONT_XIANG = 256'h0000_4780_30C2_0C44_6348_1CD0_66F0_1D98_0704_3FFE_2186_A086_7FFE_1020_0FF0_0400;   // '象'
localparam [255:0] FONT_PING  = 256'h0000_0000_8C10_4610_6210_3FFF_2310_2310_2FFE_2110_2210_3FFE_2002_2002_3FFE_0000;   // '屏'

// ============ 主字库: {len(order)} 套字模打包(最右一组 = 编号 0) ============
// 生成: font2verilog.py — 思源黑体(NotoSansSC-VF.ttf) 字重{FONT_WEIGHT}
//       64x64 灰度渲染 → LANCZOS 缩回 16x16 → 阈值 > {THRESHOLD} 二值化
//       ASCII 11x12 盒(基线对齐) / 汉字 15x15 盒(顶对齐), 均 1px 左边距
//       编号 0~11 = 原单句字库(逐位未变), 12~13 = 闭园句新增的 '已' '闭'
// 注意:Verilog 数字字面量不可跨行,整串必须写在一行
localparam [{d["nbits"]-1}:0] FONT_ALL = {d["nbits"]}'h{d["font_literal"]};

'''


TAIL_FILE = HERE / "font_rom_tail.txt"


def get_tail(current_txt):
    """取字模之后的固定逻辑段(①②③④⑤⑥)。

    首次运行时从现有 font_rom.v 切出来存成模板，之后一律用模板，
    这样脚本可以反复运行而不会把这段代码重复拼进文件。
    """
    if TAIL_FILE.exists():
        return TAIL_FILE.read_text(encoding="utf-8")
    i = current_txt.index("// ① 位置号")
    tail = current_txt[i:]
    if "// ① 位置号" in tail[10:]:
        raise SystemExit("现有 font_rom.v 已含重复段，无法作为模板；请先从备份恢复")
    TAIL_FILE.write_text(tail, encoding="utf-8")
    return tail


def write_back(d):
    txt = FONT_ROM.read_text(encoding="utf-8")
    tail = get_tail(txt)
    FONT_ROM.write_text(gen_verilog(d) + tail, encoding="utf-8")


def _strip(chars, total_w):
    """把一句文案按真实格宽拼成一条 16px 高的灰度带。"""
    strip = Image.new("L", (total_w, 16), 0)
    x = 0
    for c in chars:
        px = make_glyph(c)
        w = 12 if ord(c) < 128 else 16
        for y in range(16):
            for xx in range(min(w, 16)):
                if px[y][xx]:
                    strip.putpixel((x + xx, y), 255)
        x += w
    return strip


def preview(d, out_png):
    """两句各拼一条，模拟板上观感。"""
    W, H, PAD = 640, 20, 14
    rows = []
    for tag, chars in (("A 开园", d["chars_a"]), ("B 闭园", d["chars_b"])):
        strip = _strip(chars, d["total_w"])
        sw = strip.width
        for sub, seg in ((f"{tag} 起点", strip.crop((0, 0, min(sw, W - 8), 16))),
                         (f"{tag} 中段", strip.crop((max(0, sw // 2 - 200), 0,
                                                    min(sw, sw // 2 + 200), 16))),
                         (f"{tag} 整条", strip)):
            rows.append((sub, seg))

    sheet = Image.new("RGB", (W + 220, (H + PAD) * len(rows) + PAD), (238, 238, 238))
    d_lbl = ImageDraw.Draw(sheet)
    f_lbl = ImageFont.truetype(r"C:/Windows/Fonts/msyh.ttc", 15)

    y = PAD
    for tag, seg in rows:
        bar = Image.new("RGB", (W, H), (255, 0, 0))
        for yy in range(16):
            for xx in range(seg.width):
                if seg.getpixel((xx, yy)) > 128 and xx < W:
                    bar.putpixel((xx, 2 + yy), (0, 0, 0))
        sheet.paste(bar, (10, y))
        d_lbl.text((W + 14, y + 3), tag, font=f_lbl, fill=(30, 30, 30))
        y += H + PAD

    sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.LANCZOS)
    sheet.save(out_png)
    return out_png


def main():
    d = build()
    for tag, chars in (("A(开园)", d["chars_a"]), ("B(闭园)", d["chars_b"])):
        print(f'文案{tag}: {"".join(chars)}   ({len(chars)} 字符 = '
              f'{d["n_ascii"]} ASCII + {d["n_hanzi"]} 汉字)')
    print(f'字模: {len(d["order"])} 套   总宽: {d["total_w"]} px   '
          f'周期: {d["total_w"] + 640} 帧 = {(d["total_w"] + 640) / 60:.1f}s')
    print("--- 逐字 ---")
    for i, (c, is_ascii, npx) in enumerate(d["meta"]):
        print(f'  {i:2d} {c!r:6s} {"ASCII" if is_ascii else "汉字":5s} {npx:4d} px')

    write_back(d)
    print(f"已写入 {FONT_ROM}")

    if "--preview" in sys.argv:
        out = HERE / "font_preview.png"
        preview(d, str(out))
        print(f"预览: {out}")


if __name__ == "__main__":
    main()
