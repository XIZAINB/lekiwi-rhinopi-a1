# 电脑端：leader 遥控臂校准（交互式，必须人在旁边操作）。
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\win_calibrate.ps1
param(
    [switch]$Recalibrate
)

$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_env.ps1')

$map = Read-LeKiwiEnv -RepoDir $RepoDir
$lerobotDir = Get-LeKiwiSetting $map 'LEROBOT_DIR' (Join-Path $env:USERPROFILE 'lerobot')
$leaderPort = Get-LeKiwiSetting $map 'LEADER_PORT' 'COM11'
$leaderId = Get-LeKiwiSetting $map 'LEADER_ID' 'my_awesome_leader_arm'
$calib = Join-Path $env:USERPROFILE ".cache\huggingface\lerobot\calibration\teleoperators\so_leader\$leaderId.json"

if (-not (Test-Path -LiteralPath (Join-Path $lerobotDir '.venv'))) {
    Write-Bad "没找到 $lerobotDir\.venv，先跑 scripts\win_bootstrap.ps1"
    exit 1
}

$comOk = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match "\($leaderPort\)" }
if (-not $comOk) {
    Write-Bad "系统里没有 $leaderPort —— leader 臂没插好，或串口号变了"
    Write-Note '跑 scripts\win_bootstrap.ps1 -DetectOnly 重新确认'
    exit 1
}

Write-Host @'
==========================================================
leader 校准流程（必须人在旁边操作）
==========================================================
1) 若已有校准文件，会先问：回车=复用旧文件，输入 c 回车=重新校准
   → 需要重校就输 c

2) 【中间位姿】每个关节先推到两端硬限位，再回到行程正中间
   → 然后才按回车（这一步决定零点，别偷懒）

3) 【扫行程】除 wrist_roll 外，每个关节都要
   两个方向都推到硬限位；夹爪完全闭合 ↔ 完全张开
   → 然后才按回车结束记录

4) 只推一个方向 / 记录被打断 → 会报
   "Some motors have the same min and max values"
   → 老老实实手按回车，不要用脚本代按（残留换行会让记录立即结束）

5) 校准只需要 leader 臂 USB 供电，不依赖机器人电池，也不需要 host 运行
==========================================================
'@

Write-Host ''
Write-Host "  leader 串口 : $leaderPort" -ForegroundColor Cyan
Write-Host "  校准文件   : $calib" -ForegroundColor Cyan
if (Test-Path -LiteralPath $calib) {
    Write-Note '已有校准文件；脚本会问是否复用'
    if ($Recalibrate) { Write-Note '已指定 -Recalibrate：在提示处输入 c 覆盖' }
} else {
    Write-Note '首次校准：直接进入摆位流程'
}
Read-Host '准备好了按回车继续（Ctrl+C 放弃）' | Out-Null

Push-Location $lerobotDir
try {
    # 用模块方式调用，避免部分环境 `uv run lerobot-calibrate` 报 Failed to spawn
    & uv run python -m lerobot.scripts.lerobot_calibrate `
        --teleop.type=so100_leader `
        --teleop.port=$leaderPort `
        --teleop.id=$leaderId
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ''
if ($code -eq 0 -and (Test-Path -LiteralPath $calib)) {
    Write-Ok "校准文件：$calib"
    Write-Note '下一步：powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1（零点对齐）'
} else {
    Write-Bad "校准似乎没成功（退出码 $code）"
}
exit $code
