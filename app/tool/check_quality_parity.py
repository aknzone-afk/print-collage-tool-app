# Companion to check_quality_parity.dart — exercises libjpeg-turbo (the
# same codec family Android/Skia uses) at the app's settings, and verifies
# the DPI stamp reads back as 350 in a PIL/Photoshop-style reader.
import math
import os
import sys

from PIL import Image, ImageChops


def psnr(a, b):
    diff = ImageChops.difference(a, b)
    h = diff.histogram()
    n = a.size[0] * a.size[1] * 3
    se = 0
    for ch in range(3):
        for v in range(256):
            se += h[ch * 256 + v] * v * v
    mse = se / n
    return 99 if mse == 0 else 10 * math.log10(255 * 255 / mse)


def main():
    if sys.argv[1] == "--dpi":
        d = sys.argv[2]
        im = Image.open(os.path.join(d, "pil_q90_420_stamped.jpg"))
        print("stamped dpi:", im.info.get("dpi"), "size:", im.size)
        return
    d = sys.argv[1]
    raw = Image.open(os.path.join(d, "linear.png")).convert("RGB")
    out = os.path.join(d, "pil_q90_420.jpg")
    # quality=90, subsampling=2 (4:2:0) — the app's native-lane settings.
    raw.save(out, "JPEG", quality=90, subsampling=2)
    enc = Image.open(out).convert("RGB")
    mb = os.path.getsize(out) / 1024 / 1024
    print(f"libjpeg q90 4:2:0: {mb:.2f} MB")
    print(f"PSNR new-final vs its raw: {psnr(raw, enc):.2f} dB")
    # Cross-check: old final vs new final, decoded (upscaler+encoder both differ)
    old = Image.open(os.path.join(d, "dart_q90_420.jpg")).convert("RGB")
    print(f"PSNR old-final vs new-final: {psnr(old, enc):.2f} dB")


if __name__ == "__main__":
    main()
