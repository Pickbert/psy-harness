# 桌面小柴

一只运行在 macOS 和 Windows 桌面上的原生小狗宠物。它会在当前屏幕上随机散步、待机和打盹，也可以被拖动和点击互动。

项目同时提供原生 Windows 64 位版本，Windows 程序是独立的 Win32 可执行文件，不需要安装 Swift、Python 或 .NET。

## 功能

- 透明无边框窗口，始终浮在普通窗口上方
- 可跨桌面空间显示，并兼容全屏空间
- 随机散步、呼吸起伏、走路弹跳和睡觉状态
- 待机随机单眨眼或双眨眼，睡觉时自然闭眼
- 四帧腿部步行动画，不再只是整张图片平移
- 根据移动方向自动转身
- 鼠标拖拽改变位置，单击显示对话和爱心
- 菜单栏控制显示、暂停、尺寸、复位和退出
- 右键小狗可配置 DeepSeek API，并可直接开始 AI 对话
- 快速连续点击小狗 3 次，输入文字并按回车发送
- DeepSeek 回复以小狗对话气泡展示，并保留最近 6 轮上下文
- 记忆上次选择的小狗尺寸
- 普通宠物功能不需要网络；AI 对话需要用户自己的 DeepSeek API Key

## 系统要求

- macOS 13 或更新版本
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
3. 在短时间内连续点击小狗 3 次，输入问题并按回车发送。
4. 回复会显示在小狗上方的对话气泡中；再次三连击可以继续上下文对话。

API Key 不会写入项目文件：macOS 版保存在系统钥匙串，Windows 版保存在 Windows 凭据管理器。请求直接发送到 DeepSeek 官方接口 `https://api.deepseek.com/chat/completions`。

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

开发日期：2026-08-16
