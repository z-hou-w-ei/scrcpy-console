#Requires -Version 5.1
<#
  publish-gitee.ps1 - 把本仓库发布到 Gitee（不需要安装 git）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File publish-gitee.ps1 `
        -Token "你的Gitee私人令牌" -Repo "scrcpy-console" [-Owner "你的用户名"] [-Private]

  说明：
    * 令牌在 https://gitee.com/profile/personal_access_tokens 生成，勾选 projects 权限即可。
    * 令牌只在本进程内存里使用，不写入任何文件。
    * 仓库已存在时会直接复用；不存在则自动创建。
    * 逐个文件走 contents API 提交，适合脚本类小仓库（不适合大二进制）。
#>

param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Owner,
    [switch]$Private,
    [string]$Branch = 'master',
    [string]$Message = 'Initial commit: scrcpy-console'
)

$ErrorActionPreference = 'Stop'
$api = 'https://gitee.com/api/v5'
$repoRoot = Split-Path -Parent $PSScriptRoot

# 要跳过的目录/文件
$excludeDirs = @('.git', 'dist', 'build')
$excludeFiles = @('gui-trace.log', 'phone-ime.log')

function Invoke-Gitee {
    param([string]$Method, [string]$Path, [hashtable]$Body)
    $url = "$api$Path"
    if ($Method -eq 'GET') {
        $sep = if ($url.Contains('?')) { '&' } else { '?' }
        $url = "$url$($sep)access_token=$Token"
        if ($Body) { foreach ($k in $Body.Keys) { $url += "&$k=$([uri]::EscapeDataString([string]$Body[$k]))" } }
        return Invoke-RestMethod -Method GET -Uri $url -ErrorAction Stop
    }
    $Body['access_token'] = $Token
    $json = $Body | ConvertTo-Json -Depth 5
    return Invoke-RestMethod -Method $Method -Uri $url -Body $json -ContentType 'application/json;charset=UTF-8' -ErrorAction Stop
}

# ---------- 1. 确认身份 ----------
$me = Invoke-Gitee -Method GET -Path '/user'
if (-not $Owner) { $Owner = $me.login }
Write-Host ("Gitee 账号：$($me.login)  仓库：$Owner/$Repo")

# ---------- 2. 建仓（已存在则复用）----------
$exists = $false
try {
    $null = Invoke-Gitee -Method GET -Path "/repos/$Owner/$Repo"
    $exists = $true
    Write-Host '仓库已存在，直接推送文件。'
}
catch {
    Write-Host '仓库不存在，开始创建…'
}

if (-not $exists) {
    $body = @{
        name        = $Repo
        description = 'Windows scrcpy 投屏控制台外壳：有线/无线切换、托盘、自动输入法、热点自动开关'
        private     = [bool]$Private
        auto_init   = $false
        has_issues  = $true
        has_wiki    = $false
    }
    $created = Invoke-Gitee -Method POST -Path '/user/repos' -Body $body
    Write-Host ("仓库已创建：" + $created.html_url)
}

# ---------- 3. 逐个文件提交 ----------
$files = Get-ChildItem $repoRoot -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($repoRoot.Length).TrimStart('\')
    $parts = $rel -split '\\'
    if ($parts[0] -in $excludeDirs) { return $false }
    if ($_.Name -in $excludeFiles) { return $false }
    if ($_.Extension -in '.exe', '.dll', '.log', '.bin') { return $false }
    if ($_.Name -eq 'scrcpy-server') { return $false }
    $true
}

$ok = 0; $fail = 0
foreach ($f in $files) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\').Replace('\', '/')
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))

    $sha = $null
    try {
        $info = Invoke-Gitee -Method GET -Path "/repos/$Owner/$Repo/contents/$rel" -Body @{ ref = $Branch }
        if ($info -and $info.sha) { $sha = $info.sha }
    }
    catch { }

    $body = @{
        content = $content
        message = "$Message ($rel)"
        branch  = $Branch
    }
    if ($sha) { $body['sha'] = $sha }

    try {
        Invoke-Gitee -Method POST -Path "/repos/$Owner/$Repo/contents/$rel" -Body $body | Out-Null
        Write-Host ("  ok  $rel")
        $ok++
    }
    catch {
        Write-Warning ("  fail $rel -> " + $_.Exception.Message)
        $fail++
    }
}

Write-Host ''
Write-Host ("完成：成功 $ok 个，失败 $fail 个。仓库地址 https://gitee.com/$Owner/$Repo")
if ($fail -gt 0) { exit 1 }
