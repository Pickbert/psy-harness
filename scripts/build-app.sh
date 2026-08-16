#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/build/DesktopPet.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
local_cache_dir="$project_dir/.build/local-cache"

cd "$project_dir"
mkdir -p "$local_cache_dir/clang" "$local_cache_dir/swiftpm" "$local_cache_dir/xdg"
export CLANG_MODULE_CACHE_PATH="$local_cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$local_cache_dir/swiftpm"
export XDG_CACHE_HOME="$local_cache_dir/xdg"

swift build -c "$configuration" --disable-sandbox

binary_dir="$(swift build -c "$configuration" --disable-sandbox --show-bin-path)"
binary_path="$binary_dir/DesktopPet"

mkdir -p "$macos_dir" "$resources_dir"
install -m 755 "$binary_path" "$macos_dir/DesktopPet"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba.png" "$resources_dir/shiba.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-blink-v2.png" "$resources_dir/shiba-blink-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-1-v2.png" "$resources_dir/shiba-walk-1-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-2-v2.png" "$resources_dir/shiba-walk-2-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-3-v2.png" "$resources_dir/shiba-walk-3-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-4-v2.png" "$resources_dir/shiba-walk-4-v2.png"

plutil -create xml1 "$contents_dir/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string "zh_CN" "$contents_dir/Info.plist"
plutil -replace CFBundleDisplayName -string "桌面小柴" "$contents_dir/Info.plist"
plutil -replace CFBundleExecutable -string "DesktopPet" "$contents_dir/Info.plist"
plutil -replace CFBundleIdentifier -string "com.local.desktoppet" "$contents_dir/Info.plist"
plutil -replace CFBundleInfoDictionaryVersion -string "6.0" "$contents_dir/Info.plist"
plutil -replace CFBundleName -string "DesktopPet" "$contents_dir/Info.plist"
plutil -replace CFBundlePackageType -string "APPL" "$contents_dir/Info.plist"
plutil -replace CFBundleShortVersionString -string "0.2.0" "$contents_dir/Info.plist"
plutil -replace CFBundleVersion -string "2" "$contents_dir/Info.plist"
plutil -replace LSMinimumSystemVersion -string "13.0" "$contents_dir/Info.plist"
plutil -replace LSUIElement -bool true "$contents_dir/Info.plist"
plutil -replace NSHighResolutionCapable -bool true "$contents_dir/Info.plist"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
