$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Log-Info($msg)    { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Log-Success($msg) { Write-Host "[ OK ] $msg" -ForegroundColor Green }
function Log-Warn($msg)    { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Error($msg)   { Write-Host "[ERR ] $msg" -ForegroundColor Red }

Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         红米 AX6S 固件刷写与 OpenWrt 升级工具          " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. 定义各模式的默认密码（支持脚本自身覆写持久化）
$defaultPassword1 = "84dd155b"
$defaultPassword2 = "BMb6_VjmBg!bVcE"

# 2. 检查固件是否存在
$firmwarePath = Join-Path (Get-Location) "factory.bin"
if (-not (Test-Path $firmwarePath)) {
    Log-Error "未在当前目录找到 factory.bin 固件文件。"
    Pause; exit
}
Log-Success "已就绪固件: factory.bin"

# 3. 检查 OpenSSH 客户端
$sshCap = Get-WindowsCapability -Online | Where-Object {$_.Name -like 'OpenSSH.Client*'}
if ($sshCap.State -ne 'Installed') {
    Log-Warn "系统未安装 OpenSSH Client 组件。"
    if ((Read-Host "是否立即自动安装？(y/n)").ToLower() -eq 'y') {
        Log-Info "正在安装 OpenSSH Client，请稍候..."
        Add-WindowsCapability -Online -Name $sshCap.Name
    } else {
        Log-Error "缺少 OpenSSH 客户端，无法继续传输。"
        Pause; exit
    }
} else {
    Log-Success "OpenSSH 客户端状态正常。"
}

# 4. 主菜单选择
Write-Host "`n----------------------------------------------------------" -ForegroundColor Cyan
Write-Host "请选择刷机模式：" -ForegroundColor Cyan
Write-Host "  [1] 原厂固件标准刷入 (写入整个 firmware 分区)" -ForegroundColor White
Write-Host "  [2] 扩容版本 / 升级 OpenWrt (Kernel + UBI 分离写入)" -ForegroundColor White
Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
$menuChoice = Read-Host "请输入选项编号 (1 或 2)"

if ($menuChoice -ne '1' -and $menuChoice -ne '2') {
    Log-Error "无效的选择，程序退出。"
    Pause; exit
}

# 5. 根据菜单模式绑定对应的默认密码
if ($menuChoice -eq '1') {
    $currentDefault = $defaultPassword1
} else {
    $currentDefault = $defaultPassword2
}

# 6. 获取路由器 IP
$gateway = (Get-NetRoute | Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'}).NextHop | Select-Object -Unique -First 1
if (-not $gateway) { $gateway = "192.168.31.1" }

Log-Info "默认网关检测结果: $gateway"
$routerIP = Read-Host "请输入路由器 IP [直接回车使用: $gateway]"
if ([string]::IsNullOrEmpty($routerIP)) { $routerIP = $gateway }

# 7. 密码获取、剪贴板写入与脚本自覆写逻辑
$password = Read-Host "请输入路由器密码 (直接回车默认使用: $currentDefault)"
if ([string]::IsNullOrEmpty($password)) {
    $password = $currentDefault
} else {
    if ($password -ne $currentDefault) {
        $scriptPath = $PSCommandPath
        if ($scriptPath -and (Test-Path $scriptPath)) {
            try {
                $scriptContent = Get-Content -Raw -Encoding UTF8 $scriptPath
                if ($menuChoice -eq '1') {
                    $scriptContent = $scriptContent -replace '\$defaultPassword1\s*=\s*"[^"]*"', "`$defaultPassword1 = `"$password`""
                } else {
                    $scriptContent = $scriptContent -replace '\$defaultPassword2\s*=\s*"[^"]*"', "`$defaultPassword2 = `"$password`""
                }
                Set-Content -Path $scriptPath -Value $scriptContent -Encoding UTF8 -NoNewline
                Log-Success "已成功将新密码永久写入本脚本文件，下次直接回车即可使用新密码！"
            } catch {
                Log-Warn "未能自动更新脚本文件（可能文件正被占用）：$_"
            }
        }
    }
}

# 使用 .NET Windows Forms 接口强制更新剪贴板
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Clipboard]::SetText($password)
Log-Success "密码已自动复制到剪贴板！后续若弹出输密码提示，直接按鼠标右键粘贴即可。"

# 8. 连通性测试
Log-Info "正在测试与路由器 ($routerIP) 的连通性..."
if (-not (Test-Connection -ComputerName $routerIP -Count 1 -Quiet)) {
    Log-Error "无法 Ping 通路由器，请检查网线连接与 IP 设置。"
    Pause; exit
}
Log-Success "路由器网络连通正常。"

# 定义公共的 SSH 连接参数
$sshOpts = @(
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "HostKeyAlgorithms=+ssh-rsa",
    "-o", "PubkeyAcceptedKeyTypes=+ssh-rsa"
)

# 9. 根据菜单模式执行前置逻辑
if ($menuChoice -eq '1') {
    Log-Info "正在通过 Telnet 连接路由器并配置原厂解锁环境..."
    $socket = $null; $stream = $null; $writer = $null
    try {
        $socket = New-Object System.Net.Sockets.TcpClient($routerIP, 23)
        $stream = $socket.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true

        Start-Sleep -Seconds 1
        $writer.WriteLine("root")
        Start-Sleep -Milliseconds 500
        $writer.WriteLine($password)
        Start-Sleep -Milliseconds 1000

        foreach ($cmd in @(
            "nvram set ssh_en=1",
            "nvram set uart_en=1",
            "nvram set boot_wait=on",
            "nvram set bootdelay=3",
            "nvram set flag_try_sys1_failed=0",
            "nvram set flag_try_sys2_failed=1",
            "nvram set flag_boot_rootfs=0",
            'nvram set "boot_fw1=run boot_rd_img;bootm"',
            "nvram set flag_boot_success=1",
            "nvram commit",
            "/etc/init.d/dropbear enable",
            "/etc/init.d/dropbear start"
        )) {
            $writer.WriteLine($cmd)
            Start-Sleep -Milliseconds 200
        }
        Log-Success "Telnet 配置指令下发成功。"
    } catch {
        Log-Error "Telnet 执行失败: $_"
        Pause; exit
    } finally {
        if ($writer) { $writer.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($socket) { $socket.Dispose() }
    }

    Log-Info "等待 SSH 服务初始化 (5 秒)..."
    Start-Sleep -Seconds 5
}
else {
    Log-Info "正在通过 SSH 连接路由器获取当前内核分区大小..."
    $mtdOutput = & ssh @sshOpts "root@${routerIP}" 'cat /proc/mtd'
    $currentKernelMB = 4
    $foundKernel = $false

    if ($mtdOutput) {
        foreach ($line in $mtdOutput) {
            if ($line -match '"kernel"') {
                if ($line -match '([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"kernel"') {
                    $hexSize = $Matches[1]
                    $bytes = [Convert]::ToInt64($hexSize, 16)
                    $currentKernelMB = [math]::Round($bytes / 1MB)
                    $foundKernel = $true
                    break
                }
            }
        }
    }

    if (-not $foundKernel) {
        Log-Warn "未能自动解析当前路由器的内核分区大小，默认按 4MB 计算。"
        $currentKernelMB = 4
    } else {
        Log-Success "当前系统 Kernel 分区大小: ${currentKernelMB} MB"
    }

    Log-Info "正在本地分析 $firmwarePath 固件结构以寻找 UBI 标志..."
    $bytes = [System.IO.File]::ReadAllBytes($firmwarePath)
    $pattern = [System.Text.Encoding]::ASCII.GetBytes("UBI#")
    $ubiOffset = -1

    for ($i = 0; $i -lt ($bytes.Length - 4); $i++) {
        if ($bytes[$i] -eq $pattern[0] -and $bytes[$i+1] -eq $pattern[1] -and $bytes[$i+2] -eq $pattern[2] -and $bytes[$i+3] -eq $pattern[3]) {
            $ubiOffset = $i
            break
        }
    }

    if ($ubiOffset -eq -1) {
        Log-Warn "未能在固件中找到 UBI# 标志！"
        $newKernelStr = "未知"
    } else {
        $newKernelMB = [math]::Round($ubiOffset / 1MB)
        $newKernelStr = "${newKernelMB} MB"
    }

    Log-Success "固件结构分析完成 (内核预留: $newKernelStr)"
}

# 10. 组装刷机指令（在末尾加上 && reboot，确保成功后优雅退出并重启）
if ($menuChoice -eq '1') {
    $execCmd = 'mtd write /tmp/factory.bin firmware && reboot || { rm -f /tmp/factory.bin; exit 1; }'
    $viewCmd = @"
mtd write /tmp/factory.bin firmware
reboot
(写入成功后将自动重启路由器)
"@
}
else {
    $execCmd = 'mount -o remount,ro /; mount -o remount,ro /overlay; cd /tmp; dd if=factory.bin bs=1M count=' + $currentKernelMB + ' | mtd write - kernel && dd if=factory.bin bs=1M skip=' + $currentKernelMB + ' | mtd write - ubi && reboot || rm -f /tmp/factory.bin'

    $viewCmd = @"
mount -o remount,ro /
mount -o remount,ro /overlay
cd /tmp
dd if=factory.bin bs=1M count=$currentKernelMB | mtd write - kernel
dd if=factory.bin bs=1M skip=$currentKernelMB | mtd write - ubi
reboot
(写入成功后将自动重启路由器)
"@
}

Write-Host "`n----------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  🚀 准备上传固件并执行刷机指令：" -ForegroundColor Cyan
Write-Host "  - 目标路由 IP  : $routerIP" -ForegroundColor White
Write-Host "  - 准备执行命令 :" -ForegroundColor White
Write-Host "$viewCmd" -ForegroundColor Yellow
Write-Host "----------------------------------------------------------" -ForegroundColor Cyan

$confirm = Read-Host "是否继续？(y/N)"
$confirmTrimmed = if ($confirm) { $confirm.Trim().ToLower() } else { "" }
if ($confirmTrimmed -ne 'y') {
    Log-Warn "用户取消操作，脚本退出。"
    Pause; exit
}

# 11. 通过 SCP 上传固件
Log-Info "正在通过 SCP 上传固件至 /tmp/factory.bin..."
& scp -O @sshOpts $firmwarePath "root@${routerIP}:/tmp/factory.bin"

if ($LASTEXITCODE -ne 0) {
    Log-Error "固件上传失败，请检查密码或 SSH 服务状态。"
    Pause; exit
}
Log-Success "固件上传成功。"

# 12. 执行刷机动作
if ($menuChoice -eq '1') {
    Log-Info "正在写入标准固件并重启..."
}
else {
    Log-Info "正在执行远程内核与 UBI 分区分离写入并重启..."
}

& ssh @sshOpts "root@${routerIP}" $execCmd

# 如果按 Ctrl+C 取消、密码输错或写入失败，这里能被精准捕获
if ($LASTEXITCODE -ne 0) {
    Log-Error "刷机执行被中断、密码错误或连接失败（操作已取消/未执行）。"
    Pause; exit
}

# 13. 完成提示
Write-Host ""
Log-Success "刷机指令已发送！路由器正在重启，请静候 2-3 分钟。"
Pause
