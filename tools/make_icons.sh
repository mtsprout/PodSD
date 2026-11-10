#!/bin/zsh
# Regenerates the Mac app icon (assets/AppIcon.icns) and the web favicon (server/static/favicon.ico)
# from tools/draw_icon.swift. Needs only what ships with macOS + Xcode command line tools.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# --- Mac app icon: an .iconset at every size macOS wants, packed with iconutil ---
mkdir "$T/AppIcon.iconset"
swift tools/draw_icon.swift "$T/app1024.png" 1024 app
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/app1024.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$T/app1024.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p assets
iconutil -c icns "$T/AppIcon.iconset" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns"

# --- Web favicon: PNG-compressed ICO with 16, 32, 48 and 64 px images ---
swift tools/draw_icon.swift "$T/fav256.png" 256 favicon
for s in 16 32 48 64; do sips -z $s $s "$T/fav256.png" --out "$T/fav$s.png" >/dev/null; done
python3 -I - "$T" server/static/favicon.ico <<'PY'
import struct, sys
tmp, out = sys.argv[1], sys.argv[2]
sizes = [16, 32, 48, 64]
imgs = [open(f"{tmp}/fav{s}.png", "rb").read() for s in sizes]
data = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, png in zip(sizes, imgs):
    data += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
open(out, "wb").write(data + b"".join(imgs))
PY
echo "wrote server/static/favicon.ico"
