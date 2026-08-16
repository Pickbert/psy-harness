#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$($project_dir/scripts/build-app.sh release | tail -n 1)"
open "$app_path"
