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

node_is_supported() {
    "$1" -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit((major === 22 && minor >= 19) || major >= 24 ? 0 : 1)'
}

node_command="$(command -v node 2>/dev/null || true)"
if [[ -z "$node_command" ]] || ! node_is_supported "$node_command"; then
    if [[ -n "${NVM_BIN:-}" && -x "$NVM_BIN/node" ]] && node_is_supported "$NVM_BIN/node"; then
        export PATH="$NVM_BIN:$PATH"
        node_command="$NVM_BIN/node"
    else
        echo "DeepSeek Harness RC7 build requires Node.js 22.19+ or 24+." >&2
        exit 2
    fi
fi

mkdir -p "$runtime_dir"
cd "$harness_dir"

CI="${CI:-true}" \
COREPACK_NPM_REGISTRY="${COREPACK_NPM_REGISTRY:-https://registry.npmjs.org}" \
npm_config_registry="${npm_config_registry:-https://registry.npmjs.org}" \
    corepack pnpm install --frozen-lockfile --ignore-scripts --child-concurrency=1 --network-concurrency=8
if [[ ! -x node_modules/.pnpm/esbuild@0.28.1/node_modules/esbuild/bin/esbuild ]]; then
    "$node_command" node_modules/.pnpm/esbuild@0.28.1/node_modules/esbuild/install.js
fi
"$node_command" packages/subprocess/subprocess-local/scripts/ensure-spawn-helper.mjs

"$node_command" node_modules/typescript/bin/tsc -b tsconfig.host.json
"$node_command" node_modules/tsdown/dist/run.mjs --env.DSH_BUILD_FACE host
"$node_command" node_modules/tsx/dist/cli.mjs scripts/build-exe-for-python-sdk.ts --skip-build --targets=node24-macos-arm64

install -m 755 "$upstream_runtime" "$runtime_path"
install -m 755 "$upstream_runtime_helper" "$runtime_helper_path"
echo "$runtime_path"
