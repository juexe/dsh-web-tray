#Requires -Version 5.1
<#
.SYNOPSIS
    构建 dsh-web-tray 的 Inno Setup 安装包。

.DESCRIPTION
    版本号默认读取仓库根目录的 VERSION 文件，安装包输出到 dist/。
    构建机需要安装 Inno Setup 6（winget install JRSoftware.InnoSetup）。

.EXAMPLE
    .\packaging\build.ps1

.EXAMPLE
    .\packaging\build.ps1 -Version 1.0.1 -OutputDir D:\release
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$issPath = Join-Path $repoRoot 'packaging/dsh-web-tray.iss'

if (-not $Version) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+([.-][0-9A-Za-z.-]+)?$') {
    throw "版本号格式不正确：$Version"
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot 'dist'
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $repoRoot $OutputDir
}

$isccCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)
$iscc = $isccCandidates |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -First 1
if (-not $iscc) {
    throw '未找到 Inno Setup 6 的 ISCC.exe，请先安装：winget install --id JRSoftware.InnoSetup --exact --source winget'
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
& $iscc "/DMyAppVersion=$Version" "/DMyOutputDir=$OutputDir" $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup 编译失败（退出码 $LASTEXITCODE）。"
}

$installerPath = Join-Path $OutputDir "dsh-web-tray-$Version-setup.exe"
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "安装包未生成：$installerPath"
}

$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
$hashPath = "$installerPath.sha256"
"$hash  $(Split-Path -Leaf $installerPath)" | Set-Content -LiteralPath $hashPath -Encoding ascii

Write-Host "安装包：$installerPath"
Write-Host "SHA256：$hash"
Write-Host "校验文件：$hashPath"
