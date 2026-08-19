#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/build/windows"
intermediate_dir="$project_dir/.build/windows"
resource_object="$intermediate_dir/resources.o"
output_exe="$output_dir/DesktopPet-Windows-x64.exe"
compiler="${MINGW_CXX:-x86_64-w64-mingw32-g++}"
resource_compiler="${MINGW_WINDRES:-x86_64-w64-mingw32-windres}"

mkdir -p "$output_dir" "$intermediate_dir"
cd "$project_dir"

"$resource_compiler" \
    --codepage=65001 \
    -I windows \
    windows/resources.rc \
    -O coff \
    -o "$resource_object"

"$compiler" \
    -std=c++20 \
    -O2 \
    -Wall \
    -Wextra \
    -DUNICODE \
    -D_UNICODE \
    -finput-charset=UTF-8 \
    -ffunction-sections \
    -fdata-sections \
    -municode \
    -mwindows \
    -static \
    -static-libgcc \
    -static-libstdc++ \
    -Wl,--gc-sections \
    windows/DesktopPet.cpp \
    windows/AgentRuntime.cpp \
    windows/FileAnalysisRuntime.cpp \
    "$resource_object" \
    -lgdiplus \
    -lshell32 \
    -lole32 \
    -ladvapi32 \
    -lwinhttp \
    -lcomctl32 \
    -luuid \
    -o "$output_exe"

echo "$output_exe"
