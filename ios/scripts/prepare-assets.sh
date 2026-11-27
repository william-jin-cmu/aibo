#!/usr/bin/env bash
# Builds the iOS asset set from this repo's pet atlas and Mac icon.
# Usage: ios/scripts/prepare-assets.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"   # ios/
AIBO="$(cd "$ROOT/.." && pwd)"             # repo root
PET="$ROOT/Shared/Pet"
ICON="$ROOT/Aibo/Assets.xcassets/AppIcon.appiconset"

mkdir -p "$PET" "$ICON"

# 1. Pet frames for the widget, cut from the v2 atlas.
python3 -I - "$AIBO/app/ui/pet/sprites-v2.png" "$AIBO/app/ui/pet/sprites-v2.json" "$PET" <<'PY'
import json, sys
from PIL import Image
atlas, meta, out = sys.argv[1:4]
img = Image.open(atlas).convert("RGBA")
m = json.load(open(meta))
w, h = m["cellWidth"], m["cellHeight"]
keep = {"idle", "waving", "jumping", "failed", "waiting", "running", "review"}
for s in m["states"]:
    if s["name"] not in keep:
        continue
    for i in range(s["frames"]):
        cell = img.crop((i * w, s["row"] * h, (i + 1) * w, (s["row"] + 1) * h))
        cell.save(f"{out}/{s['name']}_{i}.png", optimize=True)
PY

# 2. App icon + chat avatar: the Mac app icon, made full-bleed (iOS applies its own mask).
python3 -I - "$AIBO/app/src-tauri/icons/icon.png" "$ICON/icon-1024.png" "$ROOT/Aibo/Assets.xcassets/Avatar.imageset" <<'PY'
import os, sys
from PIL import Image
src, icon, avatar_dir = sys.argv[1:4]
im = Image.open(src).convert("RGBA")
im = im.crop(im.getchannel("A").getbbox())
bg = Image.new("RGBA", im.size, im.getpixel((im.width // 2, im.height // 5)))
bg.alpha_composite(im)
out = bg.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out.save(icon)
os.makedirs(avatar_dir, exist_ok=True)
out.resize((256, 256), Image.LANCZOS).save(f"{avatar_dir}/avatar.png")
open(f"{avatar_dir}/Contents.json", "w").write('{"images":[{"filename":"avatar.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}\n')
PY
cat > "$ICON/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

du -sh "$PET"
