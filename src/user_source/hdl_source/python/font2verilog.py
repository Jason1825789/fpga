# -*- coding: utf-8 -*-
"""
font2verilog.py — 字模渲染工具(2026-10-05 高分辨率重写版)

功能:13 套固定字符字模 → 打包成 3328'h FONT_ALL, 直接生成 font_rom.v
     (16x16 点阵, 供 FPGA OSD 滚动字幕使用)

目标(适配黑字 + 红背景):
  * 保持粗壮      —— 去掉腐蚀、加大字重、降低二值化阈值
  * 尽量减少断笔  —— 无 MinFilter、无倾斜剪切
  * 保留细节      —— 64x64 灰度渲染 + LANCZOS, 用抗锯齿信息定二值化
  * 避免糊字      —— 不做膨胀/8邻域填充, 灰度阈值只"还原"不"加粗"

生成流程(与旧版不同, 见尾部"修改说明"):
  字体文件 → 64x64 灰度渲染 → 按排版盒裁剪缩放(数字/字母 11x12, 汉字 15x15)
            → LANCZOS 缩回 16x16 → 阈值 > THRESHOLD 二值化 → 256bit/字 打包

位序约定(与 font_rom.v / RTL 完全一致, 写错字会上下颠倒):
  * FONT_ALL 字面量"最右边那一组" = 字库编号 0 的 bits[15:0] = row 0(字符最上行)
  * 每行 16 位里 bit15 = 最左列

用法:
    python font2verilog.py                    # 用默认参数重写 font_rom.v
    python font2verilog.py --threshold 90     # 只调阈值快速对比(90=更粗 / 110/120=更细)
    python font2verilog.py --weight 500       # 换字重(NotoSansSC-VF 可变字重)
    python font2verilog.py --dry-run          # 只打印, 不写文件
"""

import os
import sys
import argparse
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SIZE = 16  # 固定 16x16(FPGA 侧 font_rom.v 按 16 位行寻址)

# ================= 可配置参数(与命令行参数同名) =================
RENDER_SCALE  = 4                     # 高分辨率倍数: 16*4 = 64x64
RENDER_SIZE   = SIZE * RENDER_SCALE   # 64
FONT_WEIGHT   = 500                   # NotoSansSC-VF 可变字重 100~900(500=中等, 600=半粗)
THRESHOLD     = 110                   # 二值化阈值(灰度 0~255); 越小笔画越粗
ENABLE_ERODE  = False                 # 腐蚀(MinFilter(3)): 细笔画杀手, 本版默认关闭
ENABLE_ITALIC = False                 # 倾斜剪切: 16x16 下会造成阶梯/错位/断笔, 本版默认关闭

# 排版盒(16x16 画布内, 单位 px)——必须与 RTL 的 12px/16px 格与当前垂直布局一致:
#   数字/字母(位置 0~7): RTL 用 12px 格采样 → 宽 ≤ 11(留 1px 左边距), 高 ≤ 12(保持现状)
#   汉字(位置 8~13):     RTL 用 16px 格采样 → 宽 ≤ 15(留 1px 左边距), 高 ≤ 15
DIGIT_BOX = (11, 12)
HAN_BOX   = (15, 15)
LEFT_MARGIN = 1                       # 1px 左边距(与旧字模一致)

# 13 套字模(顺序不可改, 与 font_rom.v 的 pos_to_font 一致)
CHARS = ['2', '0', '6', 'F', 'P', 'G', 'A', '创', '新', '设', '计', '竞', '赛']
DIGIT_CHARS = set('206FPGA')          # 走 12px 格的字符(位置 0~7)
FONT_ROM_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "font_rom.v")
FONT_CANDIDATES = [
    ("思源黑体", r"C:\Windows\Fonts\NotoSansSC-VF.ttf"),
    ("雅黑粗体", r"C:\Windows\Fonts\msyhbd.ttc"),
    ("微软雅黑", r"C:\Windows\Fonts\msyh.ttc"),
    ("黑体",     r"C:\Windows\Fonts\simhei.ttf"),
]


def find_font(name="思源黑体"):
    for disp, path in FONT_CANDIDATES:
        if name in (disp, os.path.basename(path)) and os.path.exists(path):
            return disp, path
    for disp, path in FONT_CANDIDATES:
        if os.path.exists(path):
            print("[提示] 未找到 '%s', 使用 %s" % (name, disp))
            return disp, path
    raise SystemExit("[错误] 找不到任何可用字体")


def load_font(path, size, weight):
    font = ImageFont.truetype(path, size)
    if "NotoSansSC" in path:
        try:
            font.set_variation_by_axes([weight])
        except Exception:
            pass
    return font


def render_char(ch, font_path, weight, threshold, erode, italic):
    """渲染单个字符为 16 个 16 位整数(第 0 个 = 最上行)。"""
    font = load_font(font_path, RENDER_SIZE, weight)

    # 1) 灰度渲染 —— 工作画布放大到 128x128:
    #    64px 字号的行框(ascender~descender)约 70+px, 直接画在 64x64 上
    #    会把字形底部(如 '2' 的底横)裁出画布, 必须先画在大画布再裁剪。
    work = RENDER_SIZE * 2
    img = Image.new("L", (work, work), 0)
    draw = ImageDraw.Draw(img)
    draw.text((8, 8), ch, fill=255, font=font)

    # 2) 按排版盒裁剪缩放(保留全部抗锯齿灰度)
    bbox = img.getbbox()
    if bbox is None:
        return [0] * SIZE
    crop = img.crop(bbox)
    box_w, box_h = DIGIT_BOX if ch in DIGIT_CHARS else HAN_BOX
    tw, th = box_w * RENDER_SCALE, box_h * RENDER_SCALE
    s = min(tw / crop.width, th / crop.height)          # 等比, 不拉伸
    nw = max(1, round(crop.width * s))
    nh = max(1, round(crop.height * s))
    crop = crop.resize((nw, nh), Image.Resampling.LANCZOS)

    # 3) 贴回 64x64 画布: 1px 左边距, 顶对齐(保持与旧字模相同的垂直几何)
    canvas = Image.new("L", (RENDER_SIZE, RENDER_SIZE), 0)
    canvas.paste(crop, (LEFT_MARGIN * RENDER_SCALE, 0))

    # 4) LANCZOS 缩回 16x16(显式使用 Resampling.LANCZOS, 不用 NEAREST)
    small = canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)

    # 5) 可选处理(本版默认全关)
    if erode:
        small = small.filter(ImageFilter.MinFilter(3))  # 腐蚀, 会吃掉细笔画
    if italic:
        small = small.transform((SIZE, SIZE), Image.AFFINE,
                                (1, 0.15, -1.2, 0, 1, 0),
                                resample=Image.Resampling.BILINEAR)

    # 6) 阈值二值化(只"还原", 不做任何膨胀)
    rows = []
    for r in range(SIZE):
        bits = 0
        for c in range(SIZE):
            if small.getpixel((c, r)) > threshold:
                bits |= (1 << (15 - c))                 # bit15 = 最左列
        rows.append(bits)
    return rows


def ascii_art(rows):
    out = []
    for r in range(SIZE):
        out.append("".join("#" if (rows[r] >> (15 - c)) & 1 else "."
                           for c in range(SIZE)))
    return out


def fmt_verilog(rows):
    """16 行 → 4 位十六进制组, 最右一组 = row 0。"""
    groups = ["%04X" % v for v in rows]
    groups.reverse()
    return "_".join(groups)


def build_font_rom(font_all_literal, src_path):
    """以旧 font_rom.v 为模板, 只替换头部注释和 FONT_ALL 那一行,
    module/pos_to_font/备用字库/解码逻辑逐字保留。"""
    src = open(src_path, "r", encoding="utf-8").read()
    i = src.index("module font_rom(")
    j = src.index("// ============ 主字库")
    k = src.index(";", src.index("localparam [3327:0] FONT_ALL")) + 1
    middle = src[i:j]                      # module + 端口 + pos_to_font + 备用字库
    tail = src[k:].lstrip("\n")            # FONT_ALL 之后的解码逻辑 + endmodule

    header = (
        "//====================================================\n"
        "// font_rom.v — OSD 字模 ROM(字幕引擎字库)\n"
        "// 功能: 输入字符位置号(0~13)+ 字符内行列号(0~15), 输出笔画/描边\n"
        "// 生成工具: python/font2verilog.py(2026-10-05 高分辨率重写版)\n"
        "//           64x64 灰度渲染 → LANCZOS 缩回 16x16 → 阈值二值化\n"
        "//           无腐蚀 / 无倾斜(细笔画/斜线质量大幅改善)\n"
        "// 【位序约定, 写错字会上下颠倒】\n"
        "//   字面量里\"最右边那一组\"对应 bits[15:0], 也就是 row=0 的那一行(字符最上行);\n"
        "//   每行 16 位里 bit15 = 最左列\n"
        "//====================================================\n"
    )
    font_all_block = (
        "// ============ 主字库:13 套字模打包(最右一组 = 编号 0) ============\n"
        "// 生成: font2verilog.py(2026-10-05 重写) — %s 字重%d\n"
        "//       64x64 灰度渲染 → LANCZOS 缩回 16x16 → 阈值 > %d 二值化\n"
        "//       无腐蚀 / 无倾斜 / 数字字母 %dx%d 盒 / 汉字 %dx%d 盒(1px 左边距,顶对齐)\n"
        "// 注意:Verilog 数字字面量不可跨行,整串必须写在一行\n"
        "localparam [3327:0] FONT_ALL = 3328'h%s;\n"
        % (_BANNER_FONT, _BANNER_WEIGHT, THRESHOLD_USED,
           DIGIT_BOX[0], DIGIT_BOX[1], HAN_BOX[0], HAN_BOX[1],
           font_all_literal)
    )
    return header + middle + font_all_block + "\n\n" + tail


def main():
    ap = argparse.ArgumentParser(description="高分辨率字模渲染 → font_rom.v")
    ap.add_argument("--font", default="思源黑体",
                    help="字体名(思源黑体/雅黑粗体/微软雅黑/黑体)")
    ap.add_argument("--weight", type=int, default=FONT_WEIGHT,
                    help="NotoSansSC-VF 可变字重 100~900(默认 %d)" % FONT_WEIGHT)
    ap.add_argument("--threshold", type=int, default=THRESHOLD,
                    help="二值化阈值(默认 %d; 常用 90/100/110 快速对比)" % THRESHOLD)
    ap.add_argument("--erode", action="store_true", help="(不推荐)打开 MinFilter(3) 腐蚀")
    ap.add_argument("--italic", action="store_true", help="(不推荐)打开倾斜剪切")
    ap.add_argument("--dry-run", action="store_true", help="只打印, 不写 font_rom.v")
    args = ap.parse_args()

    disp, font_path = find_font(args.font)
    global _BANNER_FONT, _BANNER_WEIGHT, THRESHOLD_USED
    _BANNER_FONT = "%s(%s)" % (disp, os.path.basename(font_path))
    _BANNER_WEIGHT = args.weight
    THRESHOLD_USED = args.threshold

    print("== font2verilog.py(2026-10-05 高分辨率重写版) ==")
    print("   字体: %s  字重: %d  阈值: >%d  腐蚀: %s  倾斜: %s"
          % (font_path, args.weight, args.threshold,
             args.erode, args.italic))
    print("   流程: 64x64 灰度渲染 → LANCZOS → 16x16 → 阈值二值化")

    all_rows = []
    for idx, ch in enumerate(CHARS):
        rows = render_char(ch, font_path, args.weight, args.threshold,
                           args.erode, args.italic)
        n_on = sum(bin(v).count("1") for v in rows)
        print("   [%2d] '%s'  笔画 %3d px" % (idx, ch, n_on))
        for ln in ascii_art(rows):
            print("        " + ln)
        all_rows.append(rows)

    # 打包: 编号 idx 的字占 bits [idx*256 +: 256](字面量最右一组 = 编号 0)
    groups = []
    for rows in all_rows:
        groups.append(fmt_verilog(rows))
    groups.reverse()                                  # 编号 0 落到最右
    font_all_literal = "_".join(groups)
    print("   打包: 13 x 256 = %d 位" % (13 * 256))

    if args.dry_run:
        print("   [dry-run] 未写文件")
        return

    text = build_font_rom(font_all_literal, FONT_ROM_PATH)
    with open(FONT_ROM_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("   已重写: %s" % os.path.abspath(FONT_ROM_PATH))


_BANNER_FONT = ""
_BANNER_WEIGHT = FONT_WEIGHT
THRESHOLD_USED = THRESHOLD

if __name__ == "__main__":
    main()
