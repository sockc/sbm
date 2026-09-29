# Sing-box Manager (sbm)

面向 Linux 服务器的 sing-box 交互式管理脚本，支持入站、出站、策略组、Clash API、本地代理、Realm 中转、备份恢复和防火墙辅助管理。

当前脚本版本：**0.2.8.0**

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

## 0.2.8.0 Web 面板管理优化

本版把普通用户看到的“Clash API 管理”收敛为“Web 面板”，底层仍使用 sing-box `experimental.clash_api`，配置格式与原有高级能力保持兼容。

普通入口：

```text
Web 面板

状态      : 已启用
访问方式  : Tailscale
监听      : 100.x.x.x:9090
面板 UI   : MetaCubeXD
访问地址  : http://100.x.x.x:9090/ui/
API Secret: 已设置（脱敏）

1. 修改访问方式
2. 更换面板 UI
3. 重新生成 API Secret
4. 查看详细状态
5. 关闭 Web 面板
6. 高级设置
0. 返回
```

访问方式统一为“仅本机 / 局域网 / Tailscale / 公网”。修改访问方式只调整 Web 面板监听与访问控制，不再自动更新订阅、重建节点或重应用路由策略。

高级设置继续保留自定义监听地址、Clash API 默认模式、UI 下载出口、CORS、私网访问、手动设置 Secret 与恢复默认值。

公网模式默认二次确认，并明确提示必须保留强 Secret、建议配合防火墙限制来源 IP。

## 0.2.7.0 出站快速配置

本版不删除原有出站高级能力，只新增一条面向日常操作的引导入口：

```text
出站管理
1. 快速配置
2. 节点管理
3. 路由策略
4. 面板管理
5. 出站开关
```

快速配置提供：

- 新增订阅并开始配置
- 使用已有订阅重新配置
- 只切换当前节点
- 只修改代理模式
- 修复/重新生成出站配置

代理模式映射：

- “智能分流”使用现有 `policy-groups.json`
- “全局代理 / 直连优先 / 最小配置”使用现有预设模板语义
- 更新已有订阅时，原默认节点仍存在则优先保留
- 切换当前节点时优先通过 Clash API 实时切换；API 不可用时回退为修改配置并重启
- 所有完整配置应用继续执行 `sing-box check`、备份和失败回滚
- Clash API / Web 面板配置在向导中保持原样，不会被订阅配置流程覆盖

## 0.2.6.0 入站管理增强

本版继续收敛入站日常操作：

- 普通界面移除 VLESS 多用户管理入口；旧多用户配置仍兼容读取，不自动破坏
- 入站实例新增“修改实例”，按协议显示可用修改项
- VLESS / VMess / TUIC 可重新生成 UUID；Hysteria2 / AnyTLS 可重新生成密码
- Reality 实例可修改握手目标、重新生成 Reality 密钥与 Short ID
- TLS 实例可修改客户端 SNI 和证书路径
- 新建/修改监听端口前检查 sing-box 配置冲突和系统监听冲突
- 入站实例列表显示“正常 / 未监听 / 服务停止 / 配置异常 / 未知”
- 配置修改继续使用 `sing-box check`、配置备份与启动失败自动回滚
- 客户端元数据只有在新配置成功启动后才提交，避免配置回滚后导出信息不一致
- 新增独立模块 `lib/inbound_manager.sh`，避免继续膨胀核心协议部署文件

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
