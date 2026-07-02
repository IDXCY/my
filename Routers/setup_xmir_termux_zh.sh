#!/usr/bin/env bash
# ==============================================================================
#  Script: Xiaomi MiR Patcher Termux 极速部署
# ==============================================================================
set -euo pipefail

# 日志函数
log() { echo -e "\033[1;36m==>\033[0m \033[1m$*\033[0m"; }

TARGET_DIR="$HOME/xmir-patcher"

# ================================= 1. 环境与依赖 =================================
log "1/4 配置 Termux 环境与核心依赖..."
export DEBIAN_FRONTEND=noninteractive
pkg update -y -q >/dev/null 2>&1 || true
pkg install -y -q python clang make libffi openssl-tool libcrypt ndk-sysroot unzip curl >/dev/null 2>&1

# ================================= 2. 源码下载 =================================
log "2/4 通过 CDN 高速下载项目源码..."
rm -rf "$TARGET_DIR" "$HOME/xmir-patcher-main" "$HOME/xmir.zip"

cd "$HOME"
curl -fsSL -o xmir.zip "https://cdn.jsdelivr.net/gh/openwrt-xiaomi/xmir-patcher@main/archive.zip" || \
curl -fsSL -o xmir.zip "https://github.com/openwrt-xiaomi/xmir-patcher/archive/refs/heads/main.zip"

unzip -q xmir.zip
mv xmir-patcher-main "$TARGET_DIR"
rm -f xmir.zip
cd "$TARGET_DIR"

# ================================= 3. Python 依赖 =================================
log "3/4 编译并安装 Python 依赖库..."
export CFLAGS="-Wno-implicit-function-declaration"
pip install --upgrade pip setuptools wheel -q
pip install -r requirements.txt -q

# ================================= 4. 构建中文控制台 =================================
log "4/4 注入本地化中文菜单..."
cat << 'EOF' > menu.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys, subprocess, gateway

gw = gateway.Gateway(detect_device=False, detect_ssh=False)

def get_header(delim, suffix=''):
    # 将 SSH 账号密码提示放在这里，用户每次进入菜单都能看到
    ssh_tip = " 💡 默认账号&密码：root/root 修改root密码：passwd\n"
    return f"{delim*58}\n\n 小米路由器修补工具 (Xiaomi MiR Patcher) {suffix}\n{ssh_tip}\n"

def menu_show(level):
    gw.load_config()
    if level == 1:
        print(get_header('='))
        menus = [
            f" 1 - 设置 IP 地址 (当前: {gw.ip_addr})",
            " 2 - 连接到设备 (安装漏洞利用/Exploit)",
            " 3 - 读取完整的设备信息",
            " 4 - 创建完整备份",
            " 5 - 安装 英文/俄文 语言包",
            " 6 - 安装永久 SSH",
            " 7 - 安装固件 (自 'firmware' 目录)",
            " 8 - {{{ 其它高级功能 }}}",
            " 9 - [[ 重启设备 ]]",
            " 0 - 退出"
        ]
    else:
        print(get_header('-', '(扩展功能)'))
        menus = [
            f" 1 - 设置 IP 地址 (当前: {gw.ip_addr})",
            " 2 - 修改 root 密码",
            " 3 - 读取 dmesg 和 syslog 日志",
            " 4 - 创建指定分区的备份",
            " 5 - 卸载 英文/俄文 语言包",
            " 6 - 设置内核启动地址",
            " 7 - 安装 Breed 引导加载程序",
            " 8 - __测试功能__",
            " 9 - [[ 重启设备 ]]",
            " 0 - 返回主菜单"
        ]
    print("\n".join(menus))
    return '请选择输入: '

def menu_process(level, idx):
    if level == 1:
        mapping = {
            1: lambda: ["gateway.py", input("请输入设备 IP 地址: ")],
            2: "connect.py", 3: "read_info.py", 4: "create_backup.py",
            5: "install_lang.py", 6: "install_ssh.py", 7: "install_fw.py",
            8: "__menu2", 9: "reboot.py", 0: lambda: sys.exit(0)
        }
    else:
        mapping = {
            1: lambda: ["gateway.py", input("请输入设备 IP 地址: ")],
            2: "passw.py", 3: "read_dmesg.py", 4: ["create_backup.py", "part"],
            5: ["install_lang.py", "uninstall"], 6: "activate_boot.py",
            7: ["install_bl.py", "breed"], 8: "test.py", 9: "reboot.py", 0: "__menu1"
        }
    res = mapping.get(idx)
    return res() if callable(res) else res

def menu():
    level = 1
    while True:
        print('')
        try:
            select = input(menu_show(level))
            if not select: continue
            idx = int(select)
            if idx < 0: continue
        except (ValueError, KeyboardInterrupt, EOFError):
            continue

        cmd = menu_process(level, idx)
        if not cmd: continue
        if cmd == '__menu1': level = 1; continue
        if cmd == '__menu2': level = 2; continue

        args = [sys.executable] + ([cmd] if isinstance(cmd, str) else cmd)
        subprocess.run(args)

if __name__ == "__main__":
    menu()
EOF
chmod +x menu.py

# ================================= 5. 深度清理 =================================
log "清理安装缓存与临时文件..."
rm -rf "$HOME/.cache/pip" "$PREFIX/tmp/*" "$TMPDIR/*" 2>/dev/null || true
pkg clean -y >/dev/null 2>&1 || true

# ================================= 6. 自动启动 =================================
echo -e "\n\033[1;32m=========================================\033[0m"
echo -e "\033[1;32m 🎉 部署成功！正在启动中文控制台...\033[0m"
echo -e "\033[1;32m=========================================\033[0m\n"

# 使用 exec 替换当前 shell 进程，直接拉起 Python 菜单
exec python3 menu.py