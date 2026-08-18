#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
swift_jobs="${DESKTOPPET_SWIFT_JOBS:-1}"
app_dir="$project_dir/build/DesktopPet.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
helpers_dir="$contents_dir/Helpers"
local_cache_dir="$project_dir/.build/local-cache"
agent_runtime="$project_dir/.build/agent-runtime/dsh-agent-macos-arm64"
agent_runtime_helper="$agent_runtime-spawn-helper"
codesign_identity="${DESKTOPPET_CODESIGN_IDENTITY:--}"

sign_path() {
    local target="$1"
    shift
    if [[ "$codesign_identity" == "-" ]]; then
        codesign --force "$@" --sign - "$target"
    else
        codesign --force --options runtime --timestamp "$@" --sign "$codesign_identity" "$target"
    fi
}

cd "$project_dir"
mkdir -p "$local_cache_dir/clang" "$local_cache_dir/swiftpm" "$local_cache_dir/xdg"
export CLANG_MODULE_CACHE_PATH="$local_cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$local_cache_dir/swiftpm"
export XDG_CACHE_HOME="$local_cache_dir/xdg"

swift build -c "$configuration" --disable-sandbox --jobs "$swift_jobs"

binary_dir="$(swift build -c "$configuration" --disable-sandbox --jobs "$swift_jobs" --show-bin-path)"
binary_path="$binary_dir/DesktopPet"

mkdir -p "$macos_dir" "$resources_dir" "$helpers_dir"
install -m 755 "$binary_path" "$macos_dir/DesktopPet"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba.png" "$resources_dir/shiba.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-blink-v2.png" "$resources_dir/shiba-blink-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-1-v2.png" "$resources_dir/shiba-walk-1-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-2-v2.png" "$resources_dir/shiba-walk-2-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-3-v2.png" "$resources_dir/shiba-walk-3-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-walk-4-v2.png" "$resources_dir/shiba-walk-4-v2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-lift-1.png" "$resources_dir/shiba-lift-1.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-lift-2.png" "$resources_dir/shiba-lift-2.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-lift-3.png" "$resources_dir/shiba-lift-3.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-lift-4.png" "$resources_dir/shiba-lift-4.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-waiting.png" "$resources_dir/shiba-waiting.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-waiting-blink.png" "$resources_dir/shiba-waiting-blink.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-waiting-ear.png" "$resources_dir/shiba-waiting-ear.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-waiting-tail.png" "$resources_dir/shiba-waiting-tail.png"
install -m 644 "$project_dir/Sources/DesktopPet/Resources/shiba-chat-icon.png" "$resources_dir/shiba-chat-icon.png"
install -m 644 "$project_dir/Agent/cordis.yml" "$resources_dir/DesktopPetAgent.cordis.yml"
install -m 644 "$project_dir/Agent/SYSTEM_PROMPT.md" "$resources_dir/DesktopPetAgentSystemPrompt.md"
install -m 644 "$project_dir/Agent/HARNESS_VERSION" "$resources_dir/DeepSeekHarness.version"
install -m 644 "$project_dir/Agent/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"
install -m 644 "$project_dir/ThirdParty/deepseek-harness/LICENSE" "$resources_dir/DeepSeekHarness-LICENSE.txt"

if [[ "$(uname -m)" == "arm64" && -x "$agent_runtime" && -x "$agent_runtime_helper" ]]; then
    install -m 755 "$agent_runtime" "$helpers_dir/DesktopPetAgent"
    install -m 755 "$agent_runtime_helper" "$helpers_dir/DesktopPetAgent-spawn-helper"
    sign_path "$helpers_dir/DesktopPetAgent"
    sign_path "$helpers_dir/DesktopPetAgent-spawn-helper"
elif [[ "${DESKTOPPET_REQUIRE_AGENT_RUNTIME:-0}" == "1" ]]; then
    echo "Missing Agent runtime. Run ./scripts/build-agent-runtime.sh first." >&2
    exit 3
else
    echo "Warning: Agent runtime is not built; the app will keep ordinary DeepSeek chat fallback." >&2
fi

plutil -create xml1 "$contents_dir/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string "zh_CN" "$contents_dir/Info.plist"
plutil -replace CFBundleDisplayName -string "桌面小柴" "$contents_dir/Info.plist"
plutil -replace CFBundleExecutable -string "DesktopPet" "$contents_dir/Info.plist"
plutil -replace CFBundleIdentifier -string "com.local.desktoppet" "$contents_dir/Info.plist"
plutil -replace CFBundleInfoDictionaryVersion -string "6.0" "$contents_dir/Info.plist"
plutil -replace CFBundleName -string "DesktopPet" "$contents_dir/Info.plist"
plutil -replace CFBundlePackageType -string "APPL" "$contents_dir/Info.plist"
plutil -replace CFBundleShortVersionString -string "0.4.13" "$contents_dir/Info.plist"
plutil -replace CFBundleVersion -string "17" "$contents_dir/Info.plist"
plutil -replace LSMinimumSystemVersion -string "13.0" "$contents_dir/Info.plist"
plutil -replace LSUIElement -bool true "$contents_dir/Info.plist"
plutil -replace NSHighResolutionCapable -bool true "$contents_dir/Info.plist"

sign_path "$app_dir" --deep
echo "$app_dir"
