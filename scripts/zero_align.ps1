# 电脑端：零点对齐一条命令。
# 自动完成：停 host → 释放扭矩 → 提示摆姿势 → 重启 host → 测差 → 对齐 → 复测
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1 -DryRun   # 只测差
#   powershell -ExecutionPolicy Bypass -File scripts\zero_align.ps1 -BoardRepo '~/my-repo'
param(
    [switch]$DryRun,
    [string]$BoardRepo = ''
)

$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_env.ps1')

$map = Read-LeKiwiEnv -RepoDir $RepoDir
$lerobotDir = Get-LeKiwiSetting $map 'LEROBOT_DIR' (Join-Path $env:USERPROFILE 'lerobot')
$boardIp = Get-LeKiwiSetting $map 'BOARD_IP' ''
$boardUser = Get-LeKiwiSetting $map 'BOARD_USER' 'aidlux'
$repoOnBoard = if ($BoardRepo) { $BoardRepo } else { Get-LeKiwiSettingRaw $map 'BOARD_REPO' '~/lekiwi-rhinopi-a1' }
# config/env 里习惯写 $HOME（板端路径），这里换成 ~ 交给远端 shell 展开
# 注意：不能用 Get-LeKiwiSetting，它会把 $HOME 展开成 Windows 的 C:\Users\...
$repoOnBoard = $repoOnBoard -replace '\$HOME', '~'
$remote = "$boardUser@$boardIp"

if ([string]::IsNullOrWhiteSpace($boardIp)) { Write-Bad 'config\env 里 BOARD_IP 为空'; exit 1 }
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Bad '没有 ssh 命令，无法自动重启板端 host'
    Write-Note '可手工在板端执行： sh scripts/a1_host.sh stop / release-torque / start'
    exit 1
}

# ---------------------------------------------------------------- 1 停 host + 松扭矩
Write-Step '1/5 停 host 并释放扭矩'
$stopCmd = "cd $repoOnBoard && sh scripts/a1_host.sh stop && sh scripts/a1_host.sh release-torque"
ssh $remote $stopCmd
if ($LASTEXITCODE -ne 0) {
    Write-Bad '板端操作失败'
    Write-Note '常见原因：SSH 免密没配（会卡在密码）、板端仓库路径不对（用 -BoardRepo 指定）'
    exit 1
}

# ---------------------------------------------------------------- 2 摆姿势
Write-Step '2/5 把 leader 与 follower 摆成完全一样的姿势'
Write-Host @'
  参考姿势（尽量对齐每一个关节）：
    - 底座 shoulder_pan 朝正前方
    - shoulder_lift 大臂竖直向上
    - elbow_flex 小臂水平向前
    - wrist_flex 腕部水平
    - wrist_roll 任意（会整圈校准）
    - 夹爪半开

  提示：follow 臂此时已松扭矩，可以自由推动；leader 臂本来就能拖。
'@
Read-Host '摆好后按回车继续（Ctrl+C 放弃）' | Out-Null

# ---------------------------------------------------------------- 3 起 host
Write-Step '3/5 重启 host（会锁住当前姿势）'
ssh $remote "cd $repoOnBoard && sh scripts/a1_host.sh start"
if ($LASTEXITCODE -ne 0) {
    Write-Bad 'host 启动失败，看板端 ~/host.log'
    exit 1
}

# ---------------------------------------------------------------- 4 对齐
Write-Step '4/5 测差 + 对齐'
$alignArgs = @((Join-Path $RepoDir 'scripts\align_leader_to_follower.py'))
if ($DryRun) { $alignArgs += '--dry-run' }

Push-Location $lerobotDir
try {
    & uv run python @alignArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

# ---------------------------------------------------------------- 5 收尾
Write-Step '5/5 结果'
if ($code -eq 0) {
    if ($DryRun) {
        Write-Ok '仅测差（未写入）。去掉 -DryRun 执行对齐'
    } else {
        Write-Ok '对齐完成且残差在 1° 内'
        Write-Note '下一步：powershell -ExecutionPolicy Bypass -File scripts\teleop.ps1'
    }
} else {
    Write-Note '残差偏大或对齐失败：把两臂重新摆成同一姿势后再跑一次'
    Write-Note '任意一侧重新校准过，都必须重跑本脚本'
}
exit $code
