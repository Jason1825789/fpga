#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""宋体骨架定制艺术字渲染器。

对应四个设计诉求:
  宋体骨架    → 华文中宋 STZHONGS (标题宋, 横细竖粗天然明显)
  横细竖粗    → 单字重渲染后仅对竖笔做水平膨胀, 横笔不动
  笔画修长    → 高分辨率下垂直拉伸 STRETCH_Y
  转折精致    → 4x 超采样 + LANCZOS 降采样
  少量书法笔意 → 整体轻微右倾 SHEAR + 起收笔柔化 SOFTEN

对外接口:
  render_line(text, target_h, tracking, dilate_px, ...) -> alpha 掩膜 (255 = 墨)
  paste_ink(bg, alpha, xy, color, anchor)               -> 合成到图片
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SERIF = r"C:/Windows/Fonts/STZHONGS.TTF"   # 华文中宋

R_HI = 102          # 渲染字号 = 3x 目标字高。实测 7x(240px) 缩小后笔画发灰,
                    # 3x 既保留衬线细节又不丢锐度
STRETCH_Y = 1.10    # 垂直拉伸, 越大笔画越修长
SHEAR = -0.030      # 斜切量, 负值向右倾(书写感)
SOFTEN = 0.0        # 起收笔柔化(高分辨率像素)。缩放本身已带抗锯齿, 再模糊会发灰
DILATE_PX = 0.0     # 竖笔加粗量, 单位=最终显示像素。宋体本身已横细竖粗,
                    # 再膨胀会把横画两端也外扩(实测"M"字上横被拉长), 默认关闭。
ERO_K_HI = 16       # 竖笔判定核(高分辨率像素)


def _render(ch: str, size: int = R_HI) -> Image.Image:
    font = ImageFont.truetype(SERIF, size)
    W = H = size * 3
    cv = Image.new("L", (W, H), 0)
    ImageDraw.Draw(cv).text((W // 2, H * 2 // 3), ch, font=font, fill=255, anchor="ms")
    bbox = cv.getbbox()
    return cv.crop(bbox) if bbox else Image.new("L", (size, size), 0)


def _morph_h(a: np.ndarray, k: int, mode: str) -> np.ndarray:
    out = a.copy()
    for d in range(1, k + 1):
        f = np.minimum if mode == "erode" else np.maximum
        out = f(out, np.roll(a, d, axis=1))
        out = f(out, np.roll(a, -d, axis=1))
    return out


def _shear(im: Image.Image, amount: float) -> Image.Image:
    """以底边为支点做水平斜切, 顶端偏移 amount*字高。"""
    w, h = im.size
    dx = amount * h
    pad = int(abs(dx)) + 3
    src = Image.new("L", (w + pad * 2, h), 0)
    src.paste(im, (pad, 0))
    out = Image.new("L", (w + pad * 2, h), 0)
    for y in range(h):
        shift = int(round(dx * (1 - y / max(1, h - 1))))
        out.paste(src.crop((0, y, src.width, y + 1)), (shift, y))
    bbox = out.getbbox()
    return out.crop(bbox) if bbox else out


def glyph_alpha(ch: str, stretch_y: float = STRETCH_Y, shear: float = SHEAR,
                soften: float = SOFTEN, dilate_px: float = DILATE_PX,
                target_h: int = 34) -> Image.Image:
    """单字 alpha 掩膜 (255 = 墨), 高分辨率, 未缩放。"""
    a = np.asarray(_render(ch), dtype=np.float32)

    if dilate_px > 0:
        # 最终尺寸下的加粗量 → 高分辨率像素 (左右各扩 k 即加粗 2k)
        k = max(1, int(round(dilate_px * (R_HI / target_h) / 2)))
        v = np.clip(a - _morph_h(a, ERO_K_HI, "erode"), 0, 255)
        v = _morph_h(v, k, "dilate")
        a = np.maximum(a, v)

    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "L")
    if soften > 0:
        im = im.filter(ImageFilter.GaussianBlur(soften))
    if abs(stretch_y - 1.0) > 1e-3:
        im = im.resize((max(1, int(round(im.width / stretch_y))), im.height),
                       Image.LANCZOS)
    if abs(shear) > 1e-3:
        im = _shear(im, shear)
    return im


def _ref_height() -> int:
    """参考字高: 用"国"的墨迹高度作为满格汉字标尺。

    逐字按各自墨迹高度缩放是错的: "·" 的墨迹只有 17px 高, 按字高归一化会把它
    放大成一个 30px 的实心黑点。整行统一按汉字标尺缩放才对。
    """
    return _render("国").height


def render_line(text: str, target_h: int, tracking: float = 0.0, **kw) -> Image.Image:
    """整行 alpha 掩膜 (255 = 墨)。

    逐字按字体自身 advance 排布(标点、括号的相对位置由字体决定), 整行统一按
    "国"字墨迹高度缩放到 target_h, 因此标点不会被单独放大。
    tracking 为字距/字高比, 叠加在字体 advance 之上。
    """
    stretch_y = kw.pop("stretch_y", STRETCH_Y)
    shear = kw.pop("shear", SHEAR)

    font = ImageFont.truetype(SERIF, R_HI)
    ref_h = _ref_height()
    pad = R_HI // 2
    total_w = int(sum(font.getlength(c) for c in text) + abs(tracking) * R_HI * len(text)) + pad * 2

    cv = Image.new("L", (total_w, R_HI * 2), 0)
    d = ImageDraw.Draw(cv)
    x = float(pad)
    base_y = R_HI * 1.4
    for ch in text:
        d.text((x, base_y), ch, font=font, fill=255, anchor="ls")
        x += font.getlength(ch) + tracking * R_HI

    bbox = cv.getbbox()
    if bbox is None:
        return Image.new("L", (target_h, target_h), 0)
    im = cv.crop(bbox)

    # 拉伸与斜切都在高分辨率下完成, 最后一步才缩到目标字高, 避免二次重采样发糊
    if abs(stretch_y - 1.0) > 1e-3:
        im = im.resize((max(1, int(round(im.width / stretch_y))), im.height),
                       Image.LANCZOS)
    if abs(shear) > 1e-3:
        im = _shear(im, shear)

    # 整行统一缩放: 让一个满格汉字正好等于 target_h
    sc = target_h / ref_h
    im = im.resize((max(1, int(round(im.width * sc))),
                    max(1, int(round(im.height * sc)))), Image.LANCZOS)
    return im


def paste_ink(bg: Image.Image, alpha: Image.Image, xy, color=(16, 32, 48),
              anchor: str = "ra") -> Image.Image:
    """把 alpha 墨迹按 color 贴到 bg 上, anchor 支持 ra / la / mm。"""
    bg = bg.convert("RGB")
    if anchor == "ra":
        pos = (xy[0] - alpha.width, xy[1])
    elif anchor == "la":
        pos = (xy[0], xy[1])
    else:
        pos = xy
    bg.paste(Image.new("RGB", alpha.size, color), pos, alpha)
    return bg
