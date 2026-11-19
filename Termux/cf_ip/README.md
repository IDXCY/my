# cf-ip

用于测试优选的 Cloudflare IPv4 和 IPv6 地址，并将测速结果写入 Cloudflare DNS。

脚本会：

1. 下载 CloudflareSpeedTest 和 Cloudflare 官方 IP 段。
2. 对 IPv4 和 IPv6 进行三阶段筛选测速。
3. 自动将测速结果更新到指定域名的 A 和 AAAA 记录（10 秒内输入 `n` 可取消）。

## 一键下载并运行安装脚本

github源

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/IDXCY/my@main/Termux/cf_ip/install.sh)
```

加速源

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/IDXCY/my@main/Termux/cf_ip/install.sh)
```

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/IDXCY/my/main/Termux/cf_ip/install.sh)
```
安装完成后运行：

```bash
cd ~/cf-ip && ./run.sh
```

## 使用前

- 准备一个拥有目标 DNS 区域编辑权限的 Cloudflare API Token。
- 准备一条可访问的测速地址，例如公开可下载的 HTTP 文件地址。
- 安装时根据提示输入 Cloudflare API Token、Zone、完整域名和测速 URL。
- 配置保存在 `~/cf-ip/config.conf`，并设置为仅当前用户可读。
- 测速结果会保存到 `result-v4.csv` 和 `result-v6.csv`。
- 更新 DNS 时会删除目标域名现有的 A/AAAA 记录并重新创建。

