# 发布 Sidecar Auto

仓库提供两种发布方式：免费开发版可以直接构建 DMG；需要减少 macOS 首次打开提示
时，再使用 Developer ID 签名和 Apple 公证。仓库只提交构建脚本和源代码，不提交
`.app`、DMG、证书或个人配置。

## 免费 DMG

在 macOS 和 Xcode Command Line Tools 已安装的维护机上运行：

```sh
./packaging/build-sidecar-auto-app.sh --arch arm64,x86_64 --version 1.0.0 \
  --output ./dist
./packaging/make-dmg.sh --app "./dist/Sidecar Auto Setup.app" --output ./dist
```

脚本会把 `sidecarctl`、显示探针、蓝牙 helper 和连接脚本放进 App Resources；
最终 App 的“安装 / 修复”按钮才会把它们复制到当前用户的 `~/.local/bin`。构建
脚本默认不签名，适合 CI 编译检查。`--host-only` 可以在不需要交叉编译时只构建
当前架构。

生成 `dist/Sidecar-Auto-Setup.dmg` 后，可以把它和 `SHA256SUMS` 上传到 GitHub
Release。首次打开若被 macOS 拦截，到“系统设置 → 隐私与安全性”允许打开即可。

## 可选：签名与公证

推荐使用仓库内的发布包装脚本，它会执行构建、嵌套代码签名、校验、notarytool
公证、stapler、Gatekeeper 检查、DMG 和 SHA256 文件生成：

```sh
./packaging/release-sidecar-auto.sh \
  --version 1.0.0 \
  --identity "Developer ID Application: Example Company (TEAMID)" \
  --keychain-profile "sidecar-auto-notary"
```

脚本不会把证书、Apple Account 或公证令牌写入仓库；`notarytool` 只读取你已经
保存到钥匙串的 profile。没有这些凭据时，使用上面的免费 DMG 流程即可。

使用 Developer ID Application 身份构建：

```sh
./packaging/build-sidecar-auto-app.sh \
  --arch arm64,x86_64 \
  --sign "Developer ID Application: Example Company (TEAMID)" \
  --version 1.0.0

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
公证凭据和 Apple Account 令牌只能放在 CI secret 或维护机钥匙串中。

## 发布前检查

- 在 arm64 和 Intel Mac 各启动一次，确认 `lipo -info` 包含对应架构。
- 在有显示器环境完成首次 Bluetooth TCC、BetterDisplay 和 Shortcuts 授权。
- 在有线、无线、拔掉显示器三种情形各做一次真实连接测试；连接失败时不得把
  API 接受请求当成成功。
- 解压发布包后检查其中不含日志、配置、USB 序列号、用户名、绝对路径或私钥。
- 在 GitHub Release 上传 DMG、校验和和变更说明；源代码 ZIP 只面向开发者。
