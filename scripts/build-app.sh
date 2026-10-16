#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

app_path="${1:-$project_root/.build/Afterword.app}"
signing_identity_file="$project_root/.build/afterword-signing-identity"
if [[ ${AFTERWORD_SIGNING_IDENTITY+x} ]]; then
    afterword_signing_identity="$AFTERWORD_SIGNING_IDENTITY"
elif [[ -f "$signing_identity_file" ]]; then
    read -r afterword_signing_identity < "$signing_identity_file"
    if [[ ! "$afterword_signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf '%s\n' "Invalid signing identity in $signing_identity_file" >&2
        exit 1
    fi
else
    afterword_signing_identity="-"
fi
if [[ "$afterword_signing_identity" == "-" ]]; then
    if [[ -d "$app_path" ]] && codesign -dv "$app_path" 2>&1 | grep -q '^Authority='; then
        printf '%s\n' 'Set AFTERWORD_SIGNING_IDENTITY to preserve the existing certificate-signed app identity.' >&2
        exit 1
    fi
    printf '%s\n' 'Local ad-hoc build: macOS may require permissions again after code changes.' >&2
fi

swift build --cache-path "$project_root/.cache/swiftpm" --product Afterword
binary_dir="$(swift build --cache-path "$project_root/.cache/swiftpm" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Afterword" "$app_path/Contents/MacOS/Afterword"
cp App/Info.plist "$app_path/Contents/Info.plist"
cp App/Assets/Afterword.icns "$app_path/Contents/Resources/Afterword.icns"
codesign --force --sign "$afterword_signing_identity" "$app_path"
codesign --verify --strict "$app_path"
printf 'Built %s\n' "$app_path"
