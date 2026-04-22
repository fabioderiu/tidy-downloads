"""Generate the macOS app icon (.icns) from an emoji using AppKit."""

import os
import subprocess
import sys

def main():
    app_path = "/Applications/Sortwise.app"
    iconset = "/tmp/Sortwise.iconset"
    icns_path = f"{app_path}/Contents/Resources/AppIcon.icns"

    # Check if icon already exists
    if os.path.exists(icns_path):
        return

    os.makedirs(iconset, exist_ok=True)

    try:
        import objc
        from AppKit import (
            NSImage, NSBitmapImageRep, NSFont,
            NSMakeRect, NSString, NSColor,
            NSFontAttributeName, NSForegroundColorAttributeName,
            NSParagraphStyleAttributeName, NSMutableParagraphStyle,
            NSBezierPath, NSPNGFileType,
        )
        from Foundation import NSSize, NSPoint, NSDictionary
    except ImportError:
        print("  ⚠ PyObjC not available — skipping icon generation (app will use default icon)")
        return

    def make_icon(size, filename):
        img = NSImage.alloc().initWithSize_(NSSize(size, size))
        img.lockFocus()

        bg = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.2, 0.5, 1.0, 1.0)
        bg.setFill()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(0, 0, size, size), size * 0.2, size * 0.2
        )
        path.fill()

        emoji = NSString.stringWithString_("🧹")
        font_size = size * 0.65
        font = NSFont.systemFontOfSize_(font_size)
        style = NSMutableParagraphStyle.alloc().init()
        style.setAlignment_(1)
        attrs = NSDictionary.dictionaryWithObjects_forKeys_(
            [font, NSColor.whiteColor(), style],
            [NSFontAttributeName, NSForegroundColorAttributeName, NSParagraphStyleAttributeName],
        )
        emoji_size = emoji.sizeWithAttributes_(attrs)
        x = (size - emoji_size.width) / 2
        y = (size - emoji_size.height) / 2
        emoji.drawAtPoint_withAttributes_(NSPoint(x, y), attrs)

        img.unlockFocus()

        tiff = img.TIFFRepresentation()
        rep = NSBitmapImageRep.imageRepWithData_(tiff)
        png = rep.representationUsingType_properties_(NSPNGFileType, None)
        png.writeToFile_atomically_(os.path.join(iconset, filename), True)

    entries = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    for size, name in entries:
        make_icon(size, name)

    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns_path], check=True)
    print(f"  ✅ App icon generated")

    # Cleanup
    import shutil
    shutil.rmtree(iconset, ignore_errors=True)

if __name__ == "__main__":
    main()
