# ADR-0007：Sparkle 更新签名密钥轮换

- 状态：已采纳（2026-11-25）
- 取代：ADR-0001 / ADR-0006 中“`SUPublicEDKey` 原值保持不变”的密钥部分；其他更名与兼容决定不变。

## 背景

原 Sparkle Ed25519 私钥 `~/.ghds-release-keys/ghds-ed25519` 已无法恢复。用户明确授权生成新密钥；重新生成同一密钥在计算上不可行，不能继续使用旧公钥验证新签名。

旧公钥为 `YHHW4wKUsjO8HlZkuZc4vdJWZj4y4ftbiFcEsJkNop4=`。历史 Release、DMG 与 appcast 中的旧签名和旧公钥保持原样，不改写。

## 决定

1. 在原兼容路径生成新的 Ed25519 私钥，权限保持 `0600`，仅存于本机、不入库、不写日志、不外传。
2. 新构建的 `SUPublicEDKey` 改为 `qQwltPD68k5anSzJBvRC+Z0xvUSfEvKbEarPKhFHyfA=`；`scripts/build-app.sh` 的默认公钥同步更新。E2E 继续使用每次测试临时生成的密钥，不读取生产私钥。
3. 新 Release 的 DMG / appcast 条目使用新私钥签名。stable 默认条目与 beta 条目分别保留其实际签名；历史条目不重新签名。
4. 旧版本无法用旧公钥验证新签名，**旧版本必须手动安装一次新版本（手动下载并安装）**。新版本安装后即可继续使用新公钥验证后续自动更新；这不是无缝迁移，Release 正文必须明确说明。
5. 回滚到旧私钥只有在重新获得旧私钥时才可行；不得为回滚生成另一把密钥冒充旧身份。

## 验证

- `scripts/test-release-key.sh` 检查生产默认公钥、私钥权限、迁移说明与 ADR 链接。
- 打包时继续检查 `SUPublicEDKey` 与签名公钥一致；Sparkle 本地升级 E2E 使用临时密钥验证签名链，生产 Release 发布前再用新私钥签名并回读核对。
