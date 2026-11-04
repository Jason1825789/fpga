#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_display_bmp.py — 由源图生成 TF 卡用的 640x480 显示素材

流程（一次跑完，可重复执行）:
    源图 jpg → 等比裁切 640x480 → 椭圆羽化遮罩 → 右上角地名标签 → BMP

为什么合成一个脚本:
    地名是画进 BMP 的，不是 OSD 图层。如果只在成品 BMP 上重复叠字，
    以后改字号/改名就会糊；从源图重跑才能保证每次都干净。

椭圆参数（2026-11-02 与用户逐轮确认）:
    620 x 360，中心 (320,250)，10px 高斯羽化，圆外 #F0F0F0
    顶部给状态条/时间戳留 22px，底部给红条字幕留 30px

用法:
    python gen_display_bmp.py                 # 有地名 → 有名字/
    python gen_display_bmp.py --no-tag        # 无地名 → 椭圆羽化无名字/
    python gen_display_bmp.py --dry           # 只处理前 2 张，文件名带 _dry_ 前缀
    python gen_display_bmp.py --out DIR       # 指定输出目录
"""
import sys
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "源图"
OUT_TAG = ROOT / "有名字1"        # 隶书版
OUT_SERIF = ROOT / "有名字2"      # 宋体骨架艺术字版
OUT_PLAIN = ROOT / "椭圆羽化无名字"

W, H = 640, 480
EW, EH = 620, 360
CX, CY = 320, 250
FEATHER = 10
BG = (240, 240, 240)
SS = 4

FONT_PATH = r"C:/Windows/Fonts/NotoSansSC-VF.ttf"
TAG_SIZE = 28
TAG_WEIGHT = 500
TAG_COLOR = (16, 32, 48)
TAG_PAD_RIGHT = 24
TAG_PAD_TOP = 14

# ---- 地名标签样式（2026-11-02 第二轮：隶书三段式）----
CN_FONT = r"C:/Windows/Fonts/simli.ttf"        # 隶书，蚕头燕尾
EN_FONT = r"C:/Windows/Fonts/times.ttf"        # 衬线体，配隶书更稳
CN_SIZE = 32
EN_SIZE = 12
CN_COLOR = (16, 32, 48)                        # 与 OSD 状态条同色
EN_COLOR = (86, 104, 120)                      # 浅一档，做层级
RULE_COLOR = (150, 162, 172)
RULE_W = 2
CN_TOP = 11
RULE_DY = 39          # 细线相对中文顶部的偏移
EN_DY = 5             # 英文相对细线的偏移

# ---- 地名标签样式（2026-11-02 第三轮：宋体骨架定制艺术字）----
# 华文中宋为骨架, 3x 渲染后垂直拉伸使笔画修长, 轻微右倾带一点书写笔意。
SERIF_CN_SIZE = 34    # 宋体字面比隶书略小, 用 34 才能与 32px 隶书视觉等高
SERIF_CN_TOP = 10
SERIF_TRACKING = 0.12
RULE_GAP_TOP = 5      # 细线与中文底部的间距

# 宋体版专用地名（只影响 --serif 输出，隶书版仍用 PICKS 里的名字）
# 02 是低角度金光，08 是通透蓝天，按画面事实区分晨暮
SERIF_NAME_OVERRIDE = {
    "02.bmp": "佛香阁·暮",
    "08.bmp": "佛香阁·晨",
}

# (源图, 输出, 地名, 英文名)
PICKS = [
    ("c14.jpg", "01.bmp", "万寿山",   "Longevity Hill"),
    ("c2.jpg",  "02.bmp", "佛香阁",   "Tower of Buddhist Incense"),
    ("c5.jpg",  "03.bmp", "十七孔桥", "Seventeen-Arch Bridge"),
    ("c4.jpg",  "04.bmp", "石舫",     "Marble Boat"),
    ("c8.jpg",  "05.bmp", "清晏舫",   "Qingyan Boat"),
    ("c6.jpg",  "06.bmp", "廓如亭",   "Kuoru Pavilion"),
    ("c11.jpg", "07.bmp", "长廊",     "Long Corridor"),
    ("c3.jpg",  "08.bmp", "佛香阁远眺", "Tower of Buddhist Incense"),
]


def make_mask():
    """620x360 椭圆，4 倍超采样抗锯齿，再高斯羽化。"""
    m = Image.new("L", (W * SS, H * SS), 0)
    d = ImageDraw.Draw(m)
    a, b = EW * SS // 2, EH * SS // 2
    d.ellipse([CX * SS - a, CY * SS - b, CX * SS + a, CY * SS + b], fill=255)
    return m.resize((W, H), Image.LANCZOS).filter(ImageFilter.GaussianBlur(FEATHER))


def crop_center(im):
    """等比缩放到覆盖 640x480 后中心裁切（不拉伸）。"""
    w, h = im.size
    scale = max(W / w, H / h)
    nw, nh = int(w * scale + 0.5), int(h * scale + 0.5)
    im = im.resize((nw, nh), Image.LANCZOS)
    left = (nw - W) // 2
    top = (nh - H) // 2
    return im.crop((left, top, left + W, top + H))


def draw_tag(im, cn, en):
    """三段式地名标签：隶书中文 → 细线 → 英文小字，整体右对齐。"""
    d = ImageDraw.Draw(im)
    right = W - TAG_PAD_RIGHT
    fc = ImageFont.truetype(CN_FONT, CN_SIZE)
    fe = ImageFont.truetype(EN_FONT, EN_SIZE)

    d.text((right, CN_TOP), cn, font=fc, fill=CN_COLOR, anchor="ra")
    cn_w = d.textlength(cn, font=fc)
    # 线宽固定跟随中文：8 张里线长只随地名长度变化，不会被长英文拉长，
    # 轮播时不会出现时宽时窄的跳动。英文仍右对齐，长名自然向左延伸。
    rule_y = CN_TOP + RULE_DY
    d.line([(right - cn_w, rule_y), (right, rule_y)], fill=RULE_COLOR, width=RULE_W)
    d.text((right, rule_y + EN_DY), en, font=fe, fill=EN_COLOR, anchor="ra")
    return im


def draw_tag_serif(im, cn, en):
    """宋体骨架艺术字版：中文由 artfont 渲染成 alpha 掩膜后压入，其余同隶书版。"""
    import artfont

    right = W - TAG_PAD_RIGHT
    alpha = artfont.render_line(cn, SERIF_CN_SIZE, tracking=SERIF_TRACKING)
    im = artfont.paste_ink(im, alpha, (right, SERIF_CN_TOP), CN_COLOR, anchor="ra")

    d = ImageDraw.Draw(im)
    rule_y = SERIF_CN_TOP + SERIF_CN_SIZE + RULE_GAP_TOP
    d.line([(right - alpha.width, rule_y), (right, rule_y)],
           fill=RULE_COLOR, width=RULE_W)
    fe = ImageFont.truetype(EN_FONT, EN_SIZE)
    d.text((right, rule_y + EN_DY), en, font=fe, fill=EN_COLOR, anchor="ra")
    return im


def main():
    dry = "--dry" in sys.argv
    no_tag = "--no-tag" in sys.argv
    serif = "--serif" in sys.argv

    if no_tag:
        out = OUT_PLAIN
    elif serif:
        out = OUT_SERIF
    else:
        out = OUT_TAG
    if "--out" in sys.argv:
        out = Path(sys.argv[sys.argv.index("--out") + 1])
    out.mkdir(exist_ok=True)

    mask = make_mask()
    bg = Image.new("RGB", (W, H), BG)

    items = PICKS[:2] if dry else PICKS
    print(f"输出目录: {out}")
    print(f"{'输出':<10}{'源图':<12}{'地名':<14}{'英文':<30}")
    for src_name, dst_name, cn, en in items:
        p = SRC / src_name
        if not p.exists():
            raise SystemExit(f"源图缺失: {p}")
        if serif:
            cn = SERIF_NAME_OVERRIDE.get(dst_name, cn)
        im = Image.open(p).convert("RGB")
        im = crop_center(im)
        im = Image.composite(im, bg, mask)
        if serif:
            im = draw_tag_serif(im, SERIF_NAME_OVERRIDE.get(dst_name, cn), en)
        elif not no_tag:
            im = draw_tag(im, cn, en)
        dst = (out / f"_dry_{dst_name}") if dry else (out / dst_name)
        im.save(dst, "BMP")
        print(f"{dst.name:<10}{src_name:<12}{cn:<14}{en:<30}{os.path.getsize(dst):,} B")

    print("完成" if not dry else "dry 模式：仅生成带 _dry_ 前缀的文件供核对")


if __name__ == "__main__":
    main()
