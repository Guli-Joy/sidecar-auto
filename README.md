# Sidecar Auto

> 一键用 Mac 快捷指令连接 iPad Sidecar 显示器。

[![CI](https://github.com/Guli-Joy/sidecar-auto/actions/workflows/ci.yml/badge.svg)](https://github.com/Guli-Joy/sidecar-auto/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Guli-Joy/sidecar-auto?display_name=tag)](https://github.com/Guli-Joy/sidecar-auto/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-111827)](https://github.com/Guli-Joy/sidecar-auto#前置条件)
[![License](https://img.shields.io/badge/license-MIT-2563eb)](LICENSE)

Sidecar Auto 面向需要把 iPad 当作 Mac 显示器的人，尤其适合没有常驻显示器的 Mac mini。它只在用户主动触发时运行：先确认设备和显示状态，再选择有线或无线路径，最后验证 Sidecar 会话和画面是否真的上线。

## 核心能力

| 需求 | 使用体验 |
| --- | --- |
| 插着数据线 | 自动优先使用有线连接，减少无线准备步骤。 |
| 没有数据线 | 按需准备 Wi‑Fi、蓝牙和接力，再尝试无线连接。 |
| 没有实体显示器 | 使用项目内置虚拟屏，也可以选择 BetterDisplay。 |
| 临时使用或重复触发 | 只在你主动点击或运行快捷指令时操作，不会后台无限重试。 |

连接过程支持提示音、中文语音和通知；失败、取消和超时都会在有限时间内结束。

## 下载

普通用户直接前往 [Releases](https://github.com/Guli-Joy/sidecar-auto/releases) 下载最新 DMG。当前首个正式版本是 [v1.0.0](https://github.com/Guli-Joy/sidecar-auto/releases/tag/v1.0.0)，提供 Apple Silicon（arm64）安装包。

App 的“概览”页提供“检查更新”。它会读取 GitHub Releases，发现新版本后把 arm64 DMG 下载到“下载”文件夹；打开 DMG 后把新 App 拖到“应用程序”并重新打开即可完成更新。

首次打开时如果 macOS 拦截应用，请到“系统设置 → 隐私与安全性”允许打开；部分系统会显示“允许来自任何来源”或“仍要打开”。

开发者也可以从源码安装：

```sh
git clone https://github.com/Guli-Joy/sidecar-auto.git
cd sidecar-auto
./installer/install-sidecar-auto.sh
```

源码安装需要 macOS 13+ 和 Xcode Command Line Tools；DMG 已包含运行时文件，普通用户不需要安装 Swift 或 clang。

## 快速开始

1. 打开 `Sidecar Auto Setup.app`，点击“安装 / 修复”。
2. 点击“重新检查”，确认目标 iPad、显示器和无线状态已经读取。
3. 点击“一键配置快捷指令”，按 macOS 提示完成导入。
4. 在快捷指令中运行“连接 Sidecar”；日常入口会自动选择有线或无线。
5. 需要结束会话时运行“断开 Sidecar”。

也可以直接运行脚本：

```sh
"$HOME/.local/bin/sidecar-connect-once.sh" auto
"$HOME/.local/bin/sidecar-disconnect-once.sh"
```

指定连接路径排障入口：

```sh
"$HOME/.local/bin/sidecar-connect-once.sh" wired    # 有线排障
"$HOME/.local/bin/sidecar-connect-once.sh" wireless # 无线排障
```

## 前置条件

- Mac 使用 macOS 13 或更高版本。
- Mac 和 iPad 支持 Sidecar，并登录同一个 Apple Account、开启双重认证。
- 有线连接需要可传输数据的 USB 线，且 iPad 已信任这台 Mac。
- 无线连接需要两台设备打开 Wi‑Fi、蓝牙和接力（Handoff），并保持唤醒、靠近。
- iPad 必须唤醒并解锁；Sidecar 不能在锁屏或 FileVault 解锁界面建立画面会话。

## 无显示器模式

默认的 `auto` provider 优先使用项目内置虚拟屏，提供固定的 1920×1080、60Hz 屏幕。它不需要 BetterDisplay，但依赖 macOS 未公开的虚拟显示接口。

登录启动器会等待图形会话就绪；如果 App 或虚拟屏工具在登录瞬间退出，会自动重试，但不会在后台反复连接或断开 Sidecar。

需要 HiDPI、更多分辨率或复杂排列时，可以在配置中选择 BetterDisplay：

```sh
VIRTUAL_DISPLAY_BACKEND="betterdisplay"
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
```

可选值为 `auto`、`builtin` 和 `betterdisplay`。连接失败或取消时，控制器只清理本次操作创建的虚拟屏。

## 配置

安装器会创建 `~/.config/sidecar-auto/config`，已有配置不会覆盖。常用设置：

```sh
IPAD_NAME="iPad"
# 多台 iPad 同时插线时填写目标 USB 序列号。
# IPAD_USB_SERIAL_NUMBER=""
AUTO_ENABLE_HANDOFF=1
# 登录进入 macOS 桌面后静默启动 App；无实体显示器时准备虚拟屏。
AUTO_START_HEADLESS_DISPLAY=1
VIRTUAL_DISPLAY_BACKEND="auto"
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
```

配置只接受白名单字段，文件必须由当前用户拥有且不能对组或其他用户开放写权限；配置内容不会作为 shell 代码执行。

## 诊断

只读诊断不会连接、断开或修改显示器：

```sh
"$HOME/.local/bin/sidecar-doctor.sh"
"$HOME/.local/bin/sidecarctl" snapshot
```

日志保存在 `~/Library/Logs/sidecar-auto.log`，会自动轮转。多台 iPad 时，请同时配置准确的 `IPAD_NAME` 和 `IPAD_USB_SERIAL_NUMBER`。

## 使用文档

- [普通用户 App 指南](docs/APP_GUIDE.md)：下载、安装、首次授权和日常使用。
- [排障手册](docs/TROUBLESHOOTING.md)：USB、无线、虚拟屏和权限问题。
- [安全与隐私](docs/SECURITY_MODEL.md)：本地数据、配置边界和 macOS 权限。
- [English overview](docs/README.en.md)：英文项目简介。

## 限制与隐私

- 项目依赖 Apple 未公开的 Sidecar 和虚拟显示接口，系统更新可能造成兼容性变化。
- 项目不收集遥测，不上传配置、日志、设备名称或 USB 序列号。
- 不绕过 BetterDisplay 许可、TCC 权限、FileVault 或 macOS 安全策略。
- 不会安装 root LaunchDaemon，不会在后台自动抢占 iPad，也不会保存密码。

## 许可证

自动化代码使用 [MIT License](LICENSE)。`vendor/sidecarctl` 中的上游 MIT 声明必须保留，详见 [`docs/NOTICE.md`](docs/NOTICE.md)。本项目与 Apple 或 BetterDisplay 没有隶属或背书关系。
