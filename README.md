# 🛡️ VPS 入站端口管理脚本

适配所有 Linux 发行版的 VPS 入站端口管理脚本，交互式菜单操作，支持修改 SSH 端口、开放/关闭端口、批量操作等。

## 🚀 一键安装

```bash
git clone https://github.com/liyanliang888/vps-port-manager.git && cd vps-port-manager && chmod +x port-manager.sh && sudo ./port-manager.sh
```

首次运行自动检测环境、安装依赖，并提示安装快捷命令 `dk`，之后直接输入 `dk` 即可进入。

## 📋 功能列表

| 序号 | 功能 | 说明 |
|------|------|------|
| 1 | 查看防火墙状态 | 实时显示当前防火墙规则 |
| 2 | 查看监听端口 | 列出所有正在监听的端口及进程 |
| 3 | 开放端口 | 单个端口开放，支持 TCP/UDP/both |
| 4 | 关闭端口 | 单个端口关闭，SSH 端口保护确认 |
| 5 | 批量开放端口 | 一次性开放多个端口 |
| 6 | 修改 SSH 端口 | 修改后自动验证、重启、关闭旧端口 |
| 7 | 一键放行常用端口 | Web/数据库/FTP/邮件/DNS 预设 |
| 8 | 重置防火墙 | 重置所有规则，保持 SSH 端口开放 |
| 9 | 安装/卸载快捷命令 | 安装 `dk` 全局命令 |
| 10 | 卸载脚本 | 一键卸载脚本及所有残留 |

## 🔧 修改 SSH 端口流程

1. 备份 SSH 配置文件
2. 修改 Port 配置（支持 sshd_config.d Include 场景）
3. 防火墙开放新端口（TCP+UDP）
4. `sshd -t` 验证配置，失败自动回滚
5. 重启 SSH 服务（自动检测服务名，显式错误输出）
6. 检测 SELinux，自动添加端口策略
7. 验证新端口在监听
8. ✅ **自动关闭旧端口**

## 🔒 安全特性

- 修改 SSH 端口前自动备份，验证失败自动回滚
- 新端口验证监听成功后才关闭旧端口，未监听则保留旧端口
- 关闭当前 SSH 端口时二次确认
- 重置防火墙后自动保持 SSH 端口开放
- 卸载脚本需输入 `yes` 确认，防火墙和 SSH 配置不被还原

## 🖥️ 适配范围

**操作系统:** Ubuntu/Debian/CentOS/RHEL/Fedora/Arch/Alpine/openSUSE

**防火墙:** ufw → firewalld → nftables → iptables（自动检测）

**包管理器:** apt-get/dnf/yum/pacman/apk/zypper

**Init 系统:** systemd/OpenRC/SysVinit

**Shell:** bash/zsh

## 📖 日常使用

```bash
# 快捷命令（安装后）
sudo dk

# 或直接运行
sudo bash /path/to/port-manager.sh
```

## 🗑️ 卸载

菜单中选择 `10) 卸载脚本`，或手动执行：

```bash
rm -f /usr/local/bin/dk
sed -i '/# VPS Port Manager 快捷命令/d' ~/.bashrc
sed -i "/alias dk='sudo/d" ~/.bashrc
rm -rf ~/vps-port-manager
rm -f /etc/port-manager-installed
```

> 卸载不会还原防火墙规则和 SSH 端口配置。
