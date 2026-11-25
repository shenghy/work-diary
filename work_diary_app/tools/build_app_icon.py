# -*- coding: utf-8 -*-
"""从方角母图生成圆角图标（桌面 app_icon.ico + 托盘/安装包 tray.ico）。

用法（在 work_diary_app 目录下）：
    python tools/build_app_icon.py                # 重建两个 ico
    python tools/build_app_icon.py --preview DIR  # 额外输出目测样张

打包前必须重跑一次：
- windows/runner/resources/app_icon.ico → 桌面/任务栏/窗口标题栏/气泡窗图标
- assets/icons/tray.ico → 托盘图标（app_lifecycle.dart），同时是 installer.iss
  的 SetupIconFile（安装包 exe 自己的图标）
以后每次打包的圆角图标由本脚本保证，不要手工替换 ico 文件。
"""

import argparse
import pathlib

from PIL import Image, ImageDraw

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "assets" / "icon" / "app_icon.png"
DST = REPO / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY_DST = REPO / "assets" / "icons" / "tray.ico"

# 圆角半径 = 边长 × 该比例（母图 1024 → 205px，256 → 52px）
CORNER_RATIO = 0.20
# 小尺寸直接缩会毛刺，先按 4 倍超采样画遮罩再缩到目标尺寸
SUPERSAMPLE = 4
SIZES = (256, 128, 64, 48, 32, 24, 16)
# 托盘/安装包：系统托盘常用 16~24，安装包里取 32~48
TRAY_SIZES = (64, 48, 32, 24, 16)


def rounded_mask(side: int, ratio: float = CORNER_RATIO) -> Image.Image:
    r = max(1, round(side * ratio))
    big = side * SUPERSAMPLE
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=r * SUPERSAMPLE, fill=255
    )
    return m.resize((side, side), Image.LANCZOS)


def rounded(src: Image.Image, side: int) -> Image.Image:
    im = src.resize((side, side), Image.LANCZOS).convert("RGBA")
    im.putalpha(rounded_mask(side))
    return im


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", type=pathlib.Path, help="样张输出目录")
    args = parser.parse_args()

    src = Image.open(SRC).convert("RGB")
    if src.size != (1024, 1024):
        raise SystemExit(f"母图尺寸异常：{src.size}（期望 1024x1024）")

    images = [rounded(src, s) for s in SIZES]
    DST.parent.mkdir(parents=True, exist_ok=True)
    images[0].save(
        DST,
        format="ICO",
        append_images=images[1:],
        sizes=[(s, s) for s in SIZES],
    )
    print(f"已生成 {DST}（{DST.stat().st_size} B，{len(SIZES)} 个尺寸，圆角 {CORNER_RATIO:.0%}）")

    tray = [rounded(src, s) for s in TRAY_SIZES]
    TRAY_DST.parent.mkdir(parents=True, exist_ok=True)
    tray[0].save(
        TRAY_DST,
        format="ICO",
        append_images=tray[1:],
        sizes=[(s, s) for s in TRAY_SIZES],
    )
    print(
        f"已生成 {TRAY_DST}（{TRAY_DST.stat().st_size} B，{len(TRAY_SIZES)} 个尺寸，"
        "托盘 + 安装包 SetupIconFile 共用）"
    )

    if args.preview:
        out = args.preview
        out.mkdir(parents=True, exist_ok=True)
        for name, side in (
            ("preview_256.png", 256),
            ("preview_48.png", 48),
            ("preview_32.png", 32),
            ("preview_16.png", 16),
        ):
            tile = rounded(src, side)
            # 深/浅两种桌面底色各铺一张，透明四角才看得出效果
            for bg_name, bg in (("dark", (35, 38, 46)), ("light", (238, 240, 244))):
                canvas = Image.new("RGB", (side * 3 + 32, side + 32), bg)
                canvas.paste(tile, (8, 16), tile)
                canvas.paste(tile, (side + 16, 16), tile)
                canvas.paste(tile, (side * 2 + 24, 16), tile)
                canvas.save(out / f"{name[:-4]}_{bg_name}.png")
        print(f"样张已输出到 {out}")


if __name__ == "__main__":
    main()
