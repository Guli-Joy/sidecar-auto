# 发布设置助手

设置助手可以在没有 Xcode Command Line Tools 的用户 Mac 上运行，但普通用户发布
包必须使用 Apple Developer ID 签名并完成公证。仓库只提交构建脚本和源代码，不提交
`.app`、DMG、证书或个人配置。

## 本地构建

在 macOS 和 Xcode Command Line Tools 已安装的维护机上运行：

```sh
./packaging/build-sidecar-auto-app.sh --arch arm64,x86_64 --version 0.2.0 \
  --output ./dist
./packaging/make-dmg.sh --app "./dist/Sidecar Auto Setup.app" --output ./dist
```

脚本会把 `sidecarctl`、显示探针、蓝牙 helper 和连接脚本放进 App Resources；
最终 App 的“安装 / 修复”按钮才会把它们复制到当前用户的 `~/.local/bin`。构建
脚本默认不签名，适合 CI 编译检查。`--host-only` 可以在不需要交叉编译时只构建
当前架构。

## 签名与公证

使用 Developer ID Application 身份构建：

```sh
./packaging/build-sidecar-auto-app.sh \
  --arch arm64,x86_64 \
  --sign "Developer ID Application: Example Company (TEAMID)" \
  --version 0.2.0

codesign --verify --deep --strict --verbose=2 "dist/Sidecar Auto Setup.app"
ditto -c -k --keepParent "dist/Sidecar Auto Setup.app" "dist/Sidecar-Auto-Setup.zip"
xcrun notarytool submit "dist/Sidecar-Auto-Setup.zip" \
  --keychain-profile "sidecar-auto-notary" --wait
xcrun stapler staple "dist/Sidecar Auto Setup.app"
spctl --assess --type execute --verbose=4 "dist/Sidecar Auto Setup.app"
./packaging/make-dmg.sh --app "dist/Sidecar Auto Setup.app" --output dist
shasum -a 256 dist/Sidecar-Auto-Setup.dmg > dist/SHA256SUMS
```

签名时先签 App 内的 Mach-O，再签 App 本身；构建脚本已经按这个顺序处理。签名身份、
公证凭据和 Apple Account 令牌只能放在 CI secret 或维护机钥匙串中。没有证书时不要
把未签名构建宣传成普通用户的正式安装包；Gatekeeper 可能阻止或显示开发者来源提示。

## 发布前检查

- 在 arm64 和 Intel Mac 各启动一次，确认 `lipo -info` 包含对应架构。
- 在有显示器环境完成首次 Bluetooth TCC、BetterDisplay 和 Shortcuts 授权。
- 在有线、无线、拔掉显示器三种情形各做一次真实连接测试；连接失败时不得把
  API 接受请求当成成功。
- 解压发布包后检查其中不含日志、配置、USB 序列号、用户名、绝对路径或私钥。
- 在 GitHub Release 上传 DMG、校验和和变更说明；源代码 ZIP 只面向开发者。
