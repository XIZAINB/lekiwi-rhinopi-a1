# 供各 .ps1 复用的 config/env 读取器（PowerShell 5.1 兼容）
# 目的：shell / Python / PowerShell 共用同一份 config/env，避免两份配置漂移。

function Read-LeKiwiEnv {
    param([Parameter(Mandatory)][string]$RepoDir)

    $map = @{}
    $path = Join-Path $RepoDir 'config\env'
    if (-not (Test-Path -LiteralPath $path)) { return $map }

    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
        $i = $t.IndexOf('=')
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $map[$k] = $v
    }
    return $map
}

function Expand-LeKiwiValue {
    param([string]$Value)
    if (-not $Value) { return $Value }
    # config/env 里写的是 $HOME（Linux 习惯），Windows 上映射到用户目录
    $v = $Value -replace '\$HOME', $env:USERPROFILE
    return [Environment]::ExpandEnvironmentVariables($v)
}

function Get-LeKiwiSetting {
    param(
        [hashtable]$Map,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )
    # 同名环境变量优先，便于临时覆盖
    $fromEnv = [Environment]::GetEnvironmentVariable($Key)
    if ($fromEnv) { return $fromEnv }
    if ($Map.ContainsKey($Key) -and $Map[$Key]) { return (Expand-LeKiwiValue $Map[$Key]) }
    return $Default
}

function Set-LeKiwiEnvValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8) }

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $lines[$i] = "$Key=$Value"; $found = $true }
    }
    if (-not $found) { $lines += "$Key=$Value" }

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $lines, $enc)
}

function Write-Step([string]$Text) { Write-Host "`n== $Text ==" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [x] $Text" -ForegroundColor Red }

function Test-LeKiwiPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 1500)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); return $false }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}
