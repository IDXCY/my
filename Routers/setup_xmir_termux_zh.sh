#!/usr/bin/env bash

# ==============================================================================
#  Script: Xiaomi MiR Patcher Termux Git 极速固化版 (轻量生产环境对齐)
# ==============================================================================
set -euo pipefail

echo "========================================="
echo "   小米路由器修补工具 Termux Git 一键部署"
echo "========================================="

# 1. 精简系统依赖 (剔除无用的 ndk-sysroot, make, clang, unzip，仅保留核心链)
echo "[1/4] 正在安装系统依赖 (Python, Git, OpenSSL)..."
pkg update -y -q || echo "提示：软件源索引可能被锁或跳过，尝试直接安装依赖..."
# 保留 openssl-tool 和 libcrypt 是为了保底特殊加密漏洞利用时的二进制握手
pkg install -y -q python git openssl-tool libcrypt curl >/dev/null 2>&1

# 2. 克隆或增量更新原项目仓库
TARGET_DIR="xmir-patcher"

if [ -d "$TARGET_DIR" ]; then
    echo "检测到 $TARGET_DIR 目录已存在，正在安全同步最新代码..."
    cd "$TARGET_DIR"
    git stash -q || true
    git pull -q || echo "警告：Git 自动同步失败，将维持当前本地版本运行。"
else
    echo "[2/4] 正在克隆仓库..."
    # 优先使用 GitHub 官方源克隆，若失败（15秒超时）则秒级无缝切换到国内高速 Git 镜像
    git clone --depth=1 -q https://github.com/openwrt-xiaomi/xmir-patcher.git "$TARGET_DIR" || \
    git clone --depth=1 -q https://mirror.ghproxy.com/https://github.com/openwrt-xiaomi/xmir-patcher.git "$TARGET_DIR"

    cd "$TARGET_DIR"
fi

# 3. 安装 Python 依赖库 (由于移除了本地编译器，这里全面强制优先使用预编译 wheel)
echo "[3/4] 正在安装 Python 依赖库..."
pip install --upgrade pip setuptools wheel --quiet
pip install -r requirements.txt --quiet

# === 极简物理网关嗅探注入 ===
# 提取默认网关 IP，如果提取失败则保底使用 192.168.31.1
DETECTED_IP=$(ip route show 2>/dev/null | grep -i default | awk '{print $3}' | head -n 1)
export ROUTER_IP="${DETECTED_IP:-192.168.31.1}"

# 4. 动态写入中文 menu.py
echo "[4/4] 正在生成本地化中文控制台..."
cat << 'EOF' > menu.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import subprocess

try:
    import xmir_base
    import gateway
    from gateway import die
except ImportError:
    sys.path.append(os.path.dirname(os.path.abspath(__file__)))
    import xmir_base
    import gateway
    from gateway import die

try:
    gw = gateway.Gateway(detect_device = False, detect_ssh = False)
    gw.ip_addr = os.environ.get("ROUTER_IP", "192.168.31.1")
except Exception:
    gw = gateway.Gateway(detect_device = False, detect_ssh = False)

def get_header(delim, suffix = ''):
  ssh_tip = "  💡 SSH 默认账号&密码：root/root 修改root密码：passwd\n"
  header = delim*58 + '\n\n'
  header += '小米路由器修补工具 (Xiaomi MiR Patcher) {} \n'.format(suffix)
  header += ssh_tip + '\n'
  return header

def menu1_show():
  try:
      gw.load_config()
  except Exception:
      pass
  print(get_header('='))
  print(' 1 - 设置 IP 地址 (当前值: {})'.format(getattr(gw, 'ip_addr', '192.168.31.1')))
  print(' 2 - 连接到设备 (安装漏洞利用程序/Exploit)')
  print(' 3 - 读取完整的设备信息')
  print(' 4 - 创建完整备份')
  print(' 5 - 安装 英文/俄文 语言包')
  print(' 6 - 安装永久 SSH')
  print(' 7 - 安装固件 (自 "firmware" 目录)')
  print(' 8 - {{{ 其它高级功能 }}}')
  print(' 9 - [[ 重启设备 ]]')
  print(' 0 - 退出')

def menu1_process(id):
  if id == 1:
    ip_addr = input("请输入设备 IP 地址: ")
    return [ "gateway.py", ip_addr ]
  if id == 2: return "connect.py"
  if id == 3: return "read_info.py"
  if id == 4: return "create_backup.py"
  if id == 5: return "install_lang.py"
  if id == 6: return "install_ssh.py"
  if id == 7: return "install_fw.py"
  if id == 8: return "__menu2"
  if id == 9: return "reboot.py"
  if id == 0: sys.exit(0)
  return None

def menu2_show():
  print(get_header('-', '(扩展功能)'))
  print(' 1 - 设置 IP 地址 (当前值: {})'.format(getattr(gw, 'ip_addr', '192.168.31.1')))
  print(' 2 - 修改 root 密码')
  print(' 3 - 读取 dmesg 和 syslog 日志')
  print(' 4 - 创建指定分区的备份')
  print(' 5 - 卸载 英文/俄文 语言包')
  print(' 6 - 设置内核启动地址')
  print(' 7 - 安装 Breed 引导加载程序')
  print(' 8 - __测试功能__')
  print(' 9 - [[ 重启设备 ]]')
  print(' 0 - 返回主菜单')

def menu2_process(id):
  if id == 1:
    ip_addr = input("请输入设备 IP 地址: ")
    return [ "gateway.py", ip_addr ]
  if id == 2: return "passw.py"
  if id == 3: return "read_dmesg.py"
  if id == 4: return [ "create_backup.py", "part" ]
  if id == 5: return [ "install_lang.py", "uninstall" ]
  if id == 6: return "activate_boot.py"
  if id == 7: return [ "install_bl.py", "breed" ]
  if id == 8: return "test.py"
  if id == 9: return "reboot.py"
  if id == 0: return "__menu1"
  return None

def menu_show(level):
  if level == 1:
    return menu1_show()
  else:
    return menu2_show()

def menu_process(level, id):
  if level == 1:
    return menu1_process(id)
  else:
    return menu2_process(id)

def menu():
  level = 1
  while True:
    print('')
    menu_show(level)
    print('')
    try:
        select = input('请选择输入: ')
        if not select: continue
        id = int(select)
        if id < 0: continue
    except (ValueError, KeyboardInterrupt, EOFError):
        continue

    cmd = menu_process(level, id)
    if not cmd: continue
    if cmd == '__menu1':
      level = 1
      continue
    if cmd == '__menu2':
      level = 2
      continue

    args = [sys.executable] + ([cmd] if isinstance(cmd, str) else cmd)
    subprocess.run(args)

if __name__ == "__main__":
    menu()
EOF

chmod +x menu.py

# 5. 极速深度清理
rm -rf "$HOME/.cache/pip" 2>/dev/null || true

# ================================= 6. 自动启动 =================================
echo -e "\n\033[1;32m=========================================\033[0m"
echo -e "\033[1;32m 🎉 部署成功！正在启动中文控制台...\033[0m"
echo -e "\033[1;32m=========================================\033[0m\n"

exec python3 menu.py