#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-web-tray 冒烟测试：参数校验、端口冲突、就绪探测、停止与孤儿进程兜底。

.DESCRIPTION
    用桩程序替换 dsh（真正监听端口并打印 `dsh web: <url>`），不需要安装真实 dsh 即可覆盖进程管理路径。
    真实 dsh 与 Edge 窗口行为另见 README。

    测试用 temp/smoke/data 作为独立状态目录（-DataRoot），不会碰 data/ 里的真实配置，也不会和在跑的托盘抢单实例锁。

    用法：powershell -NoProfile -File tests/smoke.ps1 [-TestPort 18999]（PowerShell 7 用 pwsh 亦可）
#>
[CmdletBinding()]
param(
    [int]$TestPort = 18999
)

$ErrorActionPreference = 'Stop'

$hostExePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$trayScript = Join-Path $repoRoot 'dsh-web-tray.ps1'
# 测试用独立状态目录，既能和正在运行的托盘共存，也不会污染 data/ 里的真实配置。
$stateRoot = Join-Path $repoRoot 'temp/smoke/data'
$trayLogPath = Join-Path $stateRoot 'tray.log'
$webLogPath = Join-Path $stateRoot 'web.log'
$pidPath = Join-Path $stateRoot 'tray.pid'
$stubDir = Join-Path $repoRoot 'temp/smoke'

$script:failures = 0
$script:checks = 0

function Assert-That {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )

    $script:checks++
    if ($Condition) {
        Write-Host "  ok   $Name" -ForegroundColor Green
    } else {
        $script:failures++
        $suffix = if ($Detail) { " — $Detail" } else { '' }
        Write-Host "  FAIL $Name$suffix" -ForegroundColor Red
    }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Test-PortListening {
    param([int]$Port)

    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-PortOwnerId {
    param([int]$Port)

    $connection = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
        return [int]$connection.OwningProcess
    }
    return 0
}

function Get-TrayLog {
    if (-not (Test-Path -LiteralPath $trayLogPath -PathType Leaf)) {
        return ''
    }
    return Get-Content -LiteralPath $trayLogPath -Raw
}

function Reset-State {
    param([switch]$KeepWebPid)

    $paths = @($trayLogPath, $webLogPath, "$webLogPath.1", $pidPath)
    if (-not $KeepWebPid) {
        $paths += (Join-Path $stateRoot 'web.pid')
    }
    foreach ($path in $paths) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Start-TrayHost {
    param(
        [string]$BindHost,
        [int]$Port,
        [switch]$NoWindow,
        [string]$ExtraDataRoot
    )

    $arguments = @(
        '-NoLogo', '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$trayScript`"",
        '-Manager', '-DataRoot', "`"$stateRoot`""
    )
    if ($BindHost) {
        $arguments += @('-BindHost', $BindHost)
    }
    if ($Port) {
        $arguments += @('-Port', ([string]$Port))
    }
    if ($NoWindow) {
        $arguments += '-NoWindow'
    }

    return Start-Process -FilePath $hostExePath -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Stop-TrayHost {
    param([int]$ProcessId)

    if (-not $ProcessId) {
        return
    }
    if (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
    $null = Wait-Until -Condition { -not (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue) } -TimeoutSeconds 10
}

function Invoke-TrayScript {
    # 5.1 下把原生命令 stderr 重定向进管道会触发 NativeCommandError，这里改用文件重定向。
    param([string[]]$Arguments)

    $stdoutPath = Join-Path $stateRoot 'invoke.stdout.log'
    $stderrPath = Join-Path $stateRoot 'invoke.stderr.log'
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $processArguments = @('-NoProfile', '-File', "`"$trayScript`"") + $Arguments
    $consoleEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    try {
        Start-Process -FilePath $hostExePath -ArgumentList $processArguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath | Out-Null
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath, $consoleEncoding) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath, $consoleEncoding) } else { '' }
        return ([string]$stdout + [string]$stderr)
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $pidPath) {
    $runningId = 0
    if ([int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$runningId) -and
        (Get-CimInstance Win32_Process -Filter "ProcessId = $runningId" -ErrorAction SilentlyContinue)) {
        throw "检测到正在运行的托盘宿主（PID $runningId），请先退出托盘再跑冒烟测试。"
    }
}

New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

# 桩程序：解析 --port、真正监听该端口、打印与 dsh web 相同的就绪行，然后常驻。
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$port = 0
for ($index = 0; $index -lt $Arguments.Count; $index++) {
    if ($Arguments[$index] -eq '--port') {
        $port = [int]$Arguments[$index + 1]
    }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
Write-Output "dsh web: http://127.0.0.1:$port/?token=smoke-token"
[Console]::Out.Flush()
try {
    while ($true) {
        Start-Sleep -Seconds 1
    }
} finally {
    $listener.Stop()
}
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'dsh-stub.ps1') -Encoding utf8

@'
@echo off
powershell.exe -NoLogo -NoProfile -File "%~dp0dsh-stub.ps1" %*
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'dsh.cmd') -Encoding ascii

$originalPath = $env:PATH
$env:PATH = "$stubDir;$originalPath"

try {
    Write-Host "`n== 1. 配置与启动器参数校验 =="
    Reset-State
    Remove-Item -LiteralPath (Join-Path $stateRoot 'config.json') -Force -ErrorAction SilentlyContinue

    $badHost = Invoke-TrayScript -Arguments @('-DataRoot', $stateRoot, '-BindHost', 'not-an-ip')
    Assert-That '非法 BindHost 被拒绝' ($badHost -match 'BindHost 必须是具体的 IPv4/IPv6 地址')

    $badSize = Invoke-TrayScript -Arguments @('-DataRoot', $stateRoot, '-WindowWidth', '0')
    Assert-That '非法窗口尺寸被拒绝' ($badSize -match 'WindowWidth 和 WindowHeight 必须是大于 0 的整数')

    $badPort = Invoke-TrayScript -Arguments @('-DataRoot', $stateRoot, '-Port', '0')
    Assert-That '命令行覆盖的非法 Port 被拒绝' ($badPort -match 'Port 必须在 1-65535 之间') $badPort

    $configPath = Join-Path $stateRoot 'config.json'
    Assert-That '首次运行生成 config.json' (Test-Path -LiteralPath $configPath -PathType Leaf)
    $savedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-That '默认配置含窗口位置' ($null -ne $savedConfig.window.left -and $null -ne $savedConfig.window.top) ($savedConfig | ConvertTo-Json -Depth 4)
    Assert-That '默认配置含窗口尺寸' ($savedConfig.window.width -gt 0 -and $savedConfig.window.height -gt 0) ($savedConfig | ConvertTo-Json -Depth 4)

    Set-Content -LiteralPath $configPath -Value '{ "port": "not-a-number" }' -Encoding utf8
    $badConfig = Invoke-TrayScript -Arguments @('-DataRoot', $stateRoot)
    Assert-That '损坏的 config.json 被拒绝' ($badConfig -match '配置项类型不正确') $badConfig

    # 配置项生效：宿主不带任何命令行覆盖时，按 config.json 里的 host/port/几何启动。
    Reset-State
    [ordered]@{
        bindHost   = '127.0.0.1'
        port       = $TestPort
        openWindow = $false
        window     = [ordered]@{ left = -1928; top = 64; width = 1280; height = 900 }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding utf8
    $hostProcess = Start-TrayHost
    try {
        $configReady = Wait-Until -Condition { (Get-TrayLog) -match 'dsh web 已就绪' } -TimeoutSeconds 40
        Assert-That '按 config.json 的 host/port 启动' ($configReady -and (Test-PortListening -Port $TestPort)) (Get-TrayLog)
        Assert-That '配置 openWindow=false 时不自动开窗' (-not ((Get-TrayLog) -match '打开 Edge app 窗口'))
    } finally {
        Stop-TrayHost -ProcessId $(if ($hostProcess) { $hostProcess.Id } else { 0 })
    }

    Write-Host "`n== 2. 端口被占用时直接报错 =="
    Reset-State
    $blocker = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $TestPort)
    $blocker.Start()
    $hostProcess = $null
    try {
        $hostProcess = Start-TrayHost -BindHost '127.0.0.1' -Port $TestPort -NoWindow
        $conflictLogged = Wait-Until -Condition { (Get-TrayLog) -match "端口 $TestPort 已被 .* 占用" } -TimeoutSeconds 30
    } finally {
        $blocker.Stop()
        Stop-TrayHost -ProcessId $(if ($hostProcess) { $hostProcess.Id } else { 0 })
    }
    Assert-That '端口冲突写入日志' $conflictLogged (Get-TrayLog)
    Assert-That '端口冲突时不启动 dsh web' (-not ((Get-TrayLog) -match '启动 dsh web（PID'))

    Write-Host "`n== 3. 就绪探测 =="
    Reset-State
    $hostProcess = Start-TrayHost -BindHost '127.0.0.1' -Port $TestPort -NoWindow
    try {
        $ready = Wait-Until -Condition { (Get-TrayLog) -match 'dsh web 已就绪' } -TimeoutSeconds 40
        Assert-That '从启动输出捕获就绪地址' $ready (Get-TrayLog)
        Assert-That '端口进入监听' (Test-PortListening -Port $TestPort)
        Assert-That '写入 tray.pid' (Test-Path -LiteralPath $pidPath -PathType Leaf)
        Assert-That '-NoWindow 时不自动开窗' (-not ((Get-TrayLog) -match '打开 Edge app 窗口'))
        Assert-That '托盘日志不含 token' ((Get-TrayLog) -notmatch 'smoke-token')

        Write-Host "`n== 4. 宿主被强杀：Job 兜底 + 下次启动清理遗留 =="
        $childPid = Get-PortOwnerId -Port $TestPort
        Assert-That '就绪后能定位 dsh web 进程' ($childPid -gt 0)
        $webPidPath = Join-Path $stateRoot 'web.pid'
        Assert-That '写入 web.pid' (Test-Path -LiteralPath $webPidPath -PathType Leaf)
        Stop-TrayHost -ProcessId $hostProcess.Id
        $released = Wait-Until -Condition { -not (Test-PortListening -Port $TestPort) } -TimeoutSeconds 20
        Assert-That 'Job 兜底结束 dsh web 进程树' $released "子进程 PID $childPid 仍在监听"

        # 模拟「Job 没兜住」的残留：手工留一条指向仍在监听进程的 pid 记录。
        Write-Host "`n== 5. 遗留记录清理 =="
        $orphan = Start-Process $hostExePath -ArgumentList @(
            '-NoLogo', '-NoProfile', '-Command',
            "`$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $TestPort); `$l.Start(); Start-Sleep 300"
        ) -WindowStyle Hidden -PassThru
        $listening = Wait-Until -Condition { Test-PortListening -Port $TestPort } -TimeoutSeconds 20
        Assert-That '构造出占用端口的残留进程' $listening

        $deadManagerId = 999999
        [ordered]@{ managerPid = $deadManagerId; processId = $orphan.Id } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $webPidPath -Encoding utf8
        Reset-State -KeepWebPid

        $hostProcess = Start-TrayHost -BindHost '127.0.0.1' -Port $TestPort -NoWindow
        $reclaimed = Wait-Until -Condition { (Get-TrayLog) -match '清理上次遗留的 dsh web' } -TimeoutSeconds 30
        Assert-That '新宿主清理上次遗留的 dsh web' $reclaimed (Get-TrayLog)
        Assert-That '清理后服务重新就绪' (Wait-Until -Condition { (Get-TrayLog) -match 'dsh web 已就绪' } -TimeoutSeconds 40)
        Assert-That '遗留进程已被替换' ((Get-PortOwnerId -Port $TestPort) -ne $orphan.Id)
        if (-not $orphan.HasExited) {
            Stop-Process -Id $orphan.Id -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Stop-TrayHost -ProcessId $hostProcess.Id
        $leftoverId = 0
        if (Test-Path -LiteralPath $pidPath) {
            if ([int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$leftoverId)) {
                Stop-TrayHost -ProcessId $leftoverId
            }
        }
        $null = Wait-Until -Condition { -not (Test-PortListening -Port $TestPort) } -TimeoutSeconds 15
    }

    Write-Host "`n== 6. -Stop 停止托盘 =="
    Reset-State
    $hostProcess = Start-TrayHost -BindHost '127.0.0.1' -Port $TestPort -NoWindow
    try {
        $ready = Wait-Until -Condition { (Get-TrayLog) -match 'dsh web 已就绪' } -TimeoutSeconds 40
        Assert-That '-Stop 测试宿主已就绪' $ready (Get-TrayLog)

        $stopOutput = Invoke-TrayScript -Arguments @('-DataRoot', $stateRoot, '-Stop')
        Assert-That '-Stop 返回退出确认' ($stopOutput -match 'DSH Web 托盘已退出') $stopOutput
        Assert-That '-Stop 后宿主进程退出' (Wait-Until -Condition { -not (Get-CimInstance Win32_Process -Filter "ProcessId = $($hostProcess.Id)" -ErrorAction SilentlyContinue) } -TimeoutSeconds 10)
        Assert-That '-Stop 后端口释放' (Wait-Until -Condition { -not (Test-PortListening -Port $TestPort) } -TimeoutSeconds 10)
        Assert-That '-Stop 后清理 tray.pid' (-not (Test-Path -LiteralPath $pidPath -PathType Leaf))
    } finally {
        Stop-TrayHost -ProcessId $hostProcess.Id
        $null = Wait-Until -Condition { -not (Test-PortListening -Port $TestPort) } -TimeoutSeconds 15
    }

    Write-Host "`n== 7. 缺少 dsh 时保留托盘并提示 =="
    Reset-State
    $missingHost = $null
    $savedPath = $env:PATH
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $missingHost = Start-TrayHost -BindHost '127.0.0.1' -Port $TestPort -NoWindow
    } finally {
        $env:PATH = $savedPath
    }
    try {
        $missingLogged = Wait-Until -Condition { (Get-TrayLog) -match '未在 PATH 中找到 dsh 命令' } -TimeoutSeconds 30
        Assert-That '缺少 dsh 时记录错误' $missingLogged (Get-TrayLog)
        Assert-That '缺少 dsh 时托盘仍运行' ([bool](Get-CimInstance Win32_Process -Filter "ProcessId = $($missingHost.Id)" -ErrorAction SilentlyContinue))
        $stopOutput = Invoke-TrayScript -Arguments @('-DataRoot', $stateRoot, '-Stop')
        Assert-That '-Stop 可停止缺少 dsh 的托盘' ($stopOutput -match 'DSH Web 托盘已退出') $stopOutput
    } finally {
        Stop-TrayHost -ProcessId $(if ($missingHost) { $missingHost.Id } else { 0 })
        $null = Wait-Until -Condition { -not (Test-PortListening -Port $TestPort) } -TimeoutSeconds 15
    }
} finally {
    $env:PATH = $originalPath
    Reset-State
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "全部 $($script:checks) 项通过" -ForegroundColor Green
    exit 0
}
Write-Host "$($script:failures)/$($script:checks) 项失败" -ForegroundColor Red
exit 1
