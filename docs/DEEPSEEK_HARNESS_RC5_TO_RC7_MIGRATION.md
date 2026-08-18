# DeepSeek Harness RC5 至 RC7 迁移记录

## 迁移范围

- DesktopPet 基线分支：`main`
- 升级分支：`codex/harness-rc7-upgrade`
- 旧版本：`dsh@0.1.0-rc.5`
- 新版本：`dsh@0.1.0-rc.7`
- 旧上游提交：`47f943859bef60e4160492346772ded9b24f765a`
- 新上游提交：`99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`
- 上游比较：<https://github.com/deepseek-ai/deepseek-harness/compare/47f943859bef60e4160492346772ded9b24f765a...99f6f02fecdb7dff40c3fbc9470f5907c29f74ca>

第三方源码仍以固定提交快照保存在 `ThirdParty/deepseek-harness`。应用运行时不从 TypeScript 源码启动，也不依赖用户安装 Node、pnpm 或 Python；macOS App 使用预先构建并签名的单文件 sidecar。

## 上游变更处理

RC5 至 RC7 的完整上游差异已应用到第三方源码快照，没有跟随 `master`。本次迁移重点核对了以下与 DesktopPet 集成直接相关的变化：

- Harness 全部 workspace 包版本更新为 `0.1.0-rc.7`。
- Node.js 构建要求更新为 22.19 及以上或 24 及以上。
- `node-pty` 更新为 `1.2.0-beta.15`，同时更换了上游补丁文件。
- SDK server、会话持久化、最大输出 token 回放状态和插件组合均采用 RC7 实现。
- 文件搜索、技能、待办、目标和网页搜索插件继续由 DesktopPet 的 Cordis 配置显式启用或关闭。

## DesktopPet 本地补丁

升级后保留并适配了以下本地能力：

1. JSON-RPC transport 的请求支持 `AbortSignal`，用于审批超时和取消。
2. `desktopPet/approval.request` 审批桥继续采用 fail-closed 语义，只接受 `allowed-once` 或 `rejected`。
3. DesktopPet 工具策略继续拒绝删除、提权、凭据访问和工作区越界；普通写入与命令进入审批流程。
4. `desktopPet/plugins/list` 从实际 Cordis 工具/技能注册表返回运行时状态。
5. 已落盘会话优先调用 Harness `resume`，避免应用重启后产生 session id collision。
6. Runtime 依赖闭包保留 bash sandbox、spill、文件搜索等 DesktopPet 所需组件。
7. 构建脚本增加 Node 版本保护，避免 Node 18 表面构建成功后产生不兼容运行时。
8. 为 RC7 的 `node-pty` 增加 macOS 静态原生模块引用，使 SEA 打包器能提取 `pty.node`；原有同名 spawn helper 仍作为 App Helper 一起签名。

本地补丁版本记录在 `Agent/HARNESS_VERSION`：

```text
local_patch=desktop-pet-jsonrpc-approval-policy-resume-token-config-plugins-file-search-native-pty-rc7-v8
```

## 迁移中发现并修复的问题

### Node 版本不符合 RC7 要求

机器默认 `node` 为 18.17.1，而 RC7 要求 22.19+ 或 24+。旧构建命令可以进入打包阶段，但不能作为可信发布结果。`scripts/build-agent-runtime.sh` 现在会验证版本；若当前 Node 不满足要求，会使用有效的 `NVM_BIN/node`，否则立即给出明确错误。

本次最终构建使用 Node 24 系列；SEA 内置目标为 `node24-macos-arm64`。

### node-pty 原生模块未被 SEA 提取

RC7 初次构建成功，但独立运行 sidecar 时出现：

```text
Cannot find module './prebuilds/darwin-arm64/pty.node'
```

原因是 `node-pty` 通过动态字符串加载原生模块，单文件打包器无法据此建立原生模块提取记录。修复方式是在 RC7 的 pnpm patch 中加入 macOS arm64/x64 静态 `require`，同时保留普通环境的动态回退路径。修复后，sidecar 能在没有系统 Node/Python 的最小环境中完成初始化。

### 测试沙箱导致模拟服务超时

三个 Harness 用例最初表现为 5 秒或 15 秒超时。根因是测试需要监听 `127.0.0.1` 的临时端口，而文件沙箱返回 `listen EPERM`。在允许本地测试端口的环境重跑后，相关用例全部通过。这不是 Agent 回合或流式协议回归。

### sidecar 打包后开发依赖链接需要恢复

RC7 的部署/打包步骤会重建 runtime closure，之后直接运行 workspace Vitest 可能缺少包级开发链接并报 `eventsource-parser/stream` 找不到。可靠验证顺序为：

1. 安装固定锁文件依赖。
2. 构建 sidecar。
3. 用 `pnpm install --frozen-lockfile --force --ignore-scripts` 恢复开发依赖链接。
4. 运行 Harness 定向测试。

这只影响源码树中的测试环境，不影响已经生成的 sidecar。

## 验证结果

### Harness 与 sidecar

- RC7 sidecar 构建成功，runtime dependency closure 校验通过。
- Harness SDK server、JSON-RPC transport、插件装载、审批策略、会话恢复和 native-pty：58 项测试全部通过。
- 未安装系统 Node/Python 的最小 `PATH` 冒烟通过：
  - `initialize` 成功。
  - `desktopPet/plugins/list` 返回 `bash`、`edit`、`glob`、`grep`、`read`、`write`。
  - `shutdown` 成功且进程退出码为 0。
- 同样的冒烟测试已对 macOS App 内签名后的 Helper 再执行一次并通过。

### DesktopPet

- Swift：43 项测试全部通过。
- macOS：`DesktopPet.app` 构建成功，版本 `0.5.0`、build `19`。
- macOS 主程序、Agent sidecar 和 spawn helper 均为 arm64 Mach-O。
- `codesign --verify --deep --strict` 通过。
- App 内 `DeepSeekHarness.version` 与源码清单一致。
- macOS 归档：`build/DesktopPet-macOS-v0.5.0-agent-rc7-arm64.zip`，SHA-256 为 `17992ff495dd8ea1adf89a4544630a82489645797dc35b4535300d59ca922870`。
- Windows：x64 GUI 可执行文件构建成功；不包含 Harness sidecar 标记，继续使用普通 DeepSeek 对话路径。

## 构建与复验命令

```bash
PATH="$NVM_BIN:$PATH" \
./scripts/build-agent-runtime.sh

DESKTOPPET_REQUIRE_AGENT_RUNTIME=1 ./scripts/build-app.sh release
./scripts/build-windows.sh
```

Harness 测试涉及本地模拟 HTTP 服务，需要允许监听 `127.0.0.1`。构建产物位于 `.build`、`build` 和上游 `dist-exe`，这些目录继续由 Git 忽略。

## 后续升级注意事项

- 不自动跟随上游 `master`；每次升级都固定 release 对应提交并更新 `Agent/HARNESS_VERSION`。
- 先比较官方快照，再逐项重放 DesktopPet 本地补丁，避免把旧实现覆盖到新协议上。
- 每次 `node-pty` 或单文件打包器升级后，必须运行真实 sidecar 冒烟，不能只以 TypeScript 构建成功作为验收。
- 必须保留会话恢复、审批 fail-closed、工作区越界和危险命令测试。
- Windows 构建不得打包或启动 Harness。

记录日期：2026-08-19
