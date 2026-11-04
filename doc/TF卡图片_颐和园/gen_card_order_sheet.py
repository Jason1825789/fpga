# -*- coding: utf-8 -*-
"""生成卡内"实际播放顺序"核对图。

FPGA 按物理簇（LCN）递增顺序播放，与文件名无关，因此本脚本先用
`fsutil file queryextents` 取每个 BMP 的起始 LCN，按 LCN 排序后出图。

用法：python gen_card_order_sheet.py I:
"""
import os
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

# 文件名 -> 画面上的地名（与图片内烧进的艺术字一致）
NAMES = {
    "01.bmp": "万寿山",
    "02.bmp": "佛香阁·暮",
    "03.bmp": "十七孔桥",
    "04.bmp": "石舫",
    "05.bmp": "清晏舫",
    "06.bmp": "廓如亭",
    "07.bmp": "长廊",
    "08.bmp": "佛香阁·晨",
}

CN_FONT = "C:/Windows/Fonts/msyh.ttc"

TILE_W, TILE_H = 320, 240
LABEL_H = 44
COLS = 4
PAD = 12


def font(size):
    try:
        return ImageFont.truetype(CN_FONT, size)
    except Exception:
        return ImageFont.load_default()


def first_lcn(path):
    try:
        out = subprocess.run(["fsutil", "file", "queryextents", path],
                             capture_output=True, text=True, errors="ignore").stdout
    except Exception:
        return None
    m = re.search(r"LCN:\s*0x([0-9a-fA-F]+)", out)
    return int(m.group(1), 16) if m else None


def collect(drive):
    items = []
    for fn in sorted(os.listdir(drive)):
        if not fn.lower().endswith(".bmp"):
            continue
        p = os.path.join(drive, fn)
        lcn = first_lcn(p)
        items.append((lcn if lcn is not None else 1 << 40, fn, p))
    items.sort(key=lambda t: t[0])
    return items


def main(drive):
    items = collect(drive)
    if not items:
        print("no bmp found in", drive)
        return
    rows = (len(items) + COLS - 1) // COLS
    sheet = Image.new("RGB",
                      (COLS * TILE_W + (COLS + 1) * PAD,
                       rows * (TILE_H + LABEL_H) + (rows + 1) * PAD),
                      (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    f_big = font(20)
    f_small = font(16)

    for i, (lcn, fn, p) in enumerate(items):
        cx = PAD + (i % COLS) * (TILE_W + PAD)
        cy = PAD + (i // COLS) * (TILE_H + LABEL_H + PAD)
        im = Image.open(p).convert("RGB").resize((TILE_W, TILE_H), Image.LANCZOS)
        sheet.paste(im, (cx, cy))
        d.rectangle([cx, cy, cx + TILE_W - 1, cy + TILE_H - 1], outline=(185, 185, 185), width=1)
        d.text((cx + 6, cy + TILE_H + 5),
               "第%d张  %s" % (i + 1, fn), font=f_big, fill=(15, 15, 15))
        d.text((cx + 6, cy + TILE_H + 25),
               "%s   LCN 0x%X" % (NAMES.get(fn, ""), lcn if lcn < (1 << 40) else 0),
               font=f_small, fill=(16, 32, 48))

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "卡内顺序_核对.png")
    sheet.save(out)
    print("saved:", out)
    for i, (lcn, fn, _) in enumerate(items):
        print("  第%d张 %s  LCN=0x%X" % (i + 1, fn, lcn))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "I:" + os.sep)
