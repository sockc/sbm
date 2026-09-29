# Sing-box Manager (sbm)

面向 Linux 服务器的 sing-box 交互式管理脚本，支持入站、出站、策略组、Clash API、本地代理、Realm 中转、备份恢复和防火墙辅助管理。

当前脚本版本：**0.2.5.0**

## 安装

```bash
REPO="sockc/sbm" bash <(curl -fsSL https://raw.githubusercontent.com/sockc/sbm/main/install.sh)
```

安装完成后运行：

```bash
sbm
```

## 主要功能

- VLESS（TLS / Reality）
- Hysteria2
- VMess
- TUIC
- AnyTLS（TLS / Reality）
- 多 VLESS 实例用户管理
- sing-box 固定目标中转
- Realm 独立中转实例
- URL / 本地文件节点源
- selector / urltest 与策略组
- Clash API 与 Web UI
- 本地 mixed HTTP + SOCKS 代理
- UFW / firewalld / iptables 基础端口管理
- 完整备份、校验与恢复
- 脚本自更新

## 0.2.5.0 入站实例管理优化

入站管理主菜单收拢为：

```text
1. 部署/重装 VLESS
2. 部署/重装 Hysteria2
3. 部署/重装 VMess
4. 部署/重装 TUIC
5. 部署/重装 AnyTLS
6. 中转管理
7. 入站实例管理
0. 返回
```

“查看实例、删除实例、导出客户端配置、VLESS 用户管理”统一合并到“入站实例管理”。选择实例一次后即可查看详情、导出配置、管理 VLESS 用户或删除实例，不再在多个子菜单中重复选择。

中转继续使用独立的“中转管理”，避免普通入站删除逻辑遗漏中转对应的路由规则。

## 0.2.4.0 稳定性加固

此版本重点不是新增协议，而是降低配置损坏、并发修改和更新失败风险：

- 运行时使用 `umask 077`
- 每次运行创建独立随机临时目录
- 同一台机器只允许一个 sbm 管理会话执行写操作
- 新配置先执行 `sing-box check`
- 配置应用后若 sing-box 无法正常启动，会自动恢复上一份配置
- Reality / AnyTLS 私钥、节点源、缓存和元数据收紧文件权限
- 入站元数据统一使用 JSON 序列化，避免特殊字符破坏配置
- VLESS / AnyTLS 元数据文件名进行安全编码
- Clash UI 删除操作限制在 sing-box 配置目录内
- Clash API Secret 和订阅 URL 在状态页面默认脱敏
- Realm 使用 GitHub Release 提供的 SHA256 digest 校验下载文件
- 自更新先解析远端 commit，再固定到该 commit 执行安装
- 安装器使用 staging 目录，所有文件下载和语法检查通过后才切换版本
- 修复 `outbound.sh` 重复函数与重复下载逻辑
- VLESS 用户管理支持多实例，不再依赖固定 `vless-reality-in` 标签

## 备份与恢复 V2

新备份默认保存在：

```text
/var/backups/sbm
```

该目录位于 `/etc/sing-box` 之外，所以执行“完整卸载”时不会把卸载前备份一起删除。

V2 备份会尽量包含：

- `/etc/sing-box`
- 入站元数据
- Realm 元数据和配置
- 节点源与节点缓存
- 出站代理状态
- 策略文件
- 安装来源信息

创建备份后会同时生成 SHA256 校验文件。恢复前会先校验归档、校验 SHA256、运行 `sing-box check`，并自动创建一份恢复前快照。

旧版 `/etc/sing-box/backup/manual-*.tar.gz` 仍可在备份列表中看到并恢复。

## 自更新

进入：

```text
sbm → 8. 更新脚本
```

0.2.4.0 起，自更新会先解析目标分支当前 commit SHA，并固定到该 commit 下载和安装，避免一次更新过程中远端分支发生变化造成文件混装。

## 常用排错

查看服务：

```bash
systemctl status sing-box --no-pager -l
```

查看最近日志：

```bash
journalctl -u sing-box -n 100 --no-pager
```

检查当前配置：

```bash
sing-box check -c /etc/sing-box/config.json
```

## 目录

```text
/usr/local/share/sbm/     sbm 脚本与运行元数据
/etc/sing-box/            sing-box 配置、证书、节点源和缓存
/etc/realm/               Realm 实例配置
/var/backups/sbm/         SBM V2 备份
/usr/local/sbin/sbm       命令入口
```

## 安全提示

如果启用公网 Clash API，请务必保留随机生成的 API Secret，并只开放确实需要的端口。不要把包含 UUID、密码、Reality 私钥、订阅 Token 或完整备份文件的终端输出公开发布。
