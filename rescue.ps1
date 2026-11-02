<#
  DSH 一键急救 / DeepSeek Harness First Aid
  纯 PowerShell，不依赖 DSH、不依赖 node、不联网也能跑。
  用法：
    .\rescue.ps1 -Check                只体检，不改任何东西
    .\rescue.ps1 -Fix                  体检 + 自动修复安全项 + 启动
    .\rescue.ps1 -Fix -Force           连会丢东西的修复也做（归档坏 profile、清会话缓存）
    .\rescue.ps1 -Fix -NoLaunch        修完不启动
#>
[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$Fix,
  [switch]$Force,
  [switch]$NoLaunch,
  [string]$LogPath
)

$ErrorActionPreference = 'Continue'
$script:Issues = New-Object System.Collections.ArrayList
$script:Fixes  = New-Object System.Collections.ArrayList

# ---------- 路径 ----------
$DSH_EXE      = 'E:\ds\DeepSeek Harness.exe'
$DSH_DIR      = 'E:\ds'
$NODE_DIR     = 'E:\ds\resources\runtime\primary-runtime\dependencies\node\bin'
$PY_DIR       = 'E:\ds\resources\runtime\primary-runtime\dependencies\python'
$PROFILE_DIR  = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$PROFILE_PKG  = Join-Path $PROFILE_DIR 'package.json'
$UPDATER_DIR  = Join-Path $env:LOCALAPPDATA '@deepseek-aidsh-desktop-updater'
$CRASH_DIR    = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
$STORAGE_DIR  = Join-Path $env:USERPROFILE '.dsh\storages'

if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ("dsh-first-aid-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }

# ---------- 输出 ----------
function Say($text, $color = 'Gray') {
  Write-Host $text -ForegroundColor $color
  Add-Content -Path $LogPath -Value $text -Encoding UTF8
}
function Head($text) {
  $line = ('=' * 62)
  Say ''
  Say $line 'DarkGray'
  Say ("  " + $text) 'Cyan'
  Say $line 'DarkGray'
}
function OK($m)   { Say ("  [ OK ] " + $m) 'Green' }
function WARN($m) { Say ("  [WARN] " + $m) 'Yellow'; [void]$script:Issues.Add($m) }
function BAD($m)  { Say ("  [FAIL] " + $m) 'Red';    [void]$script:Issues.Add($m) }
function DID($m)  { Say ("  [FIX ] " + $m) 'Magenta'; [void]$script:Fixes.Add($m) }
function Info($m) { Say ("         " + $m) 'DarkGray' }

Say ("DSH 一键急救   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'White'
Say ("日志：{0}" -f $LogPath) 'DarkGray'
if ($Check -and -not $Fix) { Say '模式：只体检（不改任何东西）' 'DarkGray' }
elseif ($Force)            { Say '模式：修复（包含会丢数据的项）' 'DarkGray' }
else                       { Say '模式：修复（只做安全项）' 'DarkGray' }

# ============================================================
# 0. 有没有跑着的实例
# ============================================================
Head '0. 进程与实例'
$procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
$withWin = @($procs | Where-Object { $_.MainWindowHandle -ne 0 })
Say ("  进程数 {0}，有窗口的 {1}" -f $procs.Count, $withWin.Count) 'Gray'
if ($procs.Count -eq 0) {
  WARN 'DSH 没在运行（急救完会拉起来）'
} elseif ($withWin.Count -eq 0) {
  WARN '有进程但一个窗口都没有：多半是 host 崩了留下僵尸'
} elseif ($withWin.Count -gt 1) {
  WARN ("开了 {0} 个窗口，可能是重复实例（插件会跑旧代码）" -f $withWin.Count)
} else {
  OK '单实例，窗口正常'
}
foreach ($p in $procs) {
  $age = (Get-Date) - $p.StartTime
  Info ("pid {0}  启动 {1}  已跑 {2:hh\:mm}" -f $p.Id, $p.StartTime.ToString('MM-dd HH:mm'), $age)
}

# ============================================================
# 1. 升级器残留（「应用更新后优雅关闭报错」的病根）
# ============================================================
Head '1. 升级器残留'
if (-not (Test-Path $UPDATER_DIR)) {
  OK '没有升级器缓存目录'
} else {
  $junk = @()
  $pending = Join-Path $UPDATER_DIR 'pending'
  if (Test-Path $pending) { $junk += Get-ChildItem -LiteralPath $pending -Recurse -ErrorAction SilentlyContinue }
  $junk += Get-ChildItem -LiteralPath $UPDATER_DIR -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'installer.*\.exe$|\.blockmap$|\.nsis\.7z$' }
  if ($junk.Count -eq 0) {
    OK '没有待安装的残留包'
  } else {
    $mb = [math]::Round((($junk | Measure-Object Length -Sum).Sum / 1MB), 1)
    WARN ("有 {0} 个待安装残留，共 {1} MB（会让退出时弹「优雅关闭报错」）" -f $junk.Count, $mb)
    if ($Fix) {
      foreach ($f in $junk) { try { Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction Stop } catch {} }
      if (Test-Path $pending) { try { Remove-Item -LiteralPath $pending -Recurse -Force -ErrorAction Stop } catch {} }
      DID '已清空升级器残留'
    }
  }
}

# ============================================================
# 2. PATH 里的 node（没有它插件 spawn 会退回 Electron → EPIPE 秒崩）
# ============================================================
Head '2. Node 运行时'
$nodeExe = Join-Path $NODE_DIR 'node.exe'
if (-not (Test-Path $nodeExe)) {
  BAD ("找不到内置 node：{0}" -f $nodeExe)
} else {
  $ver = (& $nodeExe --version) 2>$null
  OK ("内置 node {0}" -f $ver)
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -and ($userPath -split ';' -contains $NODE_DIR)) {
    OK 'node 已在用户 PATH 里'
  } else {
    WARN '用户 PATH 里没有 node（插件会退回 ELECTRON_RUN_AS_NODE，子进程一退就 EPIPE）'
    if ($Fix) {
      $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $NODE_DIR } else { $userPath.TrimEnd(';') + ';' + $NODE_DIR }
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      $env:Path = $env:Path.TrimEnd(';') + ';' + $NODE_DIR
      DID '已把 node 目录写进用户 PATH（新开的进程才生效）'
    }
  }
  $bc = [Environment]::GetEnvironmentVariable('BILLION_CONTEXT_NODE', 'User')
  if ($bc -eq $nodeExe) { OK 'BILLION_CONTEXT_NODE 已指向内置 node' }
  elseif ($Fix) {
    [Environment]::SetEnvironmentVariable('BILLION_CONTEXT_NODE', $nodeExe, 'User')
    $env:BILLION_CONTEXT_NODE = $nodeExe
    DID '已设置 BILLION_CONTEXT_NODE'
  } else {
    WARN 'BILLION_CONTEXT_NODE 没设（上下文插件会自己瞎找 node）'
  }
}

# ============================================================
# 3. 崩溃日志
# ============================================================
Head '3. 崩溃日志'
if (-not (Test-Path $CRASH_DIR)) {
  OK '没有崩溃日志目录'
} else {
  $logs = @(Get-ChildItem -LiteralPath $CRASH_DIR -Filter 'crash-*-host.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5)
  if ($logs.Count -eq 0) {
    OK '没有 crash 日志'
  } else {
    $newest = $logs[0]
    $ageH = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
    Info ("最近一条：{0}（{1} 小时前）" -f $newest.Name, $ageH)
    $body = Get-Content -LiteralPath $newest.FullName -Raw -ErrorAction SilentlyContinue
    $kinds = @()
    if ($body -match 'EPIPE')            { $kinds += 'EPIPE（子进程已死还往里写）' }
    if ($body -match '4294967295')       { $kinds += 'host exit 4294967295' }
    if ($body -match 'no-response')      { $kinds += '账号接口 no-response（网络/DNS）' }
    if ($body -match 'no usable Node')   { $kinds += '找不到 node' }
    if ($body -match 'Cannot find module') { $kinds += '插件缺依赖' }
    if ($body -match 'MODULE_NOT_FOUND') { $kinds += '插件缺依赖' }
    if ($kinds.Count -eq 0) { $kinds += '未识别' }
    if ($ageH -le 24) { WARN ("24 小时内崩过：" + ($kinds -join ' / ')) } else { Info ("历史崩溃：" + ($kinds -join ' / ')) }
    if ($body -match 'no-response|ETIMEDOUT|EAI_AGAIN') {
      WARN '日志里有网络超时：顺手查一下 DNS（见第 6 项）'
    }
  }
}

# ============================================================
# 4. profile 完整性（装插件的地方，最容易写坏）
# ============================================================
Head '4. profile 配置'
if (-not (Test-Path $PROFILE_PKG)) {
  BAD ("没有 profile：{0}" -f $PROFILE_PKG)
  Info 'DSH 首次启动会自动重建，急救时不用管'
} else {
  $raw = Get-Content -LiteralPath $PROFILE_PKG -Raw -Encoding UTF8
  $pkg = $null
  try {
    $pkg = $raw | ConvertFrom-Json -ErrorAction Stop
    OK 'package.json 语法正常'
  } catch {
    BAD 'package.json 解析失败（JSON 写坏了，app 会起不来）'
    if ($Fix) {
      $bak = Get-ChildItem -LiteralPath $PROFILE_DIR -Filter 'package.json.bak*' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($bak) {
        Copy-Item -LiteralPath $PROFILE_PKG -Destination ($PROFILE_PKG + '.broken-' + (Get-Date -Format 'HHmmss')) -Force
        Copy-Item -LiteralPath $bak.FullName -Destination $PROFILE_PKG -Force
        DID ("已用备份恢复：" + $bak.Name)
      } else {
        WARN '没有备份可恢复，只能手动改；可以先把它改名让它重建'
      }
    }
  }
  if ($pkg) {
    $bundles = @()
    if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) { $bundles = @($pkg.dsh.profile.bundles) }
    $deps = @()
    if ($pkg.dependencies) { $deps = @($pkg.dependencies.PSObject.Properties.Name) }
    Info ("启用插件 {0} 个：{1}" -f $bundles.Count, ($bundles -join ', '))
    # @deepseek-ai/* 是程序自带内部包，本来就不在 dependencies 里，别误报
    $missing = @($bundles | Where-Object { $deps -notcontains $_ -and $_ -notmatch '^@deepseek-ai/' })
    if ($missing.Count -gt 0) {
      WARN ("bundles 里有 {0} 个在 dependencies 里找不到：{1}" -f $missing.Count, ($missing -join ', '))
      Info '这会直接导致启动时 import 失败，急救按钮里可以把它从 bundles 去掉'
      if ($Fix) {
        Copy-Item -LiteralPath $PROFILE_PKG -Destination ($PROFILE_PKG + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
        $nodeList = @($pkg.dsh.profile.bundles) | Where-Object { $deps -contains $_ }
        $pkg.dsh.profile.bundles = @($nodeList)
        ($pkg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $PROFILE_PKG -Encoding UTF8
        DID ("已从 bundles 移除 {0}（备份留在同目录）" -f ($missing -join ', '))
      }
    } else {
      OK 'bundles 与 dependencies 对得上'
    }
    # 插件目录是否真存在
    $dead = @()
    foreach ($name in $deps) {
      $v = $pkg.dependencies.$name
      if ($v -is [string] -and $v.StartsWith('link:')) {
        $p = $v.Substring(5)
        if (-not (Test-Path $p)) { $dead += ("{0} -> {1}" -f $name, $p) }
      }
    }
    if ($dead.Count -gt 0) { WARN ("这些 link 插件目录不存在：" + ($dead -join '; ')) }
  }
}

# ============================================================
# 5. 插件子进程有没有挂 error 监听（EPIPE 的根因防护）
# ============================================================
Head '5. 插件 EPIPE 防护'
$pluginRoots = @()
if (Test-Path $PROFILE_PKG) {
  try {
    $p2 = (Get-Content -LiteralPath $PROFILE_PKG -Raw -Encoding UTF8) | ConvertFrom-Json
    if ($p2.dependencies) {
      foreach ($prop in $p2.dependencies.PSObject.Properties) {
        $v = $prop.Value
        if ($v -is [string] -and $v.StartsWith('link:')) { $pluginRoots += $v.Substring(5) }
      }
    }
  } catch {}
}
$pluginRoots += 'E:\dswork\plugins'
$pluginRoots = @($pluginRoots | Where-Object { Test-Path $_ } | Select-Object -Unique)
$spawnFiles = @()
foreach ($root in $pluginRoots) {
  $spawnFiles += Get-ChildItem -LiteralPath $root -Recurse -Filter '*.js' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\node_modules\\' -and $_.FullName -notmatch '\\dist\\' }
}
$spawnFiles = @($spawnFiles | Select-Object -Unique | Where-Object {
  $t = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
  $t -and ($t -match 'child_process') -and ($t -match 'spawn\(')
})
if ($spawnFiles.Count -eq 0) {
  OK '没发现自己 spawn 子进程的插件'
} else {
  $noGuard = @()
  foreach ($f in $spawnFiles) {
    $t = Get-Content -LiteralPath $f.FullName -Raw
    if ($t -notmatch "\.on\(\s*'error'") { $noGuard += $f.FullName }
  }
  if ($noGuard.Count -eq 0) {
    OK ("{0} 个 spawn 文件都挂了 error 监听" -f $spawnFiles.Count)
  } else {
    WARN ("{0} 个文件 spawn 子进程但没挂 error 监听（子进程一死就往里写 → EPIPE 崩 host）" -f $noGuard.Count)
    foreach ($f in $noGuard) { Info $f }
    if ($Fix -and $Force) {
      Copy-Item -LiteralPath $PROFILE_PKG -Destination ($PROFILE_PKG + '.bak-epipe-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
      DID '（需人工改代码，急救只做记录，未自动改插件）'
    }
  }
}

# ============================================================
# 6. 网络与 DNS（502 的真凶）
# ============================================================
Head '6. 网络与 DNS'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $null = [System.Net.Dns]::GetHostAddresses('api.deepseek.com') } catch {}
$sw.Stop()
$dnsMs = $sw.ElapsedMilliseconds
if ($dnsMs -lt 800) { OK ("解析 api.deepseek.com 用时 {0} ms" -f $dnsMs) }
else { WARN ("解析 api.deepseek.com 用了 {0} ms（超过 800ms 就会出现 502 / 请求超时）" -f $dnsMs) }

$vpn = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.InterfaceAlias -match 'Radmin|VPN|TAP|WireGuard' }
foreach ($v in $vpn) {
  Info ("网卡 {0}  跃点 {1}  状态 {2}" -f $v.InterfaceAlias, $v.InterfaceMetric, $v.ConnectionState)
  if ($v.InterfaceMetric -le 10) {
    WARN ("{0} 跃点只有 {1}，会把所有域名解析拖到 10 秒以上" -f $v.InterfaceAlias, $v.InterfaceMetric)
    if ($Fix) {
      try {
        Set-NetIPInterface -InterfaceAlias $v.InterfaceAlias -AddressFamily IPv4 -InterfaceMetric 9999 -ErrorAction Stop
        DID ("{0} 跃点已改成 9999" -f $v.InterfaceAlias)
      } catch {
        WARN ("改跃点需要管理员权限：{0}" -f $_.Exception.Message)
        Info ("手动跑：Set-NetIPInterface -InterfaceAlias '{0}' -AddressFamily IPv4 -InterfaceMetric 9999" -f $v.InterfaceAlias)
      }
    }
  }
}
$dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.ServerAddresses.Count -gt 0 } | Select-Object -First 1).ServerAddresses
if ($dnsServers) { Info ("系统 DNS：" + ($dnsServers -join ', ')) }

# ============================================================
# 7. 内置 python 的依赖（升级会整套替换，site-packages 全丢）
# ============================================================
Head '7. 内置 Python 依赖'
$pyExe = Join-Path $PY_DIR 'python.exe'
if (-not (Test-Path $pyExe)) {
  WARN '没找到内置 python'
} else {
  $probe = & $pyExe -c "import importlib;[print(n, 'ok' if importlib.util.find_spec(n) else 'missing') for n in ['soundcard','av','faster_whisper']]" 2>$null
  $missing = @()
  foreach ($line in ($probe -split "`n")) {
    if ($line -match '^(\S+)\s+missing') { $missing += $Matches[1] }
  }
  if ($missing.Count -eq 0) {
    OK 'soundcard / av / faster_whisper 都在'
  } else {
    WARN ("缺依赖：" + ($missing -join ', ') + '（多半是升级清空了 site-packages）')
    if ($Fix) {
      Info '正在重装（约 1-3 分钟，走本地缓存）'
      & $pyExe -m pip install --only-binary :all: --prefer-binary $missing 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Info $_ }
      $probe2 = & $pyExe -c "import importlib;[print(n, 'ok' if importlib.util.find_spec(n) else 'missing') for n in ['soundcard','av','faster_whisper']]" 2>$null
      if ($probe2 -match 'missing') { WARN '还有没装上的，需要手动 pip install' } else { DID '依赖已补回' }
    }
  }
}

# ============================================================
# 8. 磁盘与存储目录
# ============================================================
Head '8. 磁盘与存储'
try {
  $d = Get-PSDrive -Name ($STORAGE_DIR.Substring(0,1)) -ErrorAction Stop
  $freeGB = [math]::Round($d.Free / 1GB, 1)
  if ($freeGB -lt 3) { BAD ("{0} 盘只剩 {1} GB，DSH 可能写不进会话" -f $d.Name, $freeGB) }
  elseif ($freeGB -lt 8) { WARN ("{0} 盘剩 {1} GB，偏紧" -f $d.Name, $freeGB) }
  else { OK ("{0} 盘剩 {1} GB" -f $d.Name, $freeGB) }
} catch {}
if (Test-Path $STORAGE_DIR) {
  $t = Join-Path $STORAGE_DIR ('.write-test-' + [guid]::NewGuid().ToString('N').Substring(0,6))
  try { 'ok' | Set-Content -LiteralPath $t -Encoding UTF8; Remove-Item -LiteralPath $t -Force; OK '存储目录可写' }
  catch { BAD '存储目录写不进去（权限或磁盘满）' }
} else { BAD ("存储目录不存在：" + $STORAGE_DIR) }

# ============================================================
# 9. 收尾：重启 / 启动
# ============================================================
if ($Fix -and -not $NoLaunch) {
  Head '9. 重启 DSH'
  # 温柔关：先 WM_CLOSE，让 host 自己 teardown，避免再弹「优雅关闭报错」
  $procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
  if ($procs.Count -gt 0) {
    $main = $procs | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($main) { [void]$main.CloseMainWindow(); Info ("已请求关闭 pid {0}" -f $main.Id) }
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Seconds 1
      if (-not (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) { break }
    }
    $left = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
      WARN ("{0} 秒后还有 {1} 个进程没退，强制结束" -f 25, $left.Count)
      $left | ForEach-Object { try { $_.Kill() } catch {} }
      Start-Sleep -Seconds 4
    } else { OK '已干净退出' }
  }
  if (Test-Path $nodeExe) {
    if (-not (($env:Path -split ';') -contains $NODE_DIR)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $NODE_DIR }
  }
  if (Test-Path $DSH_EXE) {
    Start-Process -FilePath $DSH_EXE -WorkingDirectory $DSH_DIR
    Info '已启动，等它起来…'
    $up = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 1
      $p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowHandle -ne 0 }
      if ($p) { $up = $true; break }
    }
    if ($up) {
      $v = (Get-Item $DSH_EXE).VersionInfo.FileVersion
      OK ("窗口已出现，版本 {0}" -f $v)
      Say '  起来之后如果界面还在报错，把 %TEMP% 里最新的 dsh-first-aid-*.log 发给汐。' 'Gray'
    } else {
      BAD '60 秒内没等到窗口，可能又崩了；看第 3 项里的 crash 日志'
    }
  } else {
    BAD ("找不到 {0}" -f $DSH_EXE)
  }
}

# ============================================================
# 总结
# ============================================================
Head '结果'
if ($script:Issues.Count -eq 0) {
  Say '  全部正常，没发现问题。' 'Green'
} else {
  Say ("  发现 {0} 个问题：" -f $script:Issues.Count) 'Yellow'
  foreach ($i in $script:Issues) { Say ("   - " + $i) 'Yellow' }
}
if ($script:Fixes.Count -gt 0) {
  Say ("  本次做了 {0} 处修复：" -f $script:Fixes.Count) 'Magenta'
  foreach ($f in $script:Fixes) { Say ("   - " + $f) 'Magenta' }
}
if ($Check -and -not $Fix) {
  Say ''
  Say '  想让它自己修，双击「一键急救.cmd」，或在管理员终端跑：' 'Gray'
  Say '    powershell -ExecutionPolicy Bypass -File rescue.ps1 -Fix' 'Gray'
}
Say ''
Say ("日志已存：{0}" -f $LogPath) 'DarkGray'
