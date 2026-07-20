# Homebrew 发布

可安装的 formula 由 [release workflow](../.github/workflows/release.yml) 根据已发布归档的实际 SHA-256 自动生成，并提交到 [`ekil1100/homebrew-tap`](https://github.com/ekil1100/homebrew-tap)。本目录不保留容易过期的 formula 副本。

```bash
brew install ekil1100/tap/zc
brew upgrade ekil1100/tap/zc
```

发布后应在 Tap 仓库中检查 formula，并运行：

```bash
brew style "$(brew --repository ekil1100/tap)/zc.rb"
brew audit --strict --online ekil1100/tap/zc
brew livecheck ekil1100/tap/zc
brew test ekil1100/tap/zc
```
