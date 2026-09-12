# -*- coding: utf-8 -*-
"""生成 zremote 安卓启动图标：柑橘晨光渐变 + AI 星芒。

输出：
  mipmap-*/ic_launcher.png     legacy（圆角矩形，48..192）
  mipmap-*/ic_launcher_bg.png  自适应背景（渐变，108dp 全幅）
  mipmap-*/ic_launcher_fg.png  自适应前景（星芒，落在安全区）
  mipmap-anydpi-v26/ic_launcher.xml
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), '..', 'android', 'app', 'src', 'main', 'res')
S = 2048  # 超采样画布

C1 = (255, 198, 80)    # 左上：暖琥珀
C2 = (255, 118, 22)    # 右下：深橙
GLOW = (255, 228, 168)  # 中心提亮


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_canvas():
    """对角渐变 + 中心微光，64 小图放大保证平滑。"""
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126.0
            c = lerp(C1, C2, t)
            d = math.hypot(x / 63.0 - 0.44, y / 63.0 - 0.40) / 0.62
            g = max(0.0, 1.0 - d)
            px[x, y] = lerp(c, GLOW, 0.30 * g)
    return small.resize((S, S), Image.BICUBIC)


def sparkle(cx, cy, radius, rot=0.0, k=0.16, phi=0.28):
    """经典 AI 星芒 ✦：四个尖角，边向圆心深凹（每边一条三次贝塞尔）。"""
    pts = []
    for i in range(4):
        a0 = rot + i * math.pi / 2
        a1 = a0 + math.pi / 2
        p0 = (cx + radius * math.cos(a0), cy + radius * math.sin(a0))
        p3 = (cx + radius * math.cos(a1), cy + radius * math.sin(a1))
        c1 = (cx + k * radius * math.cos(a0 + phi), cy + k * radius * math.sin(a0 + phi))
        c2 = (cx + k * radius * math.cos(a1 - phi), cy + k * radius * math.sin(a1 - phi))
        for j in range(37):
            t = j / 36.0
            u = 1 - t
            x = u**3 * p0[0] + 3 * u*u*t * c1[0] + 3 * u*t*t * c2[0] + t**3 * p3[0]
            y = u**3 * p0[1] + 3 * u*u*t * c1[1] + 3 * u*t*t * c2[1] + t**3 * p3[1]
            pts.append((x, y))
    return pts


def draw_art(scale=1.0, center=(0.5, 0.5), fg_mode=False):
    """在渐变上画星芒。fg_mode 时整体缩小落自适应安全区。"""
    img = gradient_canvas().convert('RGBA')
    cx, cy = center[0] * S, center[1] * S
    if fg_mode:
        big = 0.20 * S * scale
        sx, sy = cx + 0.155 * S, cy - 0.165 * S
        sr = 0.062 * S * scale
        dot = (cx - 0.175 * S, cy + 0.155 * S, 0.030 * S * scale)
    else:
        big = 0.27 * S * scale
        sx, sy = cx + 0.215 * S, cy - 0.225 * S
        sr = 0.085 * S * scale
        dot = (cx - 0.235 * S, cy + 0.215 * S, 0.042 * S * scale)

    star = sparkle(cx, cy, big)
    small = sparkle(sx, sy, sr, rot=math.pi / 4)

    # 柔和投影
    sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(sh)
    d.polygon(star, fill=(168, 62, 0, 110))
    d.polygon(small, fill=(168, 62, 0, 110))
    dx, dy, dr = dot
    d.ellipse([dx - dr, dy - dr, dx + dr, dy + dr], fill=(168, 62, 0, 110))
    sh = sh.filter(ImageFilter.GaussianBlur(S // 90))
    off = round(S * 0.012)
    img.alpha_composite(sh, (0, off))

    # 白色主体
    d = ImageDraw.Draw(img)
    d.polygon(star, fill=(255, 255, 255, 255))
    d.polygon(small, fill=(255, 255, 255, 255))
    dx, dy, dr = dot
    d.ellipse([dx - dr, dy - dr, dx + dr, dy + dr], fill=(255, 255, 255, 255))
    return img


def rounded_mask(radius_ratio=0.225):
    m = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(m)
    r = round(S * radius_ratio)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=r, fill=255)
    return m


LEGACY = {'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
          'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192}
ADAPT = {'mipmap-mdpi': 108, 'mipmap-hdpi': 162, 'mipmap-xhdpi': 216,
         'mipmap-xxhdpi': 324, 'mipmap-xxxhdpi': 432}

# legacy：圆角矩形整图
legacy = draw_art()
mask = rounded_mask()
corner = Image.new('RGBA', (S, S), (0, 0, 0, 0))
corner.paste(legacy, (0, 0), mask)

# 自适应：背景全幅渐变 + 前景星芒（安全区 61%）
fg = draw_art(fg_mode=True)
bg = gradient_canvas().convert('RGBA')

for dirname, size in LEGACY.items():
    out = os.path.join(ROOT, dirname)
    os.makedirs(out, exist_ok=True)
    corner.resize((size, size), Image.LANCZOS).save(os.path.join(out, 'ic_launcher.png'))

for dirname, size in ADAPT.items():
    out = os.path.join(ROOT, dirname)
    os.makedirs(out, exist_ok=True)
    fg.resize((size, size), Image.LANCZOS).save(os.path.join(out, 'ic_launcher_fg.png'))
    bg.resize((size, size), Image.LANCZOS).save(os.path.join(out, 'ic_launcher_bg.png'))

xml_dir = os.path.join(ROOT, 'mipmap-anydpi-v26')
os.makedirs(xml_dir, exist_ok=True)
with open(os.path.join(xml_dir, 'ic_launcher.xml'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@mipmap/ic_launcher_bg"/>\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_fg"/>\n'
            '</adaptive-icon>\n')

# 预览图（人看效果用）
preview = legacy.resize((512, 512), Image.LANCZOS)
pw = Image.new('RGBA', (1080, 560), (250, 247, 240, 255))
pw.paste(preview, (40, 24), preview)
pw.paste(fg.resize((512, 512), Image.LANCZOS).convert('RGBA'), (528, 24),
         fg.resize((512, 512), Image.LANCZOS).convert('RGBA'))
circle = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
m = Image.new('L', (512, 512), 0)
ImageDraw.Draw(m).ellipse([0, 0, 511, 511], fill=255)
circ = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
circ.paste(fg.resize((512, 512), Image.LANCZOS).convert('RGBA'), (0, 0), m)
pw.paste(circ, (40, 24), circ)
pw.save(os.path.join(os.path.dirname(__file__), 'icon_preview.png'))

print('icon done')
