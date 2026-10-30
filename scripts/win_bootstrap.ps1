# 电脑端环境准备（Windows / PowerShell 5.1）。可重复执行，幂等。
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\win_bootstrap.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\win_bootstrap.ps1 -DetectOnly   # 只看串口
param(
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_env.ps1')

# ------------------------------------------------------------------ 1 环境信息
Write-Step '1/7 环境信息'
Write-Host "  PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "  OS         : $([System.Environment]::OSVersion.VersionString)"
Write-Host "  架构       : $env:PROCESSOR_ARCHITECTURE"
Write-Host "  仓库       : $RepoDir"

# ------------------------------------------------------------------ 2 配置文件
Write-Step '2/7 配置文件'
$envPath = Join-Path $RepoDir 'config\env'
if (-not (Test-Path -LiteralPath $envPath)) {
    Copy-Item -LiteralPath (Join-Path $RepoDir 'config\env.example') -Destination $envPath
    Write-Note '已生成 config\env（来自 env.example），请稍后填 BOARD_IP'
} else {
    Write-Ok 'config\env 已存在，保持不变'
}
$map = Read-LeKiwiEnv -RepoDir $RepoDir

$boardIp = Get-LeKiwiSetting $map 'BOARD_IP' ''
$lerobotDir = Get-LeKiwiSetting $map 'LEROBOT_DIR' (Join-Path $env:USERPROFILE 'lerobot')
$lerobotCommit = Get-LeKiwiSetting $map 'LEROBOT_COMMIT' '53feaef'
$leaderId = Get-LeKiwiSetting $map 'LEADER_ID' 'my_awesome_leader_arm'
$leaderPort = Get-LeKiwiSetting $map 'LEADER_PORT' 'COM11'

# ------------------------------------------------------------------ 3 git
Write-Step '3/7 git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Bad '未安装 git，请先装 Git for Windows： https://git-scm.com/download/win'
    exit 1
}
Write-Ok ((git --version) -replace 'git version ', 'git ')

# ------------------------------------------------------------------ 4 uv
Write-Step '4/7 uv'
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    $candidate = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (Test-Path -LiteralPath $candidate) {
        $env:Path = "$(Split-Path $candidate);$env:Path"
        Write-Ok '使用已有的 ~\.local\bin\uv'
    }
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host '  未找到 uv，开始安装 ...'
    powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Bad 'uv 仍不可用，请重开一个终端后重跑本脚本'
    exit 1
}
Write-Ok "uv $(& uv --version)"

# ------------------------------------------------------------------ 5 串口
Write-Step '5/7 串口设备'
$cands = @()
Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.Name -match '\(COM\d+\)' } |
    ForEach-Object {
        $m = [regex]::Match($_.Name, '\(COM(\d+)\)')
        if ($m.Success) {
            $cands += [pscustomobject]@{ Port = "COM$($m.Groups[1].Value)"; Name = $_.Name }
        }
    }

if ($cands.Count -eq 0) {
    Write-Note '未发现串口设备（leader 臂没插？CH34x 驱动没装？）'
} else {
    foreach ($c in $cands) { Write-Host ("  {0,-8} {1}" -f $c.Port, $c.Name) }
}

$leaderCands = @($cands | Where-Object { $_.Name -match 'CH34|USB-Enhanced-SERIAL|CP210|FTDI|USB-SERIAL' })
$detected = $null
if ($leaderCands.Count -eq 1) {
    $detected = $leaderCands[0].Port
    Write-Ok "候选 leader 串口：$detected"
} elseif ($leaderCands.Count -gt 1) {
    Write-Note "有 $($leaderCands.Count) 个候选串口，请手工确认哪个是 leader 臂"
} else {
    Write-Note '没识别到 USB 串口设备'
}

if ($DetectOnly) {
    Write-Host ''
    if ($detected) { Write-Host "  建议写入 config\env: LEADER_PORT=$detected" -ForegroundColor Cyan }
    exit 0
}

if ($detected -and $detected -ne $leaderPort) {
    Set-LeKiwiEnvValue -Path $envPath -Key 'LEADER_PORT' -Value $detected
    Write-Ok "已把 config\env 的 LEADER_PORT 更新为 $detected（原 $leaderPort）"
    $leaderPort = $detected
}

# ------------------------------------------------------------------ 6 lerobot
Write-Step "6/7 lerobot @ $lerobotCommit → $lerobotDir"
if (-not (Test-Path -LiteralPath (Join-Path $lerobotDir '.git'))) {
    New-Item -ItemType Directory -Force -Path $lerobotDir | Out-Null
    git -C $lerobotDir init -q
    git -C $lerobotDir remote add origin https://github.com/huggingface/lerobot.git 2>$null
    Write-Ok '已初始化空仓库'
}
Write-Host "  拉取 $lerobotCommit ..."
git -C $lerobotDir fetch --depth 1 origin $lerobotCommit
if ($LASTEXITCODE -ne 0) { Write-Bad 'git fetch 失败（检查网络/代理）'; exit 1 }
git -C $lerobotDir checkout -q --detach FETCH_HEAD
Write-Ok "checkout: $(git -C $lerobotDir log -1 --oneline)"

Write-Host '  安装依赖（首次约 2~3 分钟）...'
Push-Location $lerobotDir
try {
    & uv sync --locked --extra lekiwi --extra hardware --extra viz
    if ($LASTEXITCODE -ne 0) { Write-Bad 'uv sync 失败'; exit 1 }
} finally {
    Pop-Location
}
Write-Ok '依赖安装完成'

$venvPython = Join-Path $lerobotDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) { Write-Bad "没找到 $venvPython"; exit 1 }
& $venvPython -c "from lerobot.robots.lekiwi import LeKiwiClient; print('import ok')"
if ($LASTEXITCODE -ne 0) { Write-Bad 'import 失败'; exit 1 }
Write-Ok 'lerobot 可导入'

# ------------------------------------------------------------------ 7 自检
Write-Step '7/7 自检'

if ([string]::IsNullOrWhiteSpace($boardIp) -or $boardIp -match '^192\.168\.1\.100$') {
    Write-Note 'BOARD_IP 还是示例值 —— 请填板卡真实 IP（板上执行 hostname -I）'
} elseif (Test-LeKiwiPort -TargetHost $boardIp -Port 5555) {
    Write-Ok "板卡 $boardIp:5555 可达（host 正在运行）"
} else {
    Write-Note "板卡 $boardIp:5555 不可达 —— host 没启动 / IP 变了 / 不同网段"
}

$calib = Join-Path $env:USERPROFILE ".cache\huggingface\lerobot\calibration\teleoperators\so_leader\$leaderId.json"
if (Test-Path -LiteralPath $calib) {
    Write-Ok "leader 校准文件存在：$calib"
} else {
    Write-Note "缺少 leader 校准文件：$calib"
    Write-Note '  → 下一步跑： powershell -ExecutionPolicy Bypass -File scripts\win_calibrate.ps1'
}

if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Write-Ok 'ssh 可用（zero_align.ps1 需要它连板卡）'
} else {
    Write-Note '没有 ssh 命令：zero_align.ps1 将无法自动重启板端 host，需手工操作'
}

Write-Host @"

== 下一步 ==
  1) 填 config\env 的 BOARD_IP / BOARD_USER
  2) 纯键盘验证： powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1 -Keyboard
  3) leader 校准： powershell -ExecutionPolicy Bypass -File scripts\win_calibrate.ps1
  4) 零点对齐：   powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1
  5) 遥操作：     powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1
"@ -ForegroundColor Cyan
