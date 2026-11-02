# DSH 一键急救（dsh-first-aid）

DSH 起不来、闪退、弹「应用无法启动或已意外停止」、聊天一直报 502 的时候，双击 `一键急救.cmd` 就行。

**不依赖 DSH、不依赖 node、不联网也能跑**——它本身只是一段 PowerShell 脚本，DSH 死透了也能用。

## 怎么用

| 场景 | 操作 |
|---|---|
| DSH 活着，只想体检 | 右键 `rescue.ps1` → 用 PowerShell 运行，或命令行 `rescue.ps1 -Check` |
| DSH 死了 / 闪退 | **双击 `一键急救.cmd`**（自动要管理员权限 → 体检 → 修 → 重启 DSH） |
| 只想修不想重启 | `rescue.ps1 -Fix -NoLaunch` |
| 连会丢数据的项也要修 | `rescue.ps1 -Fix -Force` |

日志写在 `%TEMP%\dsh-first-aid-<时间>.log`。窗口关了也能翻。

## 它检查什么（按上次真实崩溃排的）

| # | 检查项 | 对应真实故障 |
|---|---|---|
| 0 | 进程与实例（多个窗口=插件跑旧代码） | 机器上挂两批 DSH，改插件不生效 |
| 1 | 升级器残留 `pending/`、`installer.exe`、`.blockmap` | 每次退出弹「应用更新后优雅关闭报错」 |
| 2 | PATH 里有没有 node | 插件 spawn 退回 `ELECTRON_RUN_AS_NODE` → 子进程一退就 EPIPE 秒崩 |
| 3 | 崩溃日志归类（EPIPE / 4294967295 / no-response / 缺模块） | 判断这次崩在哪一类 |
| 4 | profile `package.json` 能否解析、bundles 与 dependencies 是否对得上、link 目录是否存在 | 手改 profile 写坏 → app 起不来；会自动用 `.bak` 恢复 |
| 5 | 插件 spawn 有没有挂 `error` 监听 | EPIPE 的病根；只报告不擅自改代码 |
| 6 | DNS 解析耗时 + VPN 网卡跃点 | **502 的真凶**：Radmin VPN 跃点=1，解析固定 11–12 秒；需要管理员改成 9999 |
| 7 | 内置 python 的 soundcard / av / faster_whisper | 升级会整套替换 runtime，site-packages 全丢 |
| 8 | 磁盘余量与存储目录可写 | 写不进会话 |
| 9 | 温柔关（WM_CLOSE 等 25 秒）→ 再启动 → 等窗口 | 一上来就 Kill 会再触发一次「优雅关闭报错」 |

## 设计约定

- **只自动改确定安全的**：清升级器残留、修 PATH、补 python 依赖、改 VPN 跃点、重启。
- **会丢数据的先问**：归档坏 profile、清会话缓存要 `-Force`。
- **不擅自改别人的插件代码**：EPIPE 只报告路径，改不改人来看。
- 全程有中文日志，失败也告诉你下一步该敲什么命令。

## 已知边界

- 改 Radmin VPN 跃点必须管理员；没管理员权限时只提示命令，不动手。
- 检查 5 是静态扫源码（找 `spawn(` 且无 `.on('error'`），正则判断，会有少量误报。
- 只在 Windows 上用（这台机器的 DSH 是 Electron 桌面版）。

## 文件

```
dsh-first-aid\
  一键急救.cmd     ← 双击入口，自动提权
  rescue.ps1       ← 全部逻辑，可单独 -Check 体检
  README.md
```
