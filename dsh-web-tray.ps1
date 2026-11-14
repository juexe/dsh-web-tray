#Requires -Version 5.1
<#
.SYNOPSIS
    DSH Web 托盘宿主：托管 `dsh --profile web`，并用 Edge app 窗口承载 Web 界面。

.DESCRIPTION
    全部启动参数来自 `data/config.json`（相对脚本目录），默认内容等价于：

        dsh --profile web --host 127.0.0.1 --port 8310 --no-open

    直接运行脚本时只做启动器：确认没有已运行的宿主后，隐藏拉起 `-Manager` 宿主进程并退出。
    宿主常驻托盘，负责：
      * 启动 / 停止 / 重启 dsh web 子进程，异常退出时退避重启；
      * 从子进程输出中捕获 dsh 启动时打印的带 token 地址；
      * 用独立 Edge profile 打开 `--app=` 窗口，左键托盘或菜单可聚焦 / 重开；
      * 端口被占用或本机没有该地址时直接报错停止，不清理任何外部进程；
      * 开机自启动（启动目录快捷方式）、打开数据目录、退出。

    状态、日志与 Edge profile 目录：data/

.PARAMETER Manager
    内部参数：以托盘宿主身份运行，由启动器隐藏拉起。

.PARAMETER BindHost
    覆盖配置里的 dsh web 绑定地址，仅对本次启动生效。

.PARAMETER Port
    覆盖配置里的 dsh web 监听端口，仅对本次启动生效。

.PARAMETER WindowLeft
    覆盖配置里的 Edge app 窗口左边距（DIP，多显示器可为负），仅对本次启动生效。

.PARAMETER WindowTop
    覆盖配置里的 Edge app 窗口上边距（DIP），仅对本次启动生效。

.PARAMETER WindowWidth
    覆盖配置里的 Edge app 窗口宽度（DIP），仅对本次启动生效。

.PARAMETER WindowHeight
    覆盖配置里的 Edge app 窗口高度（DIP），仅对本次启动生效。

.PARAMETER NoWindow
    本次启动不自动打开 Edge 窗口；开机自启动快捷方式会带上此参数。

.EXAMPLE
    .\dsh-web-tray.cmd

.EXAMPLE
    .\dsh-web-tray.cmd -Port 8311 -NoWindow
#>
[CmdletBinding()]
param(
    [switch]$Manager,
    [string]$BindHost,
    [Nullable[int]]$Port,
    [Nullable[int]]$WindowLeft,
    [Nullable[int]]$WindowTop,
    [Nullable[int]]$WindowWidth,
    [Nullable[int]]$WindowHeight,
    [switch]$NoWindow,
    # 内部参数：测试用来隔离数据目录，避免和正在运行的托盘抢 pid 与单实例锁。
    # 注意 PowerShell 变量名不区分大小写，内部一律用 $dataDir，别再起 $dataRoot 这类同音名。
    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'dsh-web-tray 仅支持 Windows。'
}

$scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$scriptRoot = Split-Path -Parent $scriptPath
# 本次宿主沿用当前可执行文件：.cmd 默认用 5.1，手动用 pwsh 启动时仍按 7 运行。
# 开机自启动固定指向系统自带的 Windows PowerShell 5.1，避免 pwsh 7 升级或迁移影响长期后台运行。
$script:hostExePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:autoStartExePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:webJobHandle = [IntPtr]::Zero
$dataDir = if ($DataRoot) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataRoot) } else { Join-Path $scriptRoot 'data' }
$configPath = Join-Path $dataDir 'config.json'
$webLogPath = Join-Path $dataDir 'web.log'
$trayLogPath = Join-Path $dataDir 'tray.log'
$pidPath = Join-Path $dataDir 'tray.pid'
$webPidPath = Join-Path $dataDir 'web.pid'
$requestPath = Join-Path $dataDir 'request.json'
$edgeProfileDir = Join-Path $dataDir 'edge-profile'
$iconPath = Join-Path $scriptRoot 'assets/dsh-web-tray.ico'
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'DSH Web Tray.lnk'
# 单实例锁跟着状态目录走：同一个 data/ 只允许一个宿主，不同 data/ 互不影响。
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $dataDirHash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($dataDir.ToLowerInvariant()))
} finally {
    $sha256.Dispose()
}
$mutexName = 'Local\DshWebTray-' + [System.BitConverter]::ToString($dataDirHash).Replace('-', '').Substring(0, 16)
$webLogLimitBytes = 5MB
$startupTimeoutSeconds = 90
$restartDelays = @(2, 5, 10, 20, 30)

# 窗口几何沿用 Edge 的 DIP 单位（`--window-position` / `--window-size` 同一套坐标系），
# 不随显示器 DPI 变化，换缩放后仍是同一块物理区域。
$script:defaultConfig = [ordered]@{
    bindHost   = '127.0.0.1'
    port       = 8310
    openWindow = $true
    window     = [ordered]@{
        left   = 50
        top    = 0
        width  = 1813
        height = 1158
    }
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------

function Write-TrayLog {
    param(
        [string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info'
    )

    $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}][{1}] {2}' -f (Get-Date), $Level, $Message
    try {
        Add-Content -LiteralPath $trayLogPath -Value $line -Encoding utf8
    } catch {
        # 日志写入失败不能影响托盘运行。
    }
}

function Format-Exception {
    param([object]$ErrorRecord)

    if ($ErrorRecord.Exception) {
        return "$($ErrorRecord.Exception.GetType().FullName): $($ErrorRecord.Exception.Message)"
    }
    return [string]$ErrorRecord
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

function Write-DefaultConfig {
    $script:defaultConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding utf8
}

function Initialize-DataRoot {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-DefaultConfig
        Write-TrayLog "已生成默认配置：$configPath"
    }
}

function Read-TrayConfig {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "配置文件不存在：$configPath"
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "配置文件无法解析：$configPath — $($_.Exception.Message)"
    }
    if ($null -eq $raw) {
        throw "配置文件内容为空：$configPath"
    }

    $defaults = $script:defaultConfig
    $windowDefaults = $defaults.window
    try {
        $bindHost = if ($raw.PSObject.Properties['bindHost'] -and $raw.bindHost) { [string]$raw.bindHost } else { $defaults.bindHost }
        $port = if ($raw.PSObject.Properties['port']) { [int]$raw.port } else { $defaults.port }
        $openWindow = if ($raw.PSObject.Properties['openWindow']) { [bool]$raw.openWindow } else { $defaults.openWindow }

        $window = $raw.window
        $left = if ($window -and $window.PSObject.Properties['left']) { [int]$window.left } else { $windowDefaults.left }
        $top = if ($window -and $window.PSObject.Properties['top']) { [int]$window.top } else { $windowDefaults.top }
        $width = if ($window -and $window.PSObject.Properties['width']) { [int]$window.width } else { $windowDefaults.width }
        $height = if ($window -and $window.PSObject.Properties['height']) { [int]$window.height } else { $windowDefaults.height }
    } catch {
        throw "配置项类型不正确：$configPath — $($_.Exception.Message)"
    }

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($bindHost, [ref]$parsedAddress)) {
        throw "配置项 bindHost 必须是具体的 IPv4/IPv6 地址，当前为：$bindHost"
    }
    if ($port -lt 1 -or $port -gt 65535) {
        throw "配置项 port 必须在 1-65535 之间，当前为：$port"
    }
    if ($width -le 0 -or $height -le 0) {
        throw "配置项 window.width / window.height 必须是大于 0 的整数，当前为：${width}x${height}"
    }

    return [pscustomobject]@{
        BindHost   = $bindHost
        Port       = $port
        OpenWindow = $openWindow
        Left       = $left
        Top        = $top
        Width      = $width
        Height     = $height
    }
}

function Get-EffectiveConfig {
    # 配置文件的值为准，命令行参数仅覆盖本次启动。
    $config = Read-TrayConfig
    if ($BindHost) { $config.BindHost = $BindHost }
    if ($null -ne $Port) { $config.Port = [int]$Port }
    if ($null -ne $WindowLeft) { $config.Left = [int]$WindowLeft }
    if ($null -ne $WindowTop) { $config.Top = [int]$WindowTop }
    if ($null -ne $WindowWidth) { $config.Width = [int]$WindowWidth }
    if ($null -ne $WindowHeight) { $config.Height = [int]$WindowHeight }
    if ($NoWindow) { $config.OpenWindow = $false }

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($config.BindHost, [ref]$parsedAddress)) {
        throw "BindHost 必须是具体的 IPv4/IPv6 地址，收到：$($config.BindHost)"
    }
    if ($config.Port -lt 1 -or $config.Port -gt 65535) {
        throw "Port 必须在 1-65535 之间，收到：$($config.Port)"
    }
    if ($config.Width -le 0 -or $config.Height -le 0) {
        throw 'WindowWidth 和 WindowHeight 必须是大于 0 的整数。'
    }
    return $config
}

# ---------------------------------------------------------------------------
# 进程、端口、日志读取
# ---------------------------------------------------------------------------

function Resolve-DshCommand {
    $commands = @(Get-Command 'dsh' -CommandType Application -ErrorAction SilentlyContinue)
    # 同名文件里还有 unix sh 脚本，cmd 无法执行，只接受 Windows 可执行扩展名。
    $command = $commands |
        Where-Object { $_.Source -match '\.(cmd|bat|exe)$' } |
        Select-Object -First 1
    if (-not $command -or -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        throw '未在 PATH 中找到 dsh 命令（.cmd/.exe）。请先安装 DeepSeek Harness CLI，或把它加入 PATH。'
    }
    return $command.Source
}

function Test-BindHostAvailable {
    param([string]$Address)

    if (-not (Get-NetIPAddress -IPAddress $Address -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $false
    }
    return $true
}

function Get-PortOwner {
    param([int]$ListenPort)

    $connection = Get-NetTCPConnection -State Listen -LocalPort $ListenPort -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) {
        return $null
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$connection.OwningProcess)" -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        ProcessId = [int]$connection.OwningProcess
        Name      = if ($process) { [string]$process.Name } else { 'unknown' }
    }
}

function Stop-ProcessTree {
    param([int]$RootProcessId)

    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ids = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $ids.Add($RootProcessId)
    $queue.Enqueue($RootProcessId)

    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        foreach ($process in $processes) {
            $processId = [int]$process.ProcessId
            if ([int]$process.ParentProcessId -eq $parentId -and -not $ids.Contains($processId)) {
                $ids.Add($processId)
                $queue.Enqueue($processId)
            }
        }
    }

    # 广度优先收集，倒序停止即先停叶子进程。
    $ordered = $ids.ToArray()
    [array]::Reverse($ordered)
    foreach ($processId in $ordered) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}

function Test-ProcessAlive {
    param([int]$ProcessId)

    return [bool](Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue)
}

function Read-WebPidRecord {
    if (-not (Test-Path -LiteralPath $webPidPath -PathType Leaf)) {
        return $null
    }

    $text = (Get-Content -LiteralPath $webPidPath -Raw -ErrorAction SilentlyContinue).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        $record = $text | ConvertFrom-Json
        if ($record.managerPid -and $record.processId) {
            return [pscustomobject]@{
                ManagerPid = [int]$record.managerPid
                ProcessId  = [int]$record.processId
            }
        }
    } catch {
        # 损坏的 pid 文件按无记录处理。
    }
    return $null
}

function Clear-WebPidRecord {
    Remove-Item -LiteralPath $webPidPath -Force -ErrorAction SilentlyContinue
}

function Remove-OrphanWebServer {
    # 宿主被强杀（任务管理器结束进程、关机前的残留）时，上一次的 dsh web 可能仍在监听。
    # 只清理 pid 记录里属于我们自己的那棵进程树，外部实例一律不碰。
    $record = Read-WebPidRecord
    if (-not $record) {
        return
    }

    if (Test-ProcessAlive -ProcessId $record.ManagerPid) {
        return
    }

    if (Test-ProcessAlive -ProcessId $record.ProcessId) {
        Write-TrayLog "清理上次遗留的 dsh web 进程树（PID $($record.ProcessId)）"
        Stop-ProcessTree -RootProcessId $record.ProcessId
    }
    Clear-WebPidRecord
}

function Initialize-WebJob {
    if ($script:webJobHandle -ne [IntPtr]::Zero) {
        return
    }

    # kill-on-job-close：宿主即便被强杀，dsh web 进程树也会随之结束，不会留下占端口的孤儿。
    # 注意：若进程已先启动，子进程可能已逃出该 Job，因此 Start-WebServer 先建 Job 再起进程。
    if (-not ('DshWebTrayJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DshWebTrayJob {
  [StructLayout(LayoutKind.Sequential)]
  private struct IO_COUNTERS {
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

  [DllImport("kernel32.dll")]
  private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLength);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr handle);

  private const int JobObjectExtendedLimitInformation = 9;
  private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

  public static IntPtr Create() {
    var job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) {
      throw new InvalidOperationException("CreateJobObject failed: " + Marshal.GetLastWin32Error());
    }

    var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    var length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    var buffer = Marshal.AllocHGlobal(length);
    try {
      Marshal.StructureToPtr(info, buffer, false);
      if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)length)) {
        throw new InvalidOperationException("SetInformationJobObject failed: " + Marshal.GetLastWin32Error());
      }
    } finally {
      Marshal.FreeHGlobal(buffer);
    }
    return job;
  }

  public static bool Assign(IntPtr job, IntPtr process) {
    var ok = AssignProcessToJobObject(job, process);
    if (!ok) lastError = Marshal.GetLastWin32Error();
    return ok;
  }

  private static int lastError;

  public static int LastError() { return lastError; }
}
'@
    }

    $script:webJobHandle = [DshWebTrayJob]::Create()
}

function Close-WebJob {
    if ($script:webJobHandle -and $script:webJobHandle -ne [IntPtr]::Zero) {
        [void][DshWebTrayJob]::CloseHandle($script:webJobHandle)
        $script:webJobHandle = [IntPtr]::Zero
    }
}

function Resolve-WebLogPath {
    # cmd 的 >> 只以 FILE_SHARE_READ 打开日志，同一文件不能被两个追加写者共享。
    # 若上一次的残留进程还占着 web.log，就为这次启动换一个独立日志，避免启动即失败。
    try {
        $stream = [System.IO.File]::Open(
            $webLogPath,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        $stream.Dispose()
        return $webLogPath
    } catch {
        $fallback = Join-Path $dataDir ('web-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
        Write-TrayLog "web.log 被其他进程占用，本次改用 $fallback" 'warn'
        return $fallback
    }
}

function Rotate-Log {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if ((Get-Item -LiteralPath $Path).Length -le $webLogLimitBytes) {
        return
    }

    try {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    } catch {
        Write-TrayLog "轮转日志 $Path 失败：$(Format-Exception -ErrorRecord $_)" 'warn'
    }
}

function Read-WebLogTail {
    if (-not $script:activeWebLogPath -or -not (Test-Path -LiteralPath $script:activeWebLogPath)) {
        return ''
    }

    $stream = $null
    $reader = $null
    try {
        # cmd 以追加方式持有日志，读取必须允许共享写入。
        $stream = [System.IO.File]::Open(
            $script:activeWebLogPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        if ($stream.Length -lt $script:webLogOffset) {
            $script:webLogOffset = 0
        }
        [void]$stream.Seek($script:webLogOffset, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $script:webLogOffset = $stream.Position
        return $text
    } catch {
        return ''
    } finally {
        if ($reader) {
            $reader.Dispose()
        } elseif ($stream) {
            $stream.Dispose()
        }
    }
}
# ---------------------------------------------------------------------------
# Edge app 窗口
# ---------------------------------------------------------------------------

function Initialize-WindowInterop {
    if ($script:windowInteropLoaded) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class DshWebTrayWindowInfo {
  public int ProcessId { get; set; }
  public IntPtr Handle { get; set; }
  public string Title { get; set; }
}

public static class DshWebTrayInterop {
  private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  private const uint SWP_NOSIZE = 0x0001;
  private const uint SWP_NOMOVE = 0x0002;
  private const uint SWP_SHOWWINDOW = 0x0040;
  private const int WM_CLOSE = 0x0010;

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll")]
  private static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError = true)]
  private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll", SetLastError = true)]
  private static extern int GetWindowTextLength(IntPtr hWnd);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);

  [DllImport("kernel32.dll")]
  private static extern uint GetCurrentThreadId();

  [DllImport("user32.dll")]
  private static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

  [DllImport("user32.dll")]
  private static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  private static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  private static extern bool BringWindowToTop(IntPtr hWnd);

  [DllImport("user32.dll")]
  private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

  [DllImport("user32.dll")]
  private static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

  /// <summary>Edge app 窗口的类名；同一进程里还有不可见的辅助窗口，只认这个。</summary>
  private const string APP_WINDOW_CLASS = "Chrome_WidgetWin_1";

  /// <summary>app 窗口标题非空，浏览器窗口标题可能为空。</summary>
  public static DshWebTrayWindowInfo[] GetAppWindows(int[] processIds) {
    var processIdSet = new HashSet<int>(processIds);
    var windows = new List<DshWebTrayWindowInfo>();
    EnumWindows((hWnd, lParam) => {
      if (!IsWindowVisible(hWnd)) {
        return true;
      }

      int processId;
      GetWindowThreadProcessId(hWnd, out processId);
      if (!processIdSet.Contains(processId)) {
        return true;
      }

      var className = new StringBuilder(256);
      GetClassName(hWnd, className, className.Capacity);
      if (className.ToString() != APP_WINDOW_CLASS) {
        return true;
      }

      var textLength = GetWindowTextLength(hWnd);
      if (textLength <= 0) {
        return true;
      }

      var title = new StringBuilder(textLength + 1);
      GetWindowText(hWnd, title, title.Capacity);
      var titleText = title.ToString();
      if (string.IsNullOrWhiteSpace(titleText)) {
        return true;
      }

      windows.Add(new DshWebTrayWindowInfo {
        ProcessId = processId,
        Handle = hWnd,
        Title = titleText
      });
      return true;
    }, IntPtr.Zero);
    return windows.ToArray();
  }

  public static bool ForceForegroundWindow(IntPtr hWnd) {
    ShowWindowAsync(hWnd, 9);

    int targetProcessId;
    var targetThreadId = GetWindowThreadProcessId(hWnd, out targetProcessId);
    var currentThreadId = GetCurrentThreadId();
    var foregroundWindow = GetForegroundWindow();
    var foregroundThreadId = 0u;
    if (foregroundWindow != IntPtr.Zero) {
      int foregroundProcessId;
      foregroundThreadId = GetWindowThreadProcessId(foregroundWindow, out foregroundProcessId);
    }

    var attachedTargetThread = false;
    var attachedForegroundThread = false;
    try {
      if (targetThreadId != 0 && targetThreadId != currentThreadId) {
        attachedTargetThread = AttachThreadInput(currentThreadId, targetThreadId, true);
      }
      if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId) {
        attachedForegroundThread = AttachThreadInput(currentThreadId, foregroundThreadId, true);
      }

      BringWindowToTop(hWnd);
      SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
      SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
      return SetForegroundWindow(hWnd);
    } finally {
      if (attachedForegroundThread) {
        AttachThreadInput(currentThreadId, foregroundThreadId, false);
      }
      if (attachedTargetThread) {
        AttachThreadInput(currentThreadId, targetThreadId, false);
      }
    }
  }

  public static bool CloseWindow(IntPtr hWnd) {
    return PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
  }
}
'@
    $script:windowInteropLoaded = $true
}

function Resolve-EdgePath {
    $command = Get-Command 'msedge.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft/Edge/Application/msedge.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    throw '未找到 Microsoft Edge，无法打开 Web 界面。'
}

function Get-TrayEdgeProcessIds {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue)
    return [int[]]@(
        $processes |
            Where-Object {
                $_.CommandLine -and
                    $_.CommandLine.IndexOf($edgeProfileDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            } |
            ForEach-Object { [int]$_.ProcessId }
    )
}

function Get-TrayEdgeWindows {
    $processIds = @(Get-TrayEdgeProcessIds)
    if ($processIds.Count -eq 0) {
        return @()
    }

    Initialize-WindowInterop
    return @([DshWebTrayInterop]::GetAppWindows($processIds))
}

function Close-TrayEdgeWindows {
    try {
        $windows = @(Get-TrayEdgeWindows)
        if ($windows.Count -eq 0) {
            return
        }

        Initialize-WindowInterop
        foreach ($window in $windows) {
            [void][DshWebTrayInterop]::CloseWindow($window.Handle)
            Write-TrayLog "关闭 Edge 窗口（PID $($window.ProcessId)）：$($window.Title)"
        }

        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 100
            if (@(Get-TrayEdgeWindows).Count -eq 0) {
                return
            }
        }
        Write-TrayLog '等待 Edge 窗口关闭超时。' 'warn'
    } catch {
        Write-TrayLog "关闭 Edge 窗口失败：$(Format-Exception -ErrorRecord $_)" 'warn'
    }
}

function ConvertTo-ProcessArgumentString {
    # .NET Framework 4.8 的 ProcessStartInfo 没有 ArgumentList，只能拼接 Arguments 字符串。
    param([string[]]$Tokens)

    $parts = foreach ($token in $Tokens) {
        if ($token -eq '') {
            '""'
        } elseif ($token -match '[\s"]') {
            '"' + $token.Replace('"', '\"') + '"'
        } else {
            $token
        }
    }
    return ($parts -join ' ')
}

function Start-TrayEdgeWindow {
    $edgePath = Resolve-EdgePath

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $edgePath
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = ConvertTo-ProcessArgumentString @(
        "--app=$($script:webUrl)"
        "--user-data-dir=$edgeProfileDir"
        # Edge 的 --window-position / --window-size 用 DIP，且比 profile 里记的窗口状态优先。
        "--window-position=$($script:windowLeft),$($script:windowTop)"
        "--window-size=$($script:windowWidth),$($script:windowHeight)"
        # 独立 profile 一旦登录 Edge 账号就会把日常浏览器的扩展 / 书签同步进来，这里直接禁掉。
        '--disable-sync'
        '--no-first-run'
        '--no-default-browser-check'
    )
    [void][System.Diagnostics.Process]::Start($startInfo)

    Write-TrayLog "打开 Edge app 窗口：$($script:webDisplayUrl)，位置 $($script:windowLeft),$($script:windowTop)，尺寸 $($script:windowWidth)x$($script:windowHeight)"
}

function Show-WebWindow {
    if ([string]::IsNullOrWhiteSpace($script:webUrl)) {
        Write-TrayLog 'Web 服务尚未就绪，忽略打开窗口请求。' 'warn'
        Show-TrayNotification -Title 'DSH Web 尚未就绪' -Message "端口 $($script:port) 上的服务还没有就绪，请稍后再试。" -Icon Warning
        return
    }

    try {
        $windows = @(Get-TrayEdgeWindows)
        if ($windows.Count -gt 0) {
            Initialize-WindowInterop
            $window = $windows | Select-Object -First 1
            $focused = [DshWebTrayInterop]::ForceForegroundWindow($window.Handle)
            Write-TrayLog "聚焦 Edge 窗口（PID $($window.ProcessId)）：$($window.Title)，focused=$focused"
            return
        }
        Start-TrayEdgeWindow
    } catch {
        $message = Format-Exception -ErrorRecord $_
        Write-TrayLog "打开 Web 界面失败：$message" 'error'
        Show-TrayNotification -Title '打开 Web 界面失败' -Message $message -Icon Warning
    }
}

# ---------------------------------------------------------------------------
# dsh web 子进程
# ---------------------------------------------------------------------------

function Show-TrayNotification {
    param(
        [string]$Title,
        [string]$Message,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )

    if (-not $script:notifyIcon) {
        return
    }

    try {
        $script:notifyIcon.BalloonTipTitle = $Title
        $script:notifyIcon.BalloonTipText = $Message
        $script:notifyIcon.BalloonTipIcon = $Icon
        $script:notifyIcon.ShowBalloonTip(5000)
    } catch {
        Write-TrayLog "显示托盘通知失败：$(Format-Exception -ErrorRecord $_)" 'warn'
    }
}

function Set-TrayPhase {
    param([string]$Phase)

    $script:phase = $Phase
    Update-TrayStatus
}

function Start-WebServer {
    if ($script:webProcess -and -not $script:webProcess.HasExited) {
        return
    }

    $script:webUrl = $null
    $script:webDisplayUrl = $null
    $script:webError = $null
    $script:restartAt = $null

    if (-not (Test-BindHostAvailable -Address $script:bindHost)) {
        $script:desiredRunning = $false
        $message = "本机当前没有地址 $($script:bindHost)，未启动 dsh web。"
        Write-TrayLog $message 'error'
        Set-TrayPhase 'host-missing'
        Show-TrayNotification -Title 'DSH Web 未启动' -Message $message -Icon Warning
        return
    }

    $owner = Get-PortOwner -ListenPort $script:port
    if ($owner) {
        # 端口上的若是本宿主上次遗留的 dsh web，先清掉再启动；外部实例一律不动。
        $record = Read-WebPidRecord
        if ($record -and $record.ProcessId -eq $owner.ProcessId) {
            Write-TrayLog "端口 $($script:port) 上是上次遗留的 dsh web（PID $($owner.ProcessId)），清理后重启。"
            Stop-ProcessTree -RootProcessId $owner.ProcessId
            Clear-WebPidRecord
            $null = Wait-PortReleased -ListenPort $script:port
            $owner = Get-PortOwner -ListenPort $script:port
        }
    }
    if ($owner) {
        $script:desiredRunning = $false
        $message = "端口 $($script:port) 已被 $($owner.Name) (PID $($owner.ProcessId)) 占用，未启动 dsh web。"
        Write-TrayLog $message 'error'
        Set-TrayPhase 'port-conflict'
        Show-TrayNotification -Title 'DSH Web 未启动' -Message $message -Icon Warning
        return
    }

    $script:activeWebLogPath = Resolve-WebLogPath
    Rotate-Log -Path $script:activeWebLogPath
    $script:webLogOffset = if (Test-Path -LiteralPath $script:activeWebLogPath) {
        (Get-Item -LiteralPath $script:activeWebLogPath).Length
    } else {
        0
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { 'cmd.exe' } else { $env:ComSpec }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $scriptRoot
    # cmd 的 /s /c 需要整条命令包在双引号里；.ArgumentList 会破坏这层引号，因此用原始字符串。
    $startInfo.Arguments = '/d /s /c ""' + $script:dshPath + '" --profile web --host ' + $script:bindHost +
        ' --port ' + $script:port + ' --no-open >> "' + $script:activeWebLogPath + '" 2>&1"'

    # Job 必须在进程创建前就绪，否则 cmd 可能已派生 node，子进程就逃出了 Job。
    Initialize-WebJob

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'dsh web 子进程启动失败。'
    }
    if (-not [DshWebTrayJob]::Assign($script:webJobHandle, $process.Handle)) {
        Write-TrayLog "dsh web 未能加入托管 Job（Win32 $([DshWebTrayJob]::LastError())），将依赖下次启动时的残留清理。" 'warn'
    }

    [ordered]@{
        managerPid = $PID
        processId  = $process.Id
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $webPidPath -Encoding utf8

    $script:webProcess = $process
    $script:startedAt = Get-Date
    Write-TrayLog "启动 dsh web（PID $($process.Id)）：dsh --profile web --host $($script:bindHost) --port $($script:port) --no-open"
    Set-TrayPhase 'starting'
}

function Wait-PortReleased {
    param(
        [int]$ListenPort,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-PortOwner -ListenPort $ListenPort)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return -not [bool](Get-PortOwner -ListenPort $ListenPort)
}
function Stop-WebServer {
    $script:desiredRunning = $false
    $script:restartAt = $null

    if ($script:webProcess) {
        $processId = $script:webProcess.Id
        if (-not $script:webProcess.HasExited) {
            Write-TrayLog "停止 dsh web 进程树（PID $processId）"
            Stop-ProcessTree -RootProcessId $processId
        }
        try {
            $script:webProcess.Dispose()
        } catch {
            # 进程对象已失效时忽略。
        }
        $script:webProcess = $null
        if (-not (Wait-PortReleased -ListenPort $script:port)) {
            Write-TrayLog "停止后端口 $($script:port) 仍被占用。" 'warn'
        }
    }
    Clear-WebPidRecord

    $script:webUrl = $null
    $script:webDisplayUrl = $null
    Set-TrayPhase 'stopped'
}

function Complete-WebExit {
    $exitCode = 'unknown'
    try {
        $exitCode = $script:webProcess.ExitCode
    } catch {
        # 进程对象已释放时保持 unknown。
    }
    $uptime = if ($script:startedAt) { (Get-Date) - $script:startedAt } else { [TimeSpan]::Zero }

    try {
        $script:webProcess.Dispose()
    } catch {
        # 忽略重复释放。
    }
    $script:webProcess = $null
    $script:webUrl = $null
    $script:webDisplayUrl = $null
    Clear-WebPidRecord

    Write-TrayLog "dsh web 已退出，exitCode=$exitCode，运行 $([Math]::Round($uptime.TotalSeconds, 1))s" 'warn'
    if ($script:webError) {
        Write-TrayLog "最近错误输出：$($script:webError)" 'error'
    }

    if (-not $script:desiredRunning) {
        Set-TrayPhase 'stopped'
        return
    }

    # 重启后 token 会变，旧窗口里的页面已经失效；用户自己关掉窗口则不重开。
    if (@(Get-TrayEdgeWindows).Count -gt 0) {
        Close-TrayEdgeWindows
        $script:pendingWindowOpen = $true
    }

    if ($uptime.TotalSeconds -ge 60) {
        $script:consecutiveFailures = 0
    }
    $script:consecutiveFailures++

    if ($script:consecutiveFailures -gt 5) {
        $script:desiredRunning = $false
        Write-TrayLog '连续启动失败，已停止自动重启。请查看日志后手动启动。' 'error'
        Set-TrayPhase 'failed'
        Show-TrayNotification -Title 'DSH Web 启动失败' -Message '连续启动失败，已停止自动重启，详情见日志。' -Icon Error
        return
    }

    $delay = $restartDelays[[Math]::Min($script:consecutiveFailures - 1, $restartDelays.Count - 1)]
    $script:restartAt = (Get-Date).AddSeconds($delay)
    Write-TrayLog "将在 ${delay}s 后重启 dsh web（连续失败 $($script:consecutiveFailures) 次）"
    Set-TrayPhase 'waiting'
}

function Update-WebStartup {
    $text = Read-WebLogTail
    if ([string]::IsNullOrEmpty($text)) {
        return
    }

    foreach ($rawLine in ($text -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0) {
            continue
        }

        if ($line -match '^dsh web: (https?://\S+)$') {
            $script:webUrl = $Matches[1]
            try {
                $uri = [System.Uri]::new($script:webUrl)
                $script:webDisplayUrl = "$($uri.Scheme)://$($uri.Authority)"
            } catch {
                $script:webDisplayUrl = $null
            }
            $script:webError = $null
            Write-TrayLog "dsh web 已就绪：$($script:webDisplayUrl)"
            Set-TrayPhase 'ready'
            continue
        }

        if ($line -match '(?i)\b(error|failed|EADDRINUSE|EACCES|ENOENT)\b') {
            $script:webError = if ($line.Length -gt 200) { $line.Substring(0, 200) } else { $line }
        }
    }
}

# ---------------------------------------------------------------------------
# 托盘状态与操作
# ---------------------------------------------------------------------------

function Update-TrayStatus {
    if (-not $script:notifyIcon -or -not $script:statusItem) {
        return
    }

    $running = [bool]($script:webProcess -and -not $script:webProcess.HasExited)

    $status = switch ($script:phase) {
        'starting' { '启动中…' }
        'ready' { if ($running) { "运行中 (PID $($script:webProcess.Id))" } else { '运行中' } }
        'waiting' { '等待重启…' }
        'port-conflict' { "端口 $($script:port) 被占用" }
        'host-missing' { "缺少本机地址 $($script:bindHost)" }
        'failed' { '启动失败' }
        'stopped' { '已停止' }
        default { [string]$script:phase }
    }

    $script:statusItem.Text = "状态：$status"
    $script:addressItem.Text = if ($script:webDisplayUrl) { "地址：$($script:webDisplayUrl)" } else { '地址：未就绪' }

    $tooltip = "DSH Web · $status"
    if ($script:webDisplayUrl) {
        $tooltip += " · $($script:webDisplayUrl)"
    }
    $script:notifyIcon.Text = if ($tooltip.Length -gt 63) { $tooltip.Substring(0, 63) } else { $tooltip }

    $script:startItem.Enabled = -not $running
    $script:stopItem.Enabled = $running
}

function Restart-WebServer {
    Close-TrayEdgeWindows
    Stop-WebServer
    $script:desiredRunning = $true
    $script:pendingWindowOpen = $true
    Start-WebServer
}

function Open-LogDirectory {
    Start-Process -FilePath 'explorer.exe' -ArgumentList @($dataDir) | Out-Null
}

# ---------------------------------------------------------------------------
# 开机自启动
# ---------------------------------------------------------------------------

function Test-AutoStartEnabled {
    return Test-Path -LiteralPath $startupShortcutPath -PathType Leaf
}

function Enable-AutoStart {
    $startupDirectory = Split-Path -Parent $startupShortcutPath
    if (-not (Test-Path -LiteralPath $startupDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $startupDirectory -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($startupShortcutPath)
        $shortcut.TargetPath = $script:autoStartExePath
        $autoStartArguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        if ($script:startupNoWindow) {
            $autoStartArguments += ' -NoWindow'
        }
        $shortcut.Arguments = $autoStartArguments
        $shortcut.WorkingDirectory = $scriptRoot
        $shortcut.IconLocation = "$iconPath,0"
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'DSH Web 托盘宿主'
        $shortcut.Save()
    } finally {
        if ($shortcut) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($shell) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Disable-AutoStart {
    Remove-Item -LiteralPath $startupShortcutPath -Force -ErrorAction SilentlyContinue
}

function Update-AutoStartMenuState {
    if ($script:autoStartItem) {
        $script:autoStartItem.Checked = Test-AutoStartEnabled
        $script:autoStartItem.ToolTipText = $startupShortcutPath
    }
}

# ---------------------------------------------------------------------------
# 启动请求与主循环
# ---------------------------------------------------------------------------

function Read-LaunchRequest {
    if (-not (Test-Path -LiteralPath $requestPath)) {
        return $null
    }

    $text = $null
    try {
        $text = Get-Content -LiteralPath $requestPath -Raw -ErrorAction Stop
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        Write-TrayLog "启动请求内容无效：$($_.Exception.Message)" 'warn'
        return $null
    }
}

function Invoke-LaunchRequest {
    param([object]$Request)

    $showWindow = $true
    if ($Request.PSObject.Properties['showWindow']) { $showWindow = [bool]$Request.showWindow }

    $requestHost = if ($Request.PSObject.Properties['bindHost'] -and $Request.bindHost) { [string]$Request.bindHost } else { $script:bindHost }
    $requestPort = if ($Request.PSObject.Properties['port'] -and $Request.port) { [int]$Request.port } else { $script:port }
    $requestLeft = if ($Request.PSObject.Properties['left']) { [int]$Request.left } else { $script:windowLeft }
    $requestTop = if ($Request.PSObject.Properties['top']) { [int]$Request.top } else { $script:windowTop }
    $requestWidth = if ($Request.PSObject.Properties['width'] -and $Request.width) { [int]$Request.width } else { $script:windowWidth }
    $requestHeight = if ($Request.PSObject.Properties['height'] -and $Request.height) { [int]$Request.height } else { $script:windowHeight }

    $hostChanged = $requestHost -ne $script:bindHost
    $portChanged = $requestPort -ne $script:port
    $geometryChanged = ($requestLeft -ne $script:windowLeft) -or ($requestTop -ne $script:windowTop) -or
        ($requestWidth -ne $script:windowWidth) -or ($requestHeight -ne $script:windowHeight)

    if ($hostChanged -or $portChanged) {
        $script:bindHost = $requestHost
        $script:port = $requestPort
        $script:windowLeft = $requestLeft
        $script:windowTop = $requestTop
        $script:windowWidth = $requestWidth
        $script:windowHeight = $requestHeight
        Write-TrayLog "收到新的启动参数：--host $($script:bindHost) --port $($script:port)，重启服务。"
        Close-TrayEdgeWindows
        Stop-WebServer
        $script:desiredRunning = $true
        $script:pendingWindowOpen = $showWindow
        Start-WebServer
        return
    }

    if ($geometryChanged) {
        $script:windowLeft = $requestLeft
        $script:windowTop = $requestTop
        $script:windowWidth = $requestWidth
        $script:windowHeight = $requestHeight
        Write-TrayLog "窗口几何更新为 $($script:windowLeft),$($script:windowTop) $($script:windowWidth)x$($script:windowHeight)。"
        Close-TrayEdgeWindows
    }

    if ($showWindow) {
        Show-WebWindow
    }
}

function Invoke-TrayTick {
    $request = Read-LaunchRequest
    if ($request) {
        Invoke-LaunchRequest -Request $request
    }

    if ($script:webProcess -and $script:webProcess.HasExited) {
        Complete-WebExit
    }

    if ($script:phase -eq 'starting') {
        Update-WebStartup

        if ($script:webProcess -and -not $script:webProcess.HasExited -and $script:startedAt -and
            ((Get-Date) - $script:startedAt).TotalSeconds -ge $startupTimeoutSeconds) {
            Write-TrayLog "dsh web 在 ${startupTimeoutSeconds}s 内未打印就绪地址，强制结束并重试。" 'error'
            Stop-ProcessTree -RootProcessId $script:webProcess.Id
        }
    }

    if ($script:phase -eq 'ready' -and $script:pendingWindowOpen) {
        $script:pendingWindowOpen = $false
        Show-WebWindow
    }

    if ($script:desiredRunning -and -not $script:webProcess -and $script:phase -eq 'waiting' -and
        $script:restartAt -and (Get-Date) -ge $script:restartAt) {
        $script:restartAt = $null
        try {
            Start-WebServer
        } catch {
            Write-TrayLog "重启 dsh web 失败：$(Format-Exception -ErrorRecord $_)" 'error'
            $script:restartAt = (Get-Date).AddSeconds(30)
        }
    }

    Update-TrayStatus
}

function Exit-Tray {
    $script:exitRequested = $true
    Close-TrayEdgeWindows
    Stop-WebServer
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
        $script:notifyIcon = $null
    }
    if ($script:trayIcon) {
        $script:trayIcon.Dispose()
        $script:trayIcon = $null
    }
}

# ---------------------------------------------------------------------------
# 宿主
# ---------------------------------------------------------------------------

function Invoke-Manager {
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-TrayLog '已有托盘宿主实例在运行，本次启动忽略。' 'warn'
        return
    }

    Set-Content -LiteralPath $pidPath -Value $PID -Encoding ascii

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ($PSVersionTable.PSEdition -eq 'Core') {
        try {
            [void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2)
        } catch {
            # 旧运行时不支持时使用默认 DPI 模式。
        }
    }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:windowInteropLoaded = $false
    $script:webProcess = $null
    $script:desiredRunning = $true
    $script:exitRequested = $false
    $script:phase = 'stopped'
    $script:webUrl = $null
    $script:webDisplayUrl = $null
    $script:webError = $null
    $script:webLogOffset = 0
    $script:restartAt = $null
    $script:startedAt = $null
    $script:consecutiveFailures = 0
    $script:pendingWindowOpen = $false
    $script:startupNoWindow = [bool]$NoWindow
    $script:notifyIcon = $null
    $script:trayIcon = $null
    $script:statusItem = $null
    $script:addressItem = $null
    $script:startItem = $null
    $script:stopItem = $null
    $script:autoStartItem = $null

    try {
        $config = Get-EffectiveConfig
        $script:bindHost = $config.BindHost
        $script:port = $config.Port
        $script:windowLeft = $config.Left
        $script:windowTop = $config.Top
        $script:windowWidth = $config.Width
        $script:windowHeight = $config.Height
        $script:pendingWindowOpen = $config.OpenWindow

        $script:dshPath = Resolve-DshCommand
        Remove-OrphanWebServer

        if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
            throw "托盘图标不存在：$iconPath"
        }

        $script:trayIcon = [System.Drawing.Icon]::new($iconPath)
        $script:notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
        $script:notifyIcon.Icon = $script:trayIcon
        $script:notifyIcon.Visible = $true

        $script:notifyIcon.add_MouseClick({
                param($sender, $eventArgs)
                if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
                    return
                }
                try {
                    Show-WebWindow
                } catch {
                    Write-TrayLog "左键打开 Web 界面失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })

        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        $script:statusItem = [System.Windows.Forms.ToolStripMenuItem]::new('状态：启动中')
        $script:statusItem.Enabled = $false
        $script:addressItem = [System.Windows.Forms.ToolStripMenuItem]::new('地址：未就绪')
        $script:addressItem.Enabled = $false
        $openItem = [System.Windows.Forms.ToolStripMenuItem]::new('打开 Web 界面')
        $copyItem = [System.Windows.Forms.ToolStripMenuItem]::new('复制访问链接')
        $script:startItem = [System.Windows.Forms.ToolStripMenuItem]::new('启动服务')
        $script:stopItem = [System.Windows.Forms.ToolStripMenuItem]::new('停止服务')
        $restartItem = [System.Windows.Forms.ToolStripMenuItem]::new('重启服务')
        $script:autoStartItem = [System.Windows.Forms.ToolStripMenuItem]::new('开机自启动')
        $script:autoStartItem.CheckOnClick = $false
        $openLogItem = [System.Windows.Forms.ToolStripMenuItem]::new('打开数据目录')
        $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('退出托盘')

        $openItem.add_Click({
                try {
                    Show-WebWindow
                } catch {
                    Write-TrayLog "打开 Web 界面失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $copyItem.add_Click({
                try {
                    if ($script:webUrl) {
                        Set-Clipboard -Value $script:webUrl
                        Write-TrayLog '已复制带 token 的访问链接到剪贴板。'
                    } else {
                        Show-TrayNotification -Title 'DSH Web 尚未就绪' -Message '服务就绪后才能复制访问链接。' -Icon Warning
                    }
                } catch {
                    Write-TrayLog "复制访问链接失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $script:startItem.add_Click({
                try {
                    $script:desiredRunning = $true
                    $script:pendingWindowOpen = $true
                    Start-WebServer
                } catch {
                    Write-TrayLog "启动服务失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $script:stopItem.add_Click({
                try {
                    Close-TrayEdgeWindows
                    Stop-WebServer
                } catch {
                    Write-TrayLog "停止服务失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $restartItem.add_Click({
                try {
                    Restart-WebServer
                } catch {
                    Write-TrayLog "重启服务失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $script:autoStartItem.add_Click({
                try {
                    if (Test-AutoStartEnabled) {
                        Disable-AutoStart
                        Write-TrayLog "已关闭开机自启动：$startupShortcutPath"
                    } else {
                        Enable-AutoStart
                        Write-TrayLog "已开启开机自启动：$startupShortcutPath"
                    }
                    Update-AutoStartMenuState
                } catch {
                    Write-TrayLog "设置开机自启动失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $openLogItem.add_Click({
                try {
                    Open-LogDirectory
                } catch {
                    Write-TrayLog "打开数据目录失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $exitItem.add_Click({
                try {
                    Exit-Tray
                } catch {
                    Write-TrayLog "退出托盘失败：$(Format-Exception -ErrorRecord $_)" 'error'
                }
            })
        $menu.add_Opening({
                Update-AutoStartMenuState
            })

        [void]$menu.Items.Add($script:statusItem)
        [void]$menu.Items.Add($script:addressItem)
        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
        [void]$menu.Items.Add($openItem)
        [void]$menu.Items.Add($copyItem)
        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
        [void]$menu.Items.Add($script:startItem)
        [void]$menu.Items.Add($script:stopItem)
        [void]$menu.Items.Add($restartItem)
        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
        [void]$menu.Items.Add($script:autoStartItem)
        [void]$menu.Items.Add($openLogItem)
        [void]$menu.Items.Add($exitItem)
        $script:notifyIcon.ContextMenuStrip = $menu
        Update-AutoStartMenuState

        Write-TrayLog "托盘宿主启动：PID $PID，dsh=$($script:dshPath)，目标 $($script:bindHost):$($script:port)"
        try {
            Start-WebServer
        } catch {
            $script:desiredRunning = $false
            Write-TrayLog "启动服务失败：$(Format-Exception -ErrorRecord $_)" 'error'
            Set-TrayPhase 'failed'
            Show-TrayNotification -Title 'DSH Web 启动失败' -Message (Format-Exception -ErrorRecord $_) -Icon Error
        }

        while (-not $script:exitRequested) {
            [System.Windows.Forms.Application]::DoEvents()
            try {
                Invoke-TrayTick
            } catch {
                Write-TrayLog "托盘轮询失败：$(Format-Exception -ErrorRecord $_)" 'error'
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        try {
            Stop-WebServer
        } catch {
            Write-TrayLog "退出时停止服务失败：$(Format-Exception -ErrorRecord $_)" 'warn'
        }
        try {
            Close-WebJob
        } catch {
            Write-TrayLog "关闭托管 Job 失败：$(Format-Exception -ErrorRecord $_)" 'warn'
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        if ($script:notifyIcon) {
            $script:notifyIcon.Visible = $false
            $script:notifyIcon.Dispose()
            $script:notifyIcon = $null
        }
        if ($script:trayIcon) {
            $script:trayIcon.Dispose()
            $script:trayIcon = $null
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# ---------------------------------------------------------------------------
# 启动器
# ---------------------------------------------------------------------------

function Test-ManagerAlive {
    param([int]$ProcessId)

    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if (-not $process) {
            return $false
        }
        $commandLine = [string]$process.CommandLine
        return $commandLine.IndexOf('dsh-web-tray.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $commandLine.IndexOf('-Manager', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    } catch {
        return $false
    }
}

function Invoke-Launcher {
    $config = Get-EffectiveConfig
    $null = Resolve-DshCommand

    $existingId = 0
    if (Test-Path -LiteralPath $pidPath) {
        $pidText = (Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue).Trim()
        if ([int]::TryParse($pidText, [ref]$existingId) -and (Test-ManagerAlive -ProcessId $existingId)) {
            [ordered]@{
                bindHost   = $config.BindHost
                port       = $config.Port
                left       = $config.Left
                top        = $config.Top
                width      = $config.Width
                height     = $config.Height
                showWindow = $config.OpenWindow
            } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -Encoding utf8
            Write-Host "DSH Web 托盘已在运行（PID $existingId），已发送请求。数据目录：$dataDir"
            return
        }
    }

    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-Sta',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$scriptPath`"",
        '-Manager'
    )
    # 宿主自己会再读一遍配置，这里只透传显式给出的覆盖参数。
    if ($BindHost) {
        $arguments += @('-BindHost', $config.BindHost)
    }
    if ($null -ne $Port) {
        $arguments += @('-Port', ([string]$config.Port))
    }
    if ($null -ne $WindowLeft) {
        $arguments += @('-WindowLeft', ([string]$config.Left))
    }
    if ($null -ne $WindowTop) {
        $arguments += @('-WindowTop', ([string]$config.Top))
    }
    if ($null -ne $WindowWidth) {
        $arguments += @('-WindowWidth', ([string]$config.Width))
    }
    if ($null -ne $WindowHeight) {
        $arguments += @('-WindowHeight', ([string]$config.Height))
    }
    if ($NoWindow) {
        $arguments += '-NoWindow'
    }
    if ($DataRoot) {
        $arguments += @('-DataRoot', $dataDir)
    }

    Start-Process -FilePath $script:hostExePath -ArgumentList $arguments -WorkingDirectory $scriptRoot -WindowStyle Hidden | Out-Null
    Write-Host "DSH Web 托盘已启动，托管 $($config.BindHost):$($config.Port)，数据目录：$dataDir"
}

Initialize-DataRoot

if ($Manager) {
    Invoke-Manager
} else {
    Invoke-Launcher
}
