# 哈妮丝

一只运行在 macOS 和 Windows 桌面上的原生小狗宠物。它会在当前屏幕上随机散步、待机和打盹，也可以被拖动和点击互动。

项目同时提供原生 Windows 64 位版本，Windows 程序是独立的 Win32 可执行文件，不需要安装 Swift、Python 或 .NET。

## 功能

- 透明无边框窗口，始终浮在普通窗口上方
- 可跨桌面空间显示，并兼容全屏空间
- 随机散步、呼吸起伏、走路弹跳和睡觉状态
- 待机随机单眨眼或双眨眼，睡觉时自然闭眼
- 长时间无交互后进入蹲坐等待召唤状态，并随机眨眼、抖耳和摆尾
- 菜单中可配置进入等待状态的分钟数，填写 `0` 可关闭
- 四帧腿部步行动画，不再只是整张图片平移
- 根据移动方向自动转身
- 鼠标拖拽改变位置，单击显示对话和爱心
- 菜单栏控制显示、暂停、尺寸、复位和退出
- 右键小狗可配置 DeepSeek API，并可直接开始 AI 对话
- 快速连续点击小狗 3 次，输入文字并按回车发送
- macOS 支持全局快捷键 `⌥⌘0`，Windows 支持全局快捷键 `Ctrl+Alt+0`，在其他应用中也能立即打开 DeepSeek 对话框并直接输入
- macOS AI 输入框采用 Alfred 风格的深色极简浮层，支持回车发送和 `Esc` 取消
- DeepSeek 回复以小狗对话气泡展示，支持 Markdown 与原生表格渲染，并保留最近 6 轮上下文
- Apple Silicon + macOS 14 及以上以及 Windows 10/11 x64 可启用本地 DeepSeek Harness Agent，读取文件、修改项目和运行命令
- macOS 与完整 Windows Agent 版均可将 1–5 个 PDF、DOCX、XLSX、XLSM、文本、Markdown、CSV、JSON 或常见代码文件直接拖到小狗身上，再输入自定义分析要求
- Agent 使用用户选择的独立工作目录；写入和命令可“允许一次”或在当前运行期间“允许所有”，高风险和越界操作始终拒绝
- “插件与技能”设置直接控制 Harness Cordis 插件，可启用本地 Skill、任务清单、长期目标和 DeepSeek 网页搜索
- 记忆上次选择的小狗尺寸
- 普通宠物功能不需要网络；AI 对话需要用户自己的 DeepSeek API Key

## 系统要求

- macOS 13 或更新版本（本地 Agent 需要 Apple Silicon 和 macOS 14+）
- Xcode 15 或兼容的 Swift 5.9 工具链
- Windows 10/11 x64（Windows 本地 Agent 需要随包分发的 `DesktopPetAgent/` 目录）

## 快速运行

在终端进入项目目录后执行：

```bash
./scripts/run.sh
```

脚本会构建并启动 `build/DesktopPet.app`。小狗启动后不会占用 Dock，控制入口位于菜单栏的爪印图标。

也可以只构建应用：

```bash
./scripts/build-app.sh
```

## 开发

直接运行 Swift Package：

```bash
swift run DesktopPet
```

运行自动测试：

```bash
swift test
```

## Windows 64 位版本

已经打包好的程序位于：

```text
build/windows/DesktopPet-Windows-x64.exe
```

把这一个 `.exe` 文件复制到 Windows 10 或 Windows 11 电脑即可运行基础宠物和普通 DeepSeek 对话。启动后，小狗会出现在屏幕右下角，托盘区会出现控制图标；右键小狗或托盘图标可以暂停、隐藏、调整大小和退出。

Windows 本地 Agent 版需要将 `DesktopPet-Windows-x64.exe` 和同级的 `DesktopPetAgent/` 目录一起分发；运行时已包含 Node，用户电脑不需要另行安装 Node、pnpm、Python、Swift 或 .NET。首次 Agent 对话会选择长期工作目录；托盘菜单中的“本地 Agent”子菜单可管理工作目录、对话、任务、插件、重启和运行状态。

正式的 Windows `0.7.1` 发布同时提供安装包和便携 ZIP。普通用户下载 `DesktopPet-Windows-v0.7.1-Agent-x64-Setup.exe` 后直接安装即可；便携版解压 `DesktopPet-Windows-v0.7.1-Agent-x64-Portable.zip` 后运行其中的 EXE。两者都已经包含完整 Agent 和文件解析运行时，不需要在目标电脑重新编译。

首版安装包尚未使用 Authenticode 代码签名，Windows SmartScreen 可能显示“未知发布者”。可用发布页中的 `DesktopPet-Windows-v0.7.1-Agent-x64-SHA256SUMS.txt` 校验文件完整性：

```powershell
Get-FileHash .\DesktopPet-Windows-v0.7.1-Agent-x64-Setup.exe -Algorithm SHA256
```

## DeepSeek AI 对话

1. 右键小狗，选择“设置 DeepSeek…”并填写自己的 API Key。
2. 默认模型为 `deepseek-v4-flash`，也可以切换为 `deepseek-v4-pro`。
3. Agent 最大输出 Token 默认 `256000`，普通对话默认 `8192`，两者都可在设置中调整（范围 `1–384000`）。
4. 在短时间内连续点击小狗 3 次，输入问题并按回车发送；macOS 也可在任意应用中按 `⌥⌘0`、Windows 按 `Ctrl+Alt+0` 直接唤醒对话框。
5. 回复会显示在小狗上方的对话气泡中；再次三连击可以继续上下文对话。

### 拖拽文件分析（macOS 与 Windows Agent）

把文件拖到小狗身上后，小狗会停止移动并显示橙色接收高亮。本地解析完成后，输入框会显示附件名称；输入总结、对比、提取数据或其他要求并按回车即可。之后三连击会继续当前文件会话；macOS 也可使用 `⌥⌘0`，Windows 可使用 `Ctrl+Alt+0`。

支持 PDF、DOCX、XLSX、XLSM、TXT、Markdown、CSV、JSON 和常见文本代码文件。PDF 按页保留页码；扫描版 PDF 暂不支持 OCR；DOCX 中的嵌入图片暂不分析。Excel 会按工作表提取单元格坐标、值、公式文本和文件内缓存结果，但不会重新计算公式、执行宏或还原图表、图片、数据透视表与视觉样式；旧版二进制 `.xls` 暂不支持。Windows 解析器在独立子进程运行，菜单可取消解析；超过 5 分钟会自动停止，不会阻塞宠物界面。

文件会复制到所选 Agent 工作目录的可见目录 `DesktopPet-FileAnalysis/<会话ID>`。Agent 的执行目录、沙箱根目录和本地技能目录始终保持为原工作目录，因此可以直接复用该目录已有的 `.desktop-pet/skills`、代码和转换脚本。Agent 通过 `glob`、`grep` 和 `read` 按需检索会话分块，不会直接修改用户原文件；隔离副本如需写入仍遵循正常审批流程。该目录可能显示为 Git 未跟踪内容，App 不会自动修改项目的 `.gitignore`。

每批最多 5 个文件，原始文件总量和解析后文本总量分别最多 100 MB。单文件默认上限为 10 MB，可在“设置 DeepSeek…”中调整为 1–100 MB。文件会话保留 7 天；可在“本地 Agent”菜单中结束当前文件分析或清除当前工作目录的文件分析缓存。切换工作目录会结束当前文件分析，但不会立即删除旧目录。文件 Agent 启动失败时会保留会话供重试，不会降级到无法读取附件的普通聊天。

### 本地 Harness Agent（macOS 与 Windows）

在 Apple Silicon、macOS 14 或更新版本上，三连击或 `⌥⌘0` 会进入本地 Agent 模式。第一次使用会要求选择工作目录，之后可以在菜单栏或小狗右键菜单的“本地 Agent”中更换或清除目录、新建对话、停止任务、重启进程和查看状态。

Agent 是 App 监管的独立 sidecar，不从项目 TypeScript 源码直接启动，也不依赖用户电脑上的 Node、pnpm 或 Python。macOS 使用单文件运行时；Windows 随包携带固定 Node 运行时和审计过的 Harness 闭包。API Key 在 macOS 从钥匙串、在 Windows 从凭据管理器读取，只通过经过白名单化的子进程环境传入；Windows 会话数据保存在 `%LOCALAPPDATA%\DesktopPet\Agent\Sessions`。Intel Mac 和 macOS 13 不启动 Agent，继续使用普通 DeepSeek 对话。

Windows 宿主通过匿名管道运行换行分隔的 JSON-RPC，并用 Job Object 确保 App 退出时一并回收 sidecar 及其子进程。命令工具使用 PowerShell 方言，在 Windows 上由 Harness 的 ACL + 受限令牌后端执行 `workspace-write` 隔离；隔离后端不可用时会失败关闭，不会降级为无限制命令。写入和命令会显示“允许一次 / 本次运行允许后续安全操作 / 拒绝”对话框，删除等明显高风险操作仍会自动拒绝。

Windows 版覆盖 Agent 对话、工作目录、本地 Skill、文件/命令工具、会话持久化、操作审批和拖拽文件预处理。拖入的文件副本仍位于长期工作目录下，Agent 不会改用临时会话目录作为 `cwd`。

原生桥接使用 Harness 返回的 `messageId` 等待对应的持久化入队回执，再收集该回执之后直到下一次空闲状态的通知。应用重启并恢复旧会话时，历史恢复事件不会被误判为新问题的结果。

DeepSeek V4 的模型上下文由 Harness 按 `1,000,000` Token 管理，与单轮最大输出分开。若服务端仍以 `max-tokens` 结束，App 会保留已收到的部分内容并明确标记为不完整，不再误报任务成功。长内容流式显示时，气泡会跟随最新输出滚动。

Agent 调用工具时，跟随小狗的气泡顶部会显示无确定进度的旋转指示器和当前工具名称；等待审批、执行成功和执行失败会显示对应状态。Harness 暂未提供工具执行百分比，因此界面不会伪造百分比进度。

“本地 Agent → 插件与技能…”提供经过审核的 Harness 插件白名单。默认启用本地技能库和 `todo_write`，长期目标与 DeepSeek 网页搜索可按需开启；搜索在 macOS 复用钥匙串、在 Windows 复用凭据管理器中的 DeepSeek API Key，但会产生额外模型调用和 Token 消耗。保存后 App 会重启 sidecar，并通过 `desktopPet/plugins/list` 读取 Harness 的真实工具注册表显示生效状态，而不是仅显示前端开关。Windows 的选择保存在 `HKCU\Software\DesktopPet` 的 `AgentEnabledPlugins` `REG_DWORD` 中，显式关闭全部插件也会被保留。

本地技能位于所选工作目录的 `.desktop-pet/skills`，支持 `<name>/SKILL.md` 和平铺 Markdown。该目录仍位于 `workspace-write` 沙箱内，App 不会扫描 `~/.agents`、`~/.dsh` 或其他用户级技能目录。外部 npm/GitHub 插件不会在运行时下载执行；需要固定版本、审计并重新构建 sidecar。

安全策略为 `workspace-write + ask`：读取所选目录可自动进行，写入和命令会显示审批卡，可选择“允许一次”“允许所有”或“拒绝”。“允许所有”只对当前 sidecar 运行期间的后续安全操作生效，切换工作目录、重启 Agent 或退出 App 后自动恢复逐次确认；删除、提权、凭据访问、明显破坏性命令和结构化越界路径仍会直接拒绝。停止任务会终止并重新启动 sidecar，未完成审批按拒绝处理。

Harness 源码固定在 `dsh@0.1.0-rc.7` 的提交 `99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`，位于 `ThirdParty/deepseek-harness`。构建 Apple Silicon 单文件运行时：

```bash
./scripts/build-agent-runtime.sh
```

然后运行普通 App 构建脚本，它会把已有运行时复制到 `DesktopPet.app/Contents/Helpers/DesktopPetAgent` 并统一签名：

```bash
DESKTOPPET_REQUIRE_AGENT_RUNTIME=1 ./scripts/build-app.sh release
```

运行时配置、系统提示词、版本清单、MIT 许可证和第三方声明会一起放入 App Resources。上游处于开发者预览期，因此不会自动跟随 `master`；升级时需显式更新固定提交并重新构建、测试。

## 等待召唤

哈妮丝默认在连续 3 分钟没有点击、拖动、菜单操作或聊天后蹲坐等待。等待时仍会自然呼吸、随机眨眼，并偶尔抖动耳朵和尾巴；任何互动都会立即唤醒它。

可通过菜单中的“设置等待时间…”填写 0–1440 分钟。填写 `0` 会关闭自动等待召唤，设置会在重启后保留。

API Key 不会写入项目文件：macOS 版保存在系统钥匙串，Windows 版保存在 Windows 凭据管理器。请求直接发送到 DeepSeek 官方接口 `https://api.deepseek.com/chat/completions`。

macOS App 会在一次启动期间缓存已经成功读取的 API Key，进入多次对话不会反复访问钥匙串。首次授权时选择“始终允许”可让当前签名版本后续直接读取。正式发布时应使用稳定的 Apple 签名身份构建，避免重新打包后被钥匙串识别为新的应用：

```bash
DESKTOPPET_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  DESKTOPPET_REQUIRE_AGENT_RUNTIME=1 ./scripts/build-app.sh release
```

不建议把 API Key 改存为明文配置文件，因为同一用户下的其他进程可以直接读取它。

在 macOS 上重新交叉编译 Windows 版本：

```bash
./scripts/build-windows.sh
```

需要安装 MinGW-w64：

```bash
brew install mingw-w64
```

交叉编译只生成不带 Agent 运行时的单 EXE。完整 Windows Agent 发布包必须在 Windows x64 上使用 Node 22.19+ / 24+、Visual Studio C++ Build Tools 和 Windows SDK 构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows-package.ps1 `
  -CreateInstaller -CreatePortableZip
```

脚本会生成包含 `DesktopPet-Windows-x64.exe` 和 `DesktopPetAgent/` 的完整目录、安装包、便携 ZIP 与 SHA-256 清单，并校验 ConPTY、Koffi、ExcelJS、Mammoth 和 PDF.js 是否齐全。随后它会用仅存在于构建进程内的假 Key 和本机回环模拟服务，完成一次打包后 Agent 的初始化与对话自检；自检不需要真实 API Key，也不会访问 DeepSeek。Inno Setup 标准安装不包含简体中文翻译，脚本会从固定的 6.7.3 官方源码提交下载并校验该语言文件；也可通过 `-ChineseLanguageFile` 传入已经下载且哈希一致的文件。为避免旧依赖混入新发布包，输出目录已存在时脚本会直接报错；可通过 `-OutputDirectory` 指定一个新目录。

仓库的 `Windows Agent Release` GitHub Actions 工作流会在固定的 `windows-2022` runner 上执行同样的构建。手动运行工作流可下载测试制品；推送与 `windows/VERSION` 一致的 `v0.7.1` 标签会自动创建 GitHub Release。当前无签名证书时生成未签名包；以后配置 `WINDOWS_CERTIFICATE_BASE64` 与 `WINDOWS_CERTIFICATE_PASSWORD` Secrets 后，流水线会自动签名主程序、安装器和卸载程序。

核心文件：

- `PetController.swift`：行为状态、随机散步和窗口位置
- `PetView.swift`：小狗绘制、动画、拖拽和点击互动
- `AppDelegate.swift`：菜单栏入口及应用生命周期
- `PetMotion.swift`：可测试的移动与屏幕边界计算

## 素材说明

`Sources/DesktopPet/Resources/` 中包含为本项目生成的原创小柴犬角色与动画帧。素材包括待机、闭眼、四个步态相位，以及被拎起姿态的睁眼与眨眼两帧；所有帧均使用内置图像生成模式制作，并转换为带 Alpha 通道的透明 PNG。

---

开发日期：2026-08-19
