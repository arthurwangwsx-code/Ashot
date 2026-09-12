# GitHub 仓库与本机发布

## 两种不同的“连接 GitHub”

本项目使用电脑上的 Git 和 GitHub CLI 发布源码与应用。应用运行时没有 GitHub 登录、上传截图或自动更新功能，也不需要 GitHub token。凭据留在本机 GitHub CLI 的凭据存储中，不写进源码、应用或 Release。

默认仓库由项目 `origin` 决定。首次准备：

```sh
gh auth login --hostname github.com
# 审核完全部源码与 Git 历史之后再创建；不要公开不属于自己的项目。
gh repo create OWNER/Ashot --public --source=. --remote=origin
```

已有仓库时直接设置 `origin`，不要创建重复仓库。脚本不会自动改变已有仓库的可见性。

## 发布未公证的预览版

```sh
./dev.sh check
./dev.sh test
python3 -m unittest discover -s scripts/tests -v
python3 scripts/check_public_files.py
# 人工/AI 完成代码审核后，按逻辑批次提交。发布脚本不会自动 git add 或 commit。
./release.sh 1.0.0-preview.1 --allow-unnotarized --publish
```

去掉 `--publish` 只在本机产生分发包，不创建 Git 标签，也不访问 GitHub。工作区仍必须干净。

未公证预览版使用 ad-hoc 签名，不包含个人开发证书或 provisioning profile。必须使用带预发布后缀的版本号，并在 GitHub 标记为 prerelease，不能成为稳定版 latest。该方式保证可公开下载，但**不保证其他 Mac 下载后可以无提示直接打开**。macOS Gatekeeper 可能阻止首次启动；确认来源和校验值后，按系统“隐私与安全性”中的针对该应用的提示处理，不要全局关闭安全检查。升级也可能需要重新授予屏幕录制权限。

## 正式签名与公证

需要有效的 **Developer ID Application** 证书及私钥，以及已保存在本机钥匙串中的 notarytool 凭据配置。Apple Development 和 Apple Distribution 不能替代 Developer ID 的站外发行用途。

```sh
export ASHOT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export ASHOT_NOTARY_PROFILE='your-existing-keychain-profile'
./release.sh 1.0.0 --publish
```

脚本会签名应用、提交 Apple 公证、等待结果、装订并验证 ticket；再生成 ZIP 和 DMG，对 DMG 同样签名、公证及装订。任何失败都会停止，不能悄悄降级成未公证正式包。此路径需要真实 Developer ID 环境验证，不能因为预览发布成功就声称已经验证。

## 自动化步骤与保护

```text
校验版本/签名模式 → 要求干净工作区 → 本地文件与全部可达 Git 历史凭据扫描
→ 校验 GitHub 登录、origin、公有仓库、分支与标签冲突
→ 脚本测试 + Swift 单元测试 → 本机 Universal Release 编译
→ 签名/可选公证 → ZIP + DMG + 元数据 + SHA-256
→ 再次校验源码未改变 → 原子推送分支和标签
→ 带附件创建 draft Release → 上传完成后公开 Release
```

- 使用本机 Xcode，不依赖 GitHub Actions runner；不会把公开 PR 的代码交给个人电脑自动执行。
- 不自动强推、覆盖标签或覆盖 Release 附件。
- 不提交 build、dist、日志、私人 Xcode 设置或证书。
- 公共文件检查只是常见凭据/文件类型的启发式扫描，不能代替人工安全审核。
- 产物包含 arm64 与 x86_64；最低系统版本读取实际构建的 Info.plist。
- `release.json` 记录完整提交 SHA、版本、构建号、架构、签名方式和是否公证。
- ZIP 打包保留执行权限与符号链接，拒绝覆盖已有文件和递归打包；完成 CRC 校验后，再解压并验证应用代码签名。
- 发布阶段失败时保留产物与已存在的标签/draft。先检查远端，补传缺少的附件并核对 SHA-256，再公开 draft；不要强制重建同名版本。重新完整发布使用新版本号。
- `dist/vVERSION` 已存在会拒绝覆盖；确认失败阶段后将旧目录移到其他位置再重试。
- 公开源码不等同于授予开源许可证；本次没有擅自添加 MIT/Apache 等许可。

## 本机输出与日常开发

```text
build/Ashot.app
build/logs/xcodebuild.log
build/logs/release-build.log
dist/vVERSION/Ashot-VERSION-universal.zip
dist/vVERSION/Ashot-VERSION-universal.dmg
dist/vVERSION/SHA256SUMS
dist/vVERSION/release.json
dist/vVERSION/RELEASE_NOTES.md
```

`./dev.sh build` 继续使用 Apple Development 签名及本机架构。`./release.sh` 则明确选择分发签名模式并编译 Universal 包。构建失败时不会提前删除上一次成功的应用；日志与其他产物也会保留。

`./dev.sh test` 使用无需个人证书的 ad-hoc 签名，并**只在单元测试构建中**关闭 Hardened Runtime，使测试宿主能够加载测试框架。开发构建和 Release 分发包仍保留各自的安全配置，发布脚本会为分发包显式启用 Hardened Runtime；这不修改 macOS 的 Gatekeeper 设置。

## 参考

- [GitHub CLI release create](https://cli.github.com/manual/gh_release_create)
- [Apple Developer ID](https://developer.apple.com/support/developer-id/)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
