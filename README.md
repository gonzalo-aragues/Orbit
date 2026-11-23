# Orbit

A menu-bar app for macOS 26+. Hold **⌥ Option** while dragging any file and a Liquid Glass ring opens under the cursor; ordinary drags are left alone. Drop the file on a segment to convert it or open a quick editor. The result is saved to your Desktop. Uncheck **Save to Desktop** in the menu-bar menu to save next to the original instead.

## Build & run

```bash
./build.sh            # builds Orbit.app here
./build.sh --install  # also copies it to /Applications
open Orbit.app
```

Orbit lives in the menu bar (◎). From there you can pause it, choose where results go, change how quickly the ring appears, open the ring for a chosen file, and turn on Launch at Login.

## Using the ring

- **Drag a file while holding ⌥ Option**: the ring appears, with the file size in the hub. Let go of ⌥ before dropping and the ring closes (press it again to bring it back).
- **Hover a segment**: it turns orange and its name shows in the hub. Drop to run it.
- **Switch rings**: press **⇧ Shift** while dragging, or leave the hub and rest back on it for half a second.
- **Cancel**: drop on the hub, or drag far away and the ring gets out of the way.

| File | Convert ring | Tools ring |
|---|---|---|
| Image | PNG/JPG · WEBP · HEIC · TIFF · AVIF · BMP · PDF · DOCX (OCR) | Compress · Metadata · Edit · Annotate · Add BG · Crop · Redact |
| PDF | DOCX · JPG · PNG · TXT (OCR fallback for scans) | Compress · Metadata · Rotate · Split |
| Video | MP4 · MOV · GIF · M4A | Compress · Metadata · Mute |
| Audio | M4A · WAV · AIFF | Metadata · Copy Path |
| Document (docx, rtf, txt, md, html) | PDF · DOCX · TXT · RTF · HTML | Metadata · Copy Path |
| Anything else | ZIP · Copy Path | |

Output names follow the original: `Page 001.pdf` → `Page 001.jpg` → `Page 001 Cropped.jpg` → `Page 001 Cropped With Background.png`. Existing files are never overwritten.

## Developer flags

```bash
Orbit.app/Contents/MacOS/Orbit --run jpg "Page 001.pdf"        # headless action, prints the output path
Orbit.app/Contents/MacOS/Orbit --ring "Page 001.jpg" --tools   # show the ring in click mode
Orbit.app/Contents/MacOS/Orbit --editor crop "Page 001.jpg"    # open an editor directly
```

## Notes

- WebP output uses the built-in lossless encoder in `WebPEncoder.swift`, because ImageIO can't write WebP.
- The first time Orbit saves into Desktop, Documents or Downloads, macOS asks for permission once.
