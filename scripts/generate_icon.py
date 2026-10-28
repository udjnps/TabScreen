#!/usr/bin/env python3
import os
import shutil
import subprocess
from PIL import Image, ImageDraw

def create_icon():
    size = 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background squircle
    margin = 80
    rect = [margin, margin, size - margin, size - margin]
    draw.rounded_rectangle(rect, radius=200, fill=(24, 24, 30, 255))

    # Inner tablet bezel
    t_margin = 160
    t_rect = [t_margin, t_margin, size - t_margin, size - t_margin]
    draw.rounded_rectangle(t_rect, radius=120, fill=(38, 38, 48, 255), outline=(10, 132, 255, 255), width=12)

    # Tablet screen display (vibrant Mac blue/purple gradient)
    s_margin = 210
    for y in range(s_margin, size - s_margin):
        ratio = (y - s_margin) / (size - 2 * s_margin)
        r = int(14 + (88 - 14) * ratio)
        g = int(120 + (50 - 120) * ratio)
        b = int(240 + (220 - 240) * ratio)
        draw.line([(s_margin, y), (size - s_margin, y)], fill=(r, g, b, 255))

    # Display stand / Mac indicator
    stand_w = 120
    draw.polygon([
        ((size - stand_w) // 2, size - t_margin + 10),
        ((size + stand_w) // 2, size - t_margin + 10),
        ((size + stand_w + 40) // 2, size - margin - 20),
        ((size - stand_w - 40) // 2, size - margin - 20)
    ], fill=(60, 60, 75, 255))

    # Iconset dir
    iconset_dir = "/tmp/TabScreen.iconset"
    if os.path.exists(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir)

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for filename, s in sizes:
        resized = img.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, filename))

    out_icns = "/Applications/TabScreen.app/Contents/Resources/AppIcon.icns"
    os.makedirs(os.path.dirname(out_icns), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", out_icns], check=True)
    shutil.rmtree(iconset_dir)
    print("Generated AppIcon.icns successfully!")

if __name__ == "__main__":
    create_icon()
