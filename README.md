# 自用仓库

---

## 📂 模块导览

### 1. 🎮 游戏自动化 (HV 模块)

### 2. 📟 路由器固化 (Routers 模块)

面向基于 Termux (Android) 终端的xmir-patcher一键运行中文菜单脚本。

* `setup_xmir_termux_zh.sh`：
  * **定位**：Termux 专用的 `xmir-patcher` 一键本地化汉化控制台。
  * **特性**：内置防御性初始化，集成本地化中文菜单，替换进程一键直达修补界面。
  * **状态**：*待进一步实际场景测试验证*。
* `deploy_services.sh`：
  * **定位**：二进制服务一键部署与开机自启固化脚本。
  * **支持组件**：DDNS-Go, socat
  * **状态**：*待进一步实际场景测试验证*。

---

## 🚀 快速启动

### Termux中终端命令：

```bash
curl -LO https://cdn.jsdelivr.net/gh/IDXCY/my@main/Routers/setup_xmir_termux_zh.sh && chmod +x setup_xmir_termux_zh.sh && ./setup_xmir_termux_zh.sh
```

```bash
curl -LO https://cdn.jsdelivr.net/gh/IDXCY/my@main/Routers/deploy_services.sh && chmod +x deploy_services.sh && ./deploy_services.sh
```

```bash
curl -LO https://cdn.jsdelivr.net/gh/IDXCY/my@main/Termux/Initialization.sh && chmod +x Initialization.sh && ./Initialization.sh
```
