# 发布 Sidecar Auto

仓库提供两种发布方式：免费开发版可以直接构建 DMG；需要减少 macOS 首次打开提示
时，再使用 Developer ID 签名和 Apple 公证。仓库只提交构建脚本和源代码，不提交
`.app`、DMG、证书或个人配置。

## 免费 DMG

当前公开资产使用 Apple Silicon（arm64）构建。请在 Apple Silicon Mac 上运行（并确保
已安装 Xcode Command Line Tools）：

```sh
./packaging/build-sidecar-auto-app.sh --host-only --version 1.0.0 \
  --output ./dist
./packaging/make-dmg.sh --app "./dist/Sidecar Auto Setup.app" --output ./dist \
  --version 1.0.0
mv ./dist/Sidecar-Auto-Setup.dmg ./dist/Sidecar-Auto-Setup-1.0.0-arm64.dmg
shasum -a 256 ./dist/Sidecar-Auto-Setup-1.0.0-arm64.dmg > ./dist/SHA256SUMS
```

脚本会把 `sidecarctl`、显示探针、蓝牙 helper 和连接脚本放进 App Resources；
最终 App 的“安装 / 修复”按钮才会把它们复制到当前用户的 `~/.local/bin`。构建
脚本默认不签名，适合 CI 编译检查。`--host-only` 可以在不需要交叉编译时只构建
当前架构。

生成 `dist/Sidecar-Auto-Setup-1.0.0-arm64.dmg` 和 `SHA256SUMS` 后，把它们上传到
GitHub Release。首次打开若被 macOS 拦截，到“系统设置 → 隐私与安全性”允许打开即可。

需要 Intel 或通用构建时，把 `--host-only` 改为 `--arch arm64,x86_64`，并在发布
说明中标明实际包含的架构。

## 可选：签名与公证

如需减少 macOS 首次打开提示，可使用仓库内的发布包装脚本完成 Developer ID 签名和
Apple 公证。免费 DMG 流程不需要证书、Apple Account 或公证凭据。

```sh
./packaging/release-sidecar-auto.sh \
  --version 1.0.0 \
  --identity "Developer ID Application: Example Company (TEAMID)" \
  --keychain-profile "sidecar-auto-notary"
```

签名时先签 App 内的 Mach-O，再签 App 本身；构建脚本已经按这个顺序处理。签名身份、
公证凭据和 Apple Account 令牌只能放在 CI secret 或维护机钥匙串中。

## 发布前检查

- 在 arm64 和 Intel Mac 各启动一次，确认 `lipo -info` 包含对应架构。
- 在有显示器环境完成首次 Bluetooth TCC、BetterDisplay 和 Shortcuts 授权。
- 在有线、无线、拔掉显示器三种情形各做一次真实连接测试；连接失败时不得把
  API 接受请求当成成功。
- 解压发布包后检查其中不含日志、配置、USB 序列号、用户名、绝对路径或私钥。
- 在 GitHub Release 上传 DMG、校验和和变更说明；源代码 ZIP 只面向开发者。
