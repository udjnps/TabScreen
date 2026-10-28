#!/usr/bin/env python3
import os
import math
from PIL import Image, ImageDraw, ImageFilter

def create_android_icon(is_round=False):
    size = 512
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = 24
    if is_round:
        draw.ellipse([margin, margin, size - margin, size - margin], fill=(20, 20, 28, 255))
        # Outer neon border
        draw.ellipse([margin, margin, size - margin, size - margin], outline=(10, 132, 255, 255), width=8)
    else:
        # Modern squircle rounded rectangle
        draw.rounded_rectangle([margin, margin, size - margin, size - margin], radius=110, fill=(20, 20, 28, 255))
        draw.rounded_rectangle([margin, margin, size - margin, size - margin], radius=110, outline=(10, 132, 255, 255), width=8)

    # Tablet frame inside
    t_left = 68
    t_top = 80
    t_right = size - 68
    t_bottom = size - 80
    t_radius = 42

    # Tablet shadow / glow
    draw.rounded_rectangle([t_left, t_top, t_right, t_bottom], radius=t_radius, fill=(32, 32, 44, 255), outline=(90, 200, 250, 220), width=6)

    # Tablet Screen
    s_left = t_left + 16
    s_top = t_top + 16
    s_right = t_right - 16
    s_bottom = t_bottom - 16
    s_radius = 28

    # Create screen image with vibrant macOS gradient
    screen_w = s_right - s_left
    screen_h = s_bottom - s_top
    screen_img = Image.new("RGBA", (screen_w, screen_h), (0, 0, 0, 0))
    screen_draw = ImageDraw.Draw(screen_img)

    # macOS Ventura / Sonoma vibrant wallpaper gradient (Cyan -> Blue -> Purple)
    for y in range(screen_h):
        r_ratio = y / screen_h
        r = int(10 + (120 - 10) * r_ratio)
        g = int(110 + (40 - 110) * r_ratio)
        b = int(245 + (220 - 245) * r_ratio)
        screen_draw.line([(0, y), (screen_w, y)], fill=(r, g, b, 255))

    # Add subtle wave / abstract graphic on the screen
    for x in range(screen_w):
        y_wave = int(screen_h * 0.6 + math.sin(x * 0.03) * 24)
        screen_draw.line([(x, y_wave), (x, screen_h)], fill=(255, 100, 180, 70))

    # Mac Window Traffic Lights (Red, Yellow, Green dots) at top left of screen
    dot_y = 18
    dot_r = 7
    screen_draw.ellipse([18 - dot_r, dot_y - dot_r, 18 + dot_r, dot_y + dot_r], fill=(255, 95, 86, 255))
    screen_draw.ellipse([38 - dot_r, dot_y - dot_r, 38 + dot_r, dot_y + dot_r], fill=(255, 189, 46, 255))
    screen_draw.ellipse([58 - dot_r, dot_y - dot_r, 58 + dot_r, dot_y + dot_r], fill=(39, 201, 63, 255))

    # Mask screen to rounded rect
    mask = Image.new("L", (screen_w, screen_h), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, screen_w, screen_h], radius=s_radius, fill=255)

    img.paste(screen_img, (s_left, s_top), mask)

    # Center lightning / connection badge (Thunderbolt speed)
    badge_x = size // 2
    badge_y = size // 2 + 10
    poly = [
        (badge_x + 8, badge_y - 45),
        (badge_x - 22, badge_y + 4),
        (badge_x + 2, badge_y + 4),
        (badge_x - 8, badge_y + 45),
        (badge_x + 22, badge_y - 4),
        (badge_x - 2, badge_y - 4)
    ]
    # Drop shadow
    draw.polygon([(x + 2, y + 3) for x, y in poly], fill=(0, 0, 0, 160))
    # Glowing lightning bolt
    draw.polygon(poly, fill=(255, 255, 255, 255))

    # Camera punch hole on tablet top bezel
    draw.ellipse([size // 2 - 5, t_top + 6, size // 2 + 5, t_top + 14], fill=(15, 15, 20, 255))

    return img

def main():
    base_res = os.path.abspath("android-app/app/src/main/res")
    densities = [
        ("mipmap-mdpi", 48),
        ("mipmap-hdpi", 72),
        ("mipmap-xhdpi", 96),
        ("mipmap-xxhdpi", 144),
        ("mipmap-xxxhdpi", 192),
    ]

    sq_icon = create_android_icon(is_round=False)
    round_icon = create_android_icon(is_round=True)

    for folder, dim in densities:
        d_path = os.path.join(base_res, folder)
        os.makedirs(d_path, exist_ok=True)

        # Standard icon
        sq_resized = sq_icon.resize((dim, dim), Image.Resampling.LANCZOS)
        sq_resized.save(os.path.join(d_path, "ic_launcher.png"), "PNG")

        # Round icon
        round_resized = round_icon.resize((dim, dim), Image.Resampling.LANCZOS)
        round_resized.save(os.path.join(d_path, "ic_launcher_round.png"), "PNG")

        print(f"Generated {dim}x{dim} icons in {folder}")

    print("✅ All Android app icons successfully generated!")

if __name__ == "__main__":
    main()
