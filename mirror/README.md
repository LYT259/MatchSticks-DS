# Cloudflare Pages 镜像

- `public/index.html`：下载镜像页（安装三步 + xattr 兜底 + 本地网络第一嫌疑——与 Releases 教程同款）
- `public/appcast-mirror.xml`：Sparkle appcast 镜像模板（发版时从 SHA256SUMS + sign-update 生成，enclosure 指镜像可达地址）
- 最新 dmg 镜像文件名：`MatchSticks-DriverStaion-latest.dmg`
- 部署命令见 `wrangler.toml` 注释（Pages 项目 `matchsticks-driver-staion-mirror`；需用户凭证，未经点名不部署）

发版 checklist（主仓库 docs/release-kit.md）含：主链接 GitHub Releases + 镜像链接本站，发版前实测镜像可达。
