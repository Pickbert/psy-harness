# 桌面小柴

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
- macOS 支持全局快捷键 `⌥⌘0`，在其他应用中也能立即打开 DeepSeek 对话框
- macOS AI 输入框采用 Alfred 风格的深色极简浮层，支持回车发送和 `Esc` 取消
- DeepSeek 回复以小狗对话气泡展示，并保留最近 6 轮上下文
- Apple Silicon + macOS 14 及以上可启用本地 DeepSeek Harness Agent，读取文件、修改项目和运行命令
- Agent 使用用户选择的独立工作目录；写入和命令必须逐次点击“允许一次”，高风险和越界操作直接拒绝
- 记忆上次选择的小狗尺寸
- 普通宠物功能不需要网络；AI 对话需要用户自己的 DeepSeek API Key

## 系统要求

- macOS 13 或更新版本（本地 Agent 需要 Apple Silicon 和 macOS 14+）
- Xcode 15 或兼容的 Swift 5.9 工具链

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

把这一个 `.exe` 文件复制到 Windows 10 或 Windows 11 电脑即可运行。启动后，小狗会出现在屏幕右下角，托盘区会出现控制图标；右键小狗或托盘图标可以暂停、隐藏、调整大小和退出。

## DeepSeek AI 对话

1. 右键小狗，选择“设置 DeepSeek API…”并填写自己的 API Key。
2. 默认模型为 `deepseek-v4-flash`，也可以切换为 `deepseek-v4-pro`。
3. 在短时间内连续点击小狗 3 次，输入问题并按回车发送；macOS 也可在任意应用中按 `⌥⌘0` 直接唤醒对话框。
4. 回复会显示在小狗上方的对话气泡中；再次三连击可以继续上下文对话。

### 本地 Harness Agent（macOS）

在 Apple Silicon、macOS 14 或更新版本上，三连击或 `⌥⌘0` 会进入本地 Agent 模式。第一次使用会要求选择工作目录，之后可以在菜单栏或小狗右键菜单的“本地 Agent”中更换或清除目录、新建对话、停止任务、重启进程和查看状态。

Agent 是 App 内独立的预编译 sidecar，不从 TypeScript 源码启动，也不依赖用户电脑上的 Node、pnpm 或 Python。API Key 仍从 macOS 钥匙串读取，只通过子进程环境传入；会话数据保存在 `Application Support/DesktopPet/Agent/Sessions`。Windows、Intel Mac 和 macOS 13 不启动 Agent，继续使用原来的普通 DeepSeek 对话。

原生桥接使用 Harness 返回的 `messageId` 等待对应的持久化入队回执，再收集该回执之后直到下一次空闲状态的通知。应用重启并恢复旧会话时，历史恢复事件不会被误判为新问题的结果。

安全策略为 `workspace-write + ask`：读取所选目录可自动进行，写入和命令会显示审批卡，只能“允许一次”或“拒绝”；删除、提权、明显破坏性命令和结构化越界路径会直接拒绝。停止任务会终止并重新启动 sidecar，未完成审批按拒绝处理。

Harness 源码固定在提交 `47f943859bef60e4160492346772ded9b24f765a`，位于 `ThirdParty/deepseek-harness`。构建 Apple Silicon 单文件运行时：

```bash
./scripts/build-agent-runtime.sh
```

然后运行普通 App 构建脚本，它会把已有运行时复制到 `DesktopPet.app/Contents/Helpers/DesktopPetAgent` 并统一签名：

```bash
DESKTOPPET_REQUIRE_AGENT_RUNTIME=1 ./scripts/build-app.sh release
```

运行时配置、系统提示词、版本清单、MIT 许可证和第三方声明会一起放入 App Resources。上游处于开发者预览期，因此不会自动跟随 `master`；升级时需显式更新固定提交并重新构建、测试。

## 等待召唤

小柴默认在连续 3 分钟没有点击、拖动、菜单操作或聊天后蹲坐等待。等待时仍会自然呼吸、随机眨眼，并偶尔抖动耳朵和尾巴；任何互动都会立即唤醒它。

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

核心文件：

- `PetController.swift`：行为状态、随机散步和窗口位置
- `PetView.swift`：小狗绘制、动画、拖拽和点击互动
- `AppDelegate.swift`：菜单栏入口及应用生命周期
- `PetMotion.swift`：可测试的移动与屏幕边界计算

## 素材说明

`Sources/DesktopPet/Resources/` 中包含为本项目生成的原创小柴犬角色与动画帧。素材包括待机、闭眼和四个步态相位；所有帧均使用内置图像生成模式制作，并转换为带 Alpha 通道的透明 PNG。

---

开发日期：2026-08-17
