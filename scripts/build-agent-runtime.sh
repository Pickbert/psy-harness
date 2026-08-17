#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
harness_dir="$project_dir/ThirdParty/deepseek-harness"
runtime_dir="$project_dir/.build/agent-runtime"
runtime_path="$runtime_dir/dsh-agent-macos-arm64"
upstream_runtime="$harness_dir/dist-exe/dsh-jsonrpc-agent-pkg-macos-arm64"
runtime_helper_path="$runtime_path-spawn-helper"
upstream_runtime_helper="$upstream_runtime-spawn-helper"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "DeepSeek Harness Agent is built only on Apple Silicon macOS." >&2
    exit 2
fi

mkdir -p "$runtime_dir"
cd "$harness_dir"

COREPACK_NPM_REGISTRY="${COREPACK_NPM_REGISTRY:-https://registry.npmjs.org}" \
    corepack pnpm install --frozen-lockfile --ignore-scripts --child-concurrency=1 --network-concurrency=8
if [[ ! -x node_modules/.pnpm/esbuild@0.28.1/node_modules/esbuild/bin/esbuild ]]; then
    node node_modules/.pnpm/esbuild@0.28.1/node_modules/esbuild/install.js
fi
node packages/subprocess/subprocess-local/scripts/ensure-spawn-helper.mjs

node node_modules/typescript/bin/tsc -b tsconfig.host.json
node node_modules/tsdown/dist/run.mjs --env.DSH_BUILD_FACE host
node node_modules/tsx/dist/cli.mjs scripts/build-exe-for-python-sdk.ts --skip-build --targets=node24-macos-arm64

install -m 755 "$upstream_runtime" "$runtime_path"
install -m 755 "$upstream_runtime_helper" "$runtime_helper_path"
echo "$runtime_path"
