#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 4.4 兼容的传统 PNG launcher 图标（§6.1 图标兜底）。

背景：仓库原先只有 mipmap-anydpi(-v26) 里的 <vector>/adaptive-icon。矢量 launcher
图标在 API<21（Android 4.4）**无法被 PackageManager/Launcher 解析**——装包时读不出
图标，是"装包图标不显示"乃至"解析包/文件出错"体验的一部分。传统位图 PNG 是 4.4
唯一稳妥的 launcher 图标形态。

本脚本用纯 stdlib（zlib+struct，无 PIL 依赖，可在任意 Python3 直接跑）绘制与
res/drawable/ic_launcher_foreground.xml 同款的"屏幕+播放三角"标记，输出到密度目录：
  mipmap-mdpi/48, mipmap-hdpi/72, mipmap-xhdpi/96, mipmap-xxhdpi/144
（外加 xxxhdpi/192 更清晰）。方形 ic_launcher 与圆形 ic_launcher_round 各一套。

设计：#000000 底 + #3DDC84 圆角"屏幕"块 + 黑色播放三角，与矢量前景一致，纯色/简单
图形即可（本任务只要求可解析、能显示，不追求视觉精细）。
"""
import os
import struct
import zlib

# 与 ic_launcher_foreground.xml 一致的配色。
BG = (0, 0, 0, 255)          # 黑底
GREEN = (0x3D, 0xDC, 0x84, 255)  # 屏幕块
TRI = (0, 0, 0, 255)         # 播放三角（黑）

# viewport 108 坐标系里的关键几何（对齐矢量 pathData）。
VP = 108.0
SCREEN = (24.0, 34.0, 84.0, 70.0)  # 左,上,右,下（含 4 圆角，这里用直角近似）
TRI_PTS = [(48.0, 44.0), (64.0, 52.0), (48.0, 60.0)]


def _point_in_tri(px, py, pts):
    (x1, y1), (x2, y2), (x3, y3) = pts
    d = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
    if d == 0:
        return False
    a = ((y2 - y3) * (px - x3) + (x3 - x2) * (py - y3)) / d
    b = ((y3 - y1) * (px - x3) + (x1 - x3) * (py - y3)) / d
    c = 1 - a - b
    return a >= 0 and b >= 0 and c >= 0


def _make_pixels(size, round_icon):
    s = float(size)
    scale = s / VP
    lx, ty, rx, by = (v * scale for v in SCREEN)
    tri = [(x * scale, y * scale) for (x, y) in TRI_PTS]
    r = s / 2.0
    cx = cy = r
    corner = 6.0 * scale  # 屏幕块圆角半径

    rows = bytearray()
    for y in range(size):
        rows.append(0)  # PNG filter type 0
        for x in range(size):
            fx, fy = x + 0.5, y + 0.5
            # 圆形图标：圆外透明（4.4 会按 anydpi 之外的密度目录取此 PNG）。
            if round_icon and ((fx - cx) ** 2 + (fy - cy) ** 2) > r * r:
                rows += bytes((0, 0, 0, 0))
                continue
            col = BG
            if lx <= fx <= rx and ty <= fy <= by:
                # 圆角矩形：四角圆弧外的像素归背景。
                inx = min(fx - lx, rx - fx)
                iny = min(fy - ty, by - fy)
                in_corner = inx < corner and iny < corner
                if not in_corner or ((corner - inx) ** 2 + (corner - iny) ** 2) <= corner * corner:
                    col = GREEN
            if _point_in_tri(fx, fy, tri):
                col = TRI
            rows += bytes(col)
    return bytes(rows)


def _write_png(path, size, round_icon):
    raw = _make_pixels(size, round_icon)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(raw, 9)
    png = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    res = os.path.normpath(os.path.join(here, "..", "app", "src", "main", "res"))
    for dens, size in DENSITIES.items():
        d = os.path.join(res, "mipmap-" + dens)
        os.makedirs(d, exist_ok=True)
        _write_png(os.path.join(d, "ic_launcher.png"), size, round_icon=False)
        _write_png(os.path.join(d, "ic_launcher_round.png"), size, round_icon=True)
        print("wrote", d, size)


if __name__ == "__main__":
    main()
