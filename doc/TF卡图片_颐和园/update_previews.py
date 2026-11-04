#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""为某个素材目录生成 PNG 副本、拼图、带标注预览和内嵌 HTML 画廊。

用法:
    python update_previews.py 有名字2 "宋体骨架艺术字"
"""
import base64
import io
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
NAMES = ["万寿山", "佛香阁", "十七孔桥", "石舫", "清晏舫", "廓如亭", "长廊", "佛香阁远眺"]
EN = ["Longevity Hill", "Tower of Buddhist Incense", "Seventeen-Arch Bridge",
      "Marble Boat", "Qingyan Boat", "Kuoru Pavilion", "Long Corridor",
      "Tower of Buddhist Incense"]
F_UI = r"C:/Windows/Fonts/msyh.ttc"


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "有名字2"
    style = sys.argv[2] if len(sys.argv) > 2 else "宋体骨架艺术字"

    names, ens = NAMES, EN
    if "--serif" in sys.argv:
        # 直接从生成脚本取名字, 避免预览标注与实际标签不一致
        import gen_display_bmp as G
        names = [G.SERIF_NAME_OVERRIDE.get(dst, cn) for _, dst, cn, _ in G.PICKS]
        ens = [en for _, _, _, en in G.PICKS]

    out = ROOT / d
    files = [out / f"{i:02d}.bmp" for i in range(1, 9)]
    for f in files:
        if not f.exists():
            raise SystemExit(f"缺文件: {f}")

    imgs = [Image.open(f).convert("RGB") for f in files]

    # 不再生成逐张 PNG 副本: 目录里 01.bmp / 01_预览.png 成对出现会看起来像重复文件,
    # 而预览面板能直接打开的是下面的 HTML 画廊(内嵌 base64), 不依赖 PNG 副本。

    # 2. 纯拼图
    tw, th = 320, 240
    sheet = Image.new("RGB", (tw * 4, th * 2), (240, 240, 240))
    for i, im in enumerate(imgs):
        sheet.paste(im.resize((tw, th), Image.LANCZOS), ((i % 4) * tw, (i // 4) * th))
    sheet.save(out / "preview.png")

    # 3. 带文件名与地名的标注图
    bar = 28
    lab = Image.new("RGB", (tw * 4, (th + bar) * 2), (245, 245, 245))
    dd = ImageDraw.Draw(lab)
    f1 = ImageFont.truetype(F_UI, 14)
    for i, im in enumerate(imgs):
        col, row = i % 4, i // 4
        x, y = col * tw, row * (th + bar)
        lab.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
        dd.rectangle([x, y + th, x + tw, y + th + bar], fill=(255, 255, 255))
        dd.text((x + 8, y + th + 6), f"{i+1:02d}.bmp  {names[i]}", font=f1, fill=(25, 25, 25))
        dd.rectangle([x, y, x + tw - 1, y + th + bar - 1], outline=(205, 205, 205))
    lab.save(out / "地名版预览.png")

    # 4. HTML 画廊(预览面板里唯一能直接看图的形式)
    cards = []
    for i, im in enumerate(imgs):
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=90)
        b64 = base64.b64encode(buf.getvalue()).decode()
        cards.append(
            f'<figure><img src="data:image/jpeg;base64,{b64}" alt="{names[i]}">'
            f'<figcaption><b>{i+1:02d}.bmp</b><span>{names[i]}</span>'
            f'<em>{ens[i]}</em></figcaption></figure>')

    html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>颐和园素材 · {style}</title>
<style>
 body{{margin:0;padding:26px;background:#f2f2f0;font-family:"Microsoft YaHei",sans-serif;color:#222}}
 h1{{font-size:19px;font-weight:600;margin:0 0 6px}}
 p.meta{{margin:0 0 20px;font-size:13px;color:#666;line-height:1.7}}
 .grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}}
 figure{{margin:0;background:#fff;border:1px solid #dcdcd8;border-radius:6px;overflow:hidden;
        box-shadow:0 1px 3px rgba(0,0,0,.05)}}
 img{{display:block;width:100%;height:auto}}
 figcaption{{display:flex;flex-wrap:wrap;gap:6px;align-items:baseline;padding:8px 11px;
            font-size:12.5px;border-top:1px solid #eee}}
 figcaption b{{font-weight:600;color:#102030;min-width:52px}}
 figcaption span{{color:#333}}
 figcaption em{{font-style:normal;color:#8a8fa0;font-size:11px;width:100%}}
 @media (max-width:1100px){{.grid{{grid-template-columns:repeat(2,1fr)}}}}
</style></head><body>
<h1>颐和园导览素材 · 8 张（{style}）</h1>
<p class="meta">640×480 / 24-bit 无压缩 BMP · 921,654 字节 ·
椭圆 620×360 羽化 10px · 圆外 #F0F0F0<br>
地名：华文中宋骨架，垂直拉伸 1.10、右倾 0.03，34px，颜色 #102030，右对齐距边 24px</p>
<div class="grid">{''.join(cards)}</div>
</body></html>"""
    (out / "素材预览.html").write_text(html, encoding="utf-8")
    print(f"已更新 {out.name}: preview.png、地名版预览.png、素材预览.html")


if __name__ == "__main__":
    main()
