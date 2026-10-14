#!/usr/bin/env bash
# Regenerates App/Assets.xcassets (app icon set + menu bar templates) from stint_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
GEN=scripts/icon/stint_icon.swift
ASSETS=App/Assets.xcassets

# --- app icon: every size macOS wants, as a classic icon set
SET="$ASSETS/AppIcon.appiconset"
mkdir -p "$SET"
rm -f "$SET"/*.png
images=""
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  pt=${spec%%:*}; scale=${spec##*:}; px=$((pt * scale))
  file="icon_${pt}x${pt}@${scale}x.png"
  swift "$GEN" app "$px" "$SET/$file" >/dev/null
  images="$images{\"filename\":\"$file\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${pt}x${pt}\"},"
done
images="$images{\"filename\":\"icon_1024.png\",\"idiom\":\"ios-marketing\",\"scale\":\"1x\",\"size\":\"1024x1024\"},"
swift "$GEN" app 1024 "$SET/icon_1024.png" >/dev/null
printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "${images%,}" > "$SET/Contents.json"

# --- menu bar template (18 pt): ring + stint arc, tinted by the system
rm -rf "$ASSETS/MenuBarIdle.imageset" "$ASSETS/MenuBarRunning.imageset"
dir="$ASSETS/MenuBarIcon.imageset"
mkdir -p "$dir"
swift "$GEN" menubar 18 "$dir/MenuBarIcon.png" >/dev/null
swift "$GEN" menubar 36 "$dir/MenuBarIcon@2x.png" >/dev/null
cat > "$dir/Contents.json" <<EOF
{"images":[{"filename":"MenuBarIcon.png","idiom":"universal","scale":"1x"},{"filename":"MenuBarIcon@2x.png","idiom":"universal","scale":"2x"}],
 "info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}}
EOF
[ -f "$ASSETS/Contents.json" ] || printf '{"info":{"author":"xcode","version":1}}\n' > "$ASSETS/Contents.json"
echo "icons written to $ASSETS"
