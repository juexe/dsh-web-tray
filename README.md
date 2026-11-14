# dsh-web-tray

一个非常简单的 Windows PowerShell 脚本，零依赖、运行无负担：在系统托盘后台托管 `dsh --profile web`，并用 Microsoft Edge `--app` 窗口承载 Web 界面。

![托盘菜单](assets/demo.png)

## 为什么不用官方桌面版

DeepSeek Harness 官方桌面版基于 Electron，内存与进程开销大，且只能本机使用、无法局域网访问。直接托管 `dsh --profile web` 并复用系统自带的 Edge App 窗口，既省去独立 Electron 开销，又能绑定局域网 IP 供其他设备直接访问。

## 环境要求

- Windows 10 / 11（自带 Windows PowerShell 5.1 与 Microsoft Edge）
- `dsh` 已加入系统 `PATH`

## 快速开始

直接双击 `dsh-web-tray.cmd` 即可启动（或在终端运行 `.\dsh-web-tray.cmd`）。

首次运行会自动生成 `data/config.json`，修改后重启托盘生效：

```json
{
  "bindHost": "127.0.0.1",
  "port": 8310,
  "openWindow": true,
  "window": {
    "left": 50,
    "top": 0,
    "width": 1813,
    "height": 1158
  }
}
```

- `bindHost`：监听地址。如需局域网访问，改为本机局域网 IP（如 `192.168.x.x`）。
- `port`：监听端口（被外部进程占用时直接报错，不强杀外部进程）。
- `openWindow`：启动托盘时是否自动弹出窗口。
- `window`：Edge 窗口位置与尺寸（DIP 坐标）。

也支持通过命令行参数临时覆盖单次启动：

```powershell
.\dsh-web-tray.cmd -BindHost 192.168.3.10 -Port 8310
.\dsh-web-tray.cmd -NoWindow
```

## 托盘操作

- **左键单击托盘图标**：打开或聚焦 Web 窗口（使用 `data/edge-profile` 独立配置并开启 `--disable-sync`，不污染日常浏览器）。
- **右键菜单**：打开 Web 界面、复制带 token 的访问链接、启动/停止/重启服务、开机自启动、打开数据目录、退出托盘。

## 测试

```powershell
powershell -NoProfile -File tests/smoke.ps1
```
