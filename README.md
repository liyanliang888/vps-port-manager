# VPS 入站端口管理脚本

## 概述
适配所有 Linux 发行版的 VPS 入站端口管理脚本，提供交互式菜单操作，支持修改 SSH 端口、开放/关闭端口、批量操作等。

## 文件
- `port-manager.sh` — 主脚本文件

## 功能
1. **查看防火墙状态** — 实时显示当前防火墙规则
2. **查看监听端口** — 列出所有正在监听的端口及进程
3. **开放端口** — 单个端口开放，支持 TCP/UDP/both
4. **关闭端口** — 单个端口关闭，SSH 端口保护确认
5. **批量开放端口** — 一次性开放多个端口
6. **修改 SSH 端口** — 安全修改 SSH 登录端口，自动验证配置、备份、开放新端口
7. **一键放行常用端口** — Web/数据库/FTP/邮件/DNS 等常用端口预设
8. **重置防火墙** — 重置所有规则，保持 SSH 端口开放
9. **快捷命令安装** — 安装 `pm` 全局命令快速启动

## 适配的防火墙
- ufw (Ubuntu/Debian 默认)
- firewalld (CentOS/RHEL/Fedora 默认)
- nftables (现代 Linux 内核)
- iptables (传统 Linux)

## 适配的包管理器
- apt-get (Debian/Ubuntu)
- dnf (Fedora/RHEL 8+)
- yum (CentOS 7)
- pacman (Arch Linux)
- apk (Alpine Linux)
- zypper (openSUSE)

## 适配的 Init 系统
- systemd
- OpenRC
- SysVinit

## 使用方法

### 首次安装
```bash
# 上传脚本到 VPS 后
chmod +x port-manager.sh
sudo ./port-manager.sh
```

### 日常使用
```bash
# 方式1: 快捷命令（安装后）
pm
sudo pm

# 方式2: 直接运行
sudo bash /path/to/port-manager.sh
```

## 快捷命令
首次运行后可选择安装 `pm` 快捷命令：
- 写入 `/usr/local/bin/pm` 作为全局命令
- 同时在 `~/.bashrc` 或 `~/.zshrc` 中添加 alias
- 自动检测当前 shell 类型

## 安全特性
- 修改 SSH 端口前自动备份配置文件
- SSH 配置验证 (`sshd -t`) 失败自动回滚
- 关闭当前 SSH 端口时二次确认
- 重置防火墙后自动保持 SSH 端口开放
- 修改 SSH 端口后保留旧端口开放直到手动关闭

## SSH 端口修改流程
1. 备份 `/etc/ssh/sshd_config` 或 include 目录配置
2. 修改 Port 配置行
3. 在防火墙开放新端口 (TCP+UDP)
4. `sshd -t` 验证配置
5. 重启 SSH 服务
6. 提醒用户测试新端口连接
