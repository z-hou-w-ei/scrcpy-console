#Requires -Version 5.1
<#
  wifi-pair.ps1 - Android 11+「无线调试」配对 / 连接助手

  被 scrcpy-gui.ps1 以 dot-source 方式加载（提供 Get-MdnsServices / Connect-AdbTarget /
  Invoke-AdbPair / Get-SavedTarget / Save-Target 等函数），也可以单独跑命令排查：

     powershell -File wifi-pair.ps1 -Mdns
     powershell -File wifi-pair.ps1 -Pair 192.168.137.198:39683 -Code 913288
     powershell -File wifi-pair.ps1 -Connect 192.168.137.198:42737

  说明：
    * 无线调试（adb pair）不需要 USB，也不需要 adb tcpip 5555。
    * 配对端口只在手机「使用配对码配对设备」弹窗打开期间有效，关闭即失效。
    * 连接端口是无线调试页面顶部「IP 地址和端口」那个，重启手机会变。
    * 本机地址/配置写在脚本同目录 wifi.json，不进仓库。
#>

param(
    [switch]$Mdns,
    [string]$Pair,
    [string]$Code,
    [string]$Connect,
    [string]$AdbExe,
    [switch]$VerboseOutput
)

$script:adb = if ($AdbExe) { $AdbExe } else { Join-Path $PSScriptRoot 'adb.exe' }

# ---------- basic adb wrappers ----------

function Get-ConnectedDevices {
    $list = @()
    if (-not (Test-Path $script:adb)) { return $list }
    foreach ($line in (& $script:adb devices 2>$null)) {
        if ($line -match '^\s*([^\s]+)\s+device\b') { $list += $Matches[1] }
    }
    return $list
}

function Get-MdnsServices {
    # 解析 `adb mdns services`，返回 Name / Type / Address(ip:port) / IP / Port
    $items = @()
    if (-not (Test-Path $script:adb)) { return $items }
    $raw = (& $script:adb mdns services 2>&1) -join "`n"
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*(\S+)\s+(\S+)\s+(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})\s*$') {
            $items += [pscustomobject]@{
                Name    = $Matches[1]
                Type    = $Matches[2]
                Address = ($Matches[3] + ':' + $Matches[4])
                IP      = $Matches[3]
                Port    = [int]$Matches[4]
            }
        }
    }
    return $items
}

function Get-LocalPrefixes {
    # 本机所有在线网卡的 /24 前缀，用来判断 mDNS 广播是不是"我们这一侧"的设备
    $prefixes = @()
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
                if ($u.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $b = $u.Address.GetAddressBytes()
                if ($b[0] -eq 127) { continue }
                $prefixes += ("{0}.{1}.{2}." -f $b[0], $b[1], $b[2])
            }
        }
    } catch { }
    return $prefixes
}

function Test-LocalIp {
    param([string]$IP, [string[]]$Prefixes)
    if (-not $IP -or -not $Prefixes) { return $false }
    foreach ($p in $Prefixes) {
        if ($IP.StartsWith($p)) { return $true }
    }
    return $false
}

function Get-PairingTarget {
    # 手机开着「使用配对码配对设备」弹窗时才会广播 _adb-tls-pairing._tcp
    $all = Get-MdnsServices
    $prefixes = Get-LocalPrefixes
    $any = ''
    foreach ($s in $all) {
        if ($s.Type -notlike '*pairing*') { continue }
        if (Test-LocalIp -IP $s.IP -Prefixes $prefixes) { return $s.Address }
        if (-not $any) { $any = $s.Address }
    }
    return $any
}

function Get-ConnectionTarget {
    # 优先无线调试的连接端口（_adb-tls-connect），其次旧的 adb tcpip 5555 通告；
    # 两者都优先选本机网段内的设备，避免连到同一局域网里别人的手机。
    $all = Get-MdnsServices
    $prefixes = Get-LocalPrefixes
    $tls = @()
    $classic = @()
    foreach ($s in $all) {
        if ($s.Type -like '*connect*') { $tls += $s }
        elseif ($s.Type -eq '_adb._tcp') { $classic += $s }
    }
    foreach ($s in $tls) { if (Test-LocalIp -IP $s.IP -Prefixes $prefixes) { return $s.Address } }
    if ($tls.Count -gt 0) { return $tls[0].Address }
    foreach ($s in $classic) { if (Test-LocalIp -IP $s.IP -Prefixes $prefixes) { return $s.Address } }
    return ''
}

function Connect-AdbTarget {
    param([string]$Target, [int]$WaitMs = 6000)
    if (-not $Target) { return '' }
    $Target = $Target.Trim()
    if ($Target -notmatch ':') { $Target = $Target + ':5555' }
    if ($VerboseOutput) { Write-Host "adb connect $Target" }
    (& $script:adb connect $Target 2>&1) | Out-Null
    $deadline = (Get-Date).AddMilliseconds($WaitMs)
    while ((Get-Date) -lt $deadline) {
        foreach ($d in (Get-ConnectedDevices)) { if ($d -eq $Target) { return $d } }
        Start-Sleep -Milliseconds 600
    }
    return ''
}

function Invoke-AdbPair {
    param([string]$Target, [string]$Code)
    if (-not $Target -or -not $Code) { return @{ ok = $false; msg = '配对地址或配对码为空' } }
    $Code = ($Code -replace '\s', '')
    if ($Code -notmatch '^\d{6}$') { return @{ ok = $false; msg = '配对码应为 6 位数字' } }
    if ($Target -notmatch ':') { return @{ ok = $false; msg = '配对地址应包含端口，例如 192.168.137.198:39683' } }
    $raw = (& $script:adb pair $Target $Code 2>&1) -join "`n"
    $raw = $raw.Trim()
    if ($VerboseOutput) { Write-Host $raw }
    if ($raw -match 'Successfully paired') { return @{ ok = $true; msg = $raw } }
    return @{ ok = $false; msg = $raw }
}

function Disconnect-AdbTarget {
    param([string]$Target)
    if (-not $Target) { return }
    (& $script:adb disconnect $Target 2>&1) | Out-Null
}

# ---------- remembered target (wifi.json next to this script) ----------

function Get-WifiConfigPath { return (Join-Path $PSScriptRoot 'wifi.json') }

function Get-SavedTarget {
    $p = Get-WifiConfigPath
    if (-not (Test-Path $p)) { return '' }
    try {
        $o = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = [string]$o.target
        if ($t -match '^\d{1,3}(\.\d{1,3}){3}:\d+$') { return $t }
    } catch { }
    return ''
}

function Save-Target {
    param([string]$Target)
    if (-not $Target -or $Target -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d+$') { return }
    $obj = [ordered]@{
        target  = $Target
        updated = (Get-Date -Format 's')
        note    = 'scrcpy-console 上次成功连接的无线地址（可删除，重启手机后端口会变）'
    }
    $json = $obj | ConvertTo-Json
    try {
        [System.IO.File]::WriteAllText((Get-WifiConfigPath), $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------- standalone CLI ----------

if ($Mdns) {
    Write-Host '--- mdns services ---'
    foreach ($s in (Get-MdnsServices)) {
        Write-Host ("{0}`t{1}`t{2}" -f $s.Name, $s.Type, $s.Address)
    }
    Write-Host ('pairing  = ' + (Get-PairingTarget))
    Write-Host ('connect  = ' + (Get-ConnectionTarget))
    Write-Host ('saved    = ' + (Get-SavedTarget))
}
if ($Pair) {
    $r = Invoke-AdbPair -Target $Pair -Code $Code
    Write-Host ('pair ok=' + $r.ok)
    Write-Host $r.msg
}
if ($Connect) {
    $c = Connect-AdbTarget -Target $Connect
    Write-Host ('connect ok=' + [bool]$c + '  serial=' + $c)
    if ($c) { Save-Target $c }
}
