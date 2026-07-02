#!/usr/bin/env bash

# 遇到错误立即停止
set -e

echo "========================================="
echo "   小米路由器修补工具 Termux 一键中文部署"
echo "========================================="

# 1. 升级系统并安装基础依赖
echo "[1/4] 正在安装系统依赖 (Python, Git, GCC)..."
pkg update -y
pkg install -y python git clang make libffi openssl-tool libcrypt ndk-sysroot

# 2. 克隆原项目仓库
if [ -d "xmir-patcher" ]; then
    echo "检测到 xmir-patcher 目录已存在，正在拉取最新代码..."
    cd xmir-patcher && git pull && cd ..
else
    echo "[2/4] 正在克隆官方仓库..."
    git clone --depth=1 https://github.com/openwrt-xiaomi/xmir-patcher.git
fi

cd xmir-patcher

# 3. 安装 Python 依赖库
echo "[3/4] 正在安装 Python 依赖库 (这可能需要几分钟)..."
# 预先导出环境变量以防某些C扩展库编译失败
export CFLAGS="-Wno-implicit-function-declaration"
pip install --upgrade pip setuptools wheel
# 过滤掉注释行并安装依赖
pip install -r requirements.txt

# 4. 动态写入中文 menu.py
echo "[4/4] 正在生成中文菜单..."
cat << 'EOF' > menu.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import subprocess

import xmir_base
import gateway
from gateway import die


gw = gateway.Gateway(detect_device = False, detect_ssh = False)

def get_header(delim, suffix = ''):
  header = delim*58 + '\n'
  header += '\n'
  header += '小米路由器修补工具 (Xiaomi MiR Patcher) {} \n'.format(suffix)
  header += '\n'
  return header

def menu1_show():
  gw.load_config()
  print(get_header('='))
  print(' 1 - 设置 IP 地址 (当前值: {})'.format(gw.ip_addr))
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
  print(' 1 - 设置 IP 地址 (当前值: {})'.format(gw.ip_addr))
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
    menu1_show()
    return '请选择输入: '
  else:
    menu2_show()
    return '请选择输入: '

def menu_process(level, id):
  if level == 1:
    return menu1_process(id)
  else:
    return menu2_process(id)

def menu():
  level = 1
  while True:
    print('')
    prompt = menu_show(level)
    print('')
    select = input(prompt)
    print('')
    if not select:
      continue
    try:
      id = int(select)
    except Exception:
      id = -1
    if id < 0:
      continue
    cmd = menu_process(level, id)
    if not cmd:
      continue
    if cmd == '__menu1':
      level = 1
      continue
    if cmd == '__menu2':
      level = 2
      continue
    if isinstance(cmd, str):
      result = subprocess.run([sys.executable, cmd])
    else:
      result = subprocess.run([sys.executable] + cmd)


menu()
EOF

chmod +x menu.py

echo "========================================="
echo " 部署完成！请执行以下命令启动中文菜单："
echo " cd xmir-patcher && python3 menu.py"
echo "========================================="
