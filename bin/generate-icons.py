#!/usr/bin/env python3
"""
Generate all required iOS and macOS app icon sizes.

Sources (relative to project root):
  icon-mac.png  — macOS icon, will get rounded squircle corners
  icon-ios.png  — iOS/iPadOS icon, square (iOS applies its own corner mask)

Output: Gpxex/Assets.xcassets/AppIcon.appiconset/
"""

import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(PROJECT_DIR, "Gpxex", "Assets.xcassets", "AppIcon.appiconset")

MAC_SRC = os.path.join(PROJECT_DIR, "icon-mac.png")
IOS_SRC = os.path.join(PROJECT_DIR, "icon-ios.png")

# macOS squircle corner radius ratio (Apple HIG)
RADIUS_RATIO = 0.2237

MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024]
IOS_SIZES  = [40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]

CONTENTS_JSON = """{
  "images" : [
    { "idiom" : "mac",    "scale" : "1x", "size" : "16x16",     "filename" : "mac_16.png"   },
    { "idiom" : "mac",    "scale" : "2x", "size" : "16x16",     "filename" : "mac_32.png"   },
    { "idiom" : "mac",    "scale" : "1x", "size" : "32x32",     "filename" : "mac_32.png"   },
    { "idiom" : "mac",    "scale" : "2x", "size" : "32x32",     "filename" : "mac_64.png"   },
    { "idiom" : "mac",    "scale" : "1x", "size" : "128x128",   "filename" : "mac_128.png"  },
    { "idiom" : "mac",    "scale" : "2x", "size" : "128x128",   "filename" : "mac_256.png"  },
    { "idiom" : "mac",    "scale" : "1x", "size" : "256x256",   "filename" : "mac_256.png"  },
    { "idiom" : "mac",    "scale" : "2x", "size" : "256x256",   "filename" : "mac_512.png"  },
    { "idiom" : "mac",    "scale" : "1x", "size" : "512x512",   "filename" : "mac_512.png"  },
    { "idiom" : "mac",    "scale" : "2x", "size" : "512x512",   "filename" : "mac_1024.png" },
    { "idiom" : "iphone", "scale" : "2x", "size" : "20x20",     "filename" : "ios_40.png"   },
    { "idiom" : "iphone", "scale" : "3x", "size" : "20x20",     "filename" : "ios_60.png"   },
    { "idiom" : "iphone", "scale" : "2x", "size" : "29x29",     "filename" : "ios_58.png"   },
    { "idiom" : "iphone", "scale" : "3x", "size" : "29x29",     "filename" : "ios_87.png"   },
    { "idiom" : "iphone", "scale" : "2x", "size" : "40x40",     "filename" : "ios_80.png"   },
    { "idiom" : "iphone", "scale" : "3x", "size" : "40x40",     "filename" : "ios_120.png"  },
    { "idiom" : "iphone", "scale" : "2x", "size" : "60x60",     "filename" : "ios_120.png"  },
    { "idiom" : "iphone", "scale" : "3x", "size" : "60x60",     "filename" : "ios_180.png"  },
    { "idiom" : "ipad",   "scale" : "2x", "size" : "20x20",     "filename" : "ios_40.png"   },
    { "idiom" : "ipad",   "scale" : "2x", "size" : "29x29",     "filename" : "ios_58.png"   },
    { "idiom" : "ipad",   "scale" : "2x", "size" : "40x40",     "filename" : "ios_80.png"   },
    { "idiom" : "ipad",   "scale" : "1x", "size" : "76x76",     "filename" : "ios_76.png"   },
    { "idiom" : "ipad",   "scale" : "2x", "size" : "76x76",     "filename" : "ios_152.png"  },
    { "idiom" : "ipad",   "scale" : "2x", "size" : "83.5x83.5", "filename" : "ios_167.png"  },
    { "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024", "filename" : "ios_1024.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""


def ensure_pillow():
    try:
        from PIL import Image, ImageDraw
        return Image, ImageDraw
    except ImportError:
        print("Pillow not found — installing into a temporary venv...")
        venv = "/tmp/icongen-venv"
        subprocess.run([sys.executable, "-m", "venv", venv], check=True)
        pip = os.path.join(venv, "bin", "pip")
        subprocess.run([pip, "install", "pillow", "-q"], check=True)
        python = os.path.join(venv, "bin", "python3")
        os.execv(python, [python] + sys.argv)


def make_rounded(img, size, radius_ratio):
    from PIL import Image, ImageDraw
    img = img.resize((size, size), Image.LANCZOS)
    radius = int(size * radius_ratio)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result


def main():
    Image, ImageDraw = ensure_pillow()
    from PIL import Image as PILImage

    os.makedirs(OUT_DIR, exist_ok=True)

    print("macOS icons (rounded):")
    mac_src = PILImage.open(MAC_SRC).convert("RGBA")
    for size in MAC_SIZES:
        out = os.path.join(OUT_DIR, f"mac_{size}.png")
        make_rounded(mac_src, size, RADIUS_RATIO).save(out)
        print(f"  mac_{size}.png")

    print("iOS icons (square):")
    ios_src = PILImage.open(IOS_SRC).convert("RGBA")
    for size in IOS_SIZES:
        out = os.path.join(OUT_DIR, f"ios_{size}.png")
        ios_src.resize((size, size), PILImage.LANCZOS).save(out)
        print(f"  ios_{size}.png")

    contents_path = os.path.join(OUT_DIR, "Contents.json")
    with open(contents_path, "w") as f:
        f.write(CONTENTS_JSON)
    print(f"\nContents.json written.")
    print("Done.")


if __name__ == "__main__":
    main()
