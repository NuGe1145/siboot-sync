# 分发说明

## SideInstaller.ipa

本仓库 `ipa` 这个 release 下镜像的 `SideInstaller.ipa`，**已获得原作者授权**再分发。

- 上游项目：https://github.com/FrizzleM/SideInstaller
- 授权方式：作者本人同意
- 授权凭证：另存备份（截图/邮件），如需核验可联系仓库所有者

若作者日后撤回授权，本镜像会立即删除该附件。

## siboot

本仓库镜像的 `siboot-aarch64` 及 `install.sh` 来自
https://github.com/FrizzleM/siboot ，该项目以 **MIT 协议**发布，允许自由复制、
修改与再分发（需保留版权声明）。

## 为什么要镜像

`github.com` 及其 release 下载域名（`objects.githubusercontent.com`）在中国大陆
无法直连。本项目只做"搬运"，不改动任何一行上游代码，也不从中获利。

## 同步

`.github/workflows/sync-to-gitee.yml` 每小时检查一次上游，有新版本才同步。
上游不变时不会产生任何上传。
