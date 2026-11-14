# dsh-web-tray

零依赖的 Windows PowerShell 托盘工具：后台托管 `dsh --profile web`，并用 Microsoft Edge `--app` 窗口承载 Web 界面。

![托盘菜单](assets/demo.png)

## 为什么不用官方桌面版

DeepSeek Harness 官方桌面版基于 Electron，内存与进程开销大，且仅限本机访问。直接托管 `dsh --profile web` 并复用系统自带的 Edge App 窗口，既省去独立 Electron 开销，又能绑定局域网 IP 供其他设备直接访问。

## 环境要求

- Windows 10 / 11（自带 Windows PowerShell 5.1 与 Microsoft Edge）
- `dsh` 已加入系统 `PATH`（`npm install -g @deepseek-ai/dsh`）

## 安装

使用 winget 安装：

```powershell
winget install Juexe.DshWebTray
```

或从 [GitHub Releases](https://github.com/juexe/dsh-web-tray/releases) 下载 `dsh-web-tray-<版本>-setup.exe` 安装。程序安装在 `%LOCALAPPDATA%\Programs\dsh-web-tray`，无需管理员权限。

安装后从开始菜单启动。若启动时 `PATH` 中尚未安装 `dsh`，托盘会保持运行并提示，安装后在右键菜单点击「启动服务」即可。卸载时会先停止托盘再移除程序文件，`data/` 目录中的配置、日志与浏览器数据会保留。

## 从源码运行

双击 `dsh-web-tray.cmd` 或在终端运行 `.\dsh-web-tray.cmd`。

首次运行会在 `data/config.json` 生成默认配置，修改后重启托盘生效：

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

- `bindHost`：监听地址。局域网访问请改为本机局域网 IP（如 `192.168.x.x`）。
- `port`：监听端口（被外部进程占用时直接报错，不强杀外部进程）。
- `openWindow`：启动托盘时是否自动弹出窗口。
- `window`：Edge 窗口位置与尺寸（DIP 坐标）。

命令行参数可单次覆盖配置或停止托盘：

```powershell
.\dsh-web-tray.cmd -BindHost 192.168.3.10 -Port 8310
.\dsh-web-tray.cmd -NoWindow
.\dsh-web-tray.cmd -Stop
```

## 托盘操作

- **左键单击**：打开或聚焦 Web 窗口（使用 `data/edge-profile` 独立配置并开启 `--disable-sync`，不污染日常浏览器）。
- **右键菜单**：打开 Web 界面、复制带 token 的访问链接、启动/停止/重启服务、开机自启动、打开数据目录、退出托盘。

## 开发与测试

构建安装包（需 Inno Setup 6，版本号读取自 `VERSION`）：

```powershell
winget install JRSoftware.InnoSetup
.\packaging\build.ps1
```

产物与 SHA256 校验文件输出到 `dist/`，winget 清单与发布流程见 [`packaging/README.md`](packaging/README.md)。

运行冒烟测试：

```powershell
powershell -NoProfile -File tests/smoke.ps1
```

## License

[MIT](LICENSE)
