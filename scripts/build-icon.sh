#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_source="$project_root/App/Assets/afterword-icon-v1.png"
icon_output="$project_root/App/Assets/Afterword.icns"
icon_work="$(mktemp -d "${TMPDIR:-/private/tmp}/afterword-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
icon_set="$icon_work/Afterword.iconset"
mkdir "$icon_set"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$icon_set/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$icon_source" --out "$icon_set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set" -o "$icon_output"
printf 'Packaged %s\n' "$icon_output"
