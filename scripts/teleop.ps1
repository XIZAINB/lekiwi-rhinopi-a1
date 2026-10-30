# 电脑端：遥操作入口。
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1               # leader 臂 + 键盘底盘
#   powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1 -Keyboard     # 仅键盘（无 leader 臂）
param(
    [switch]$Keyboard
)

$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_env.ps1')

$map = Read-LeKiwiEnv -RepoDir $RepoDir
$lerobotDir = Get-LeKiwiSetting $map 'LEROBOT_DIR' (Join-Path $env:USERPROFILE 'lerobot')
$boardIp = Get-LeKiwiSetting $map 'BOARD_IP' ''
$cmdPort = [int](Get-LeKiwiSetting $map 'ZMQ_CMD_PORT' '5555')
$leaderPort = Get-LeKiwiSetting $map 'LEADER_PORT' 'COM11'

if (-not (Test-Path -LiteralPath (Join-Path $lerobotDir '.venv'))) {
    Write-Bad "没找到 $lerobotDir\.venv，先跑 scripts\win_bootstrap.ps1"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($boardIp)) {
    Write-Bad 'config\env 里 BOARD_IP 为空'
    exit 1
}

if (-not (Test-LeKiwiPort -TargetHost $boardIp -Port $cmdPort)) {
    Write-Bad "连不上 $boardIp`:$cmdPort"
    Write-Note '检查：板端 sh scripts/a1_host.sh status / IP 是否变了 / 是否同一网段'
    Write-Note "板端启动： ssh <user>@$boardIp 'cd ~/lekiwi-rhinopi-a1 && sh scripts/a1_host.sh start'"
    exit 1
}
Write-Ok "板卡 $boardIp`:$cmdPort 可达"

if ($Keyboard) {
    $script = Join-Path $RepoDir 'scripts\teleoperate_keyboard_only.py'
} else {
    if (-not (Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match "\($leaderPort\)" })) {
        Write-Bad "系统里没有 $leaderPort —— leader 臂没插好，或串口号变了"
        Write-Note '只想玩底盘可以加 -Keyboard；重找串口跑 win_bootstrap.ps1 -DetectOnly'
        exit 1
    }
    $script = Join-Path $RepoDir 'scripts\teleoperate.py'
}

Write-Host ''
Write-Host '  按键：w/s 前后  a/d 左右  z/x 旋转  r/f 调速  Ctrl+C 退出' -ForegroundColor Cyan
Write-Host '  注意：按键焦点要保持在这个终端窗口' -ForegroundColor Yellow
Write-Host ''

Push-Location $lerobotDir
try {
    & uv run python $script
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
