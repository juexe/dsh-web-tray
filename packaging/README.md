# winget 清单

清单对应 `VERSION` 中的版本，发布 GitHub Release 后提交到 `microsoft/winget-pkgs` 的 `manifests/j/Juexe/DshWebTray/<version>/`。

## 校验

```powershell
winget validate --manifest packaging/winget --disable-interactivity
winget install --manifest packaging/winget --accept-package-agreements --accept-source-agreements
```

## 发布新版本

1. 修改根目录 `VERSION`。
2. 更新 `packaging/winget/` 中的 `PackageVersion`、`InstallerUrl`、`InstallerSha256`、`ReleaseDate` 与 `AppsAndFeaturesEntries`。
3. 运行 `.\packaging\build.ps1` 重新构建并生成哈希。
4. 创建 `v<version>` GitHub Release，上传 `dist/dsh-web-tray-<version>-setup.exe`。
5. 校验清单后提交：

```powershell
wingetcreate submit --prtitle "Add Juexe.DshWebTray <version>" packaging/winget
```
