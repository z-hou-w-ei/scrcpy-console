<#
  hotspot.ps1 - Windows 移动热点开关（无需管理员权限）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File hotspot.ps1 -Action status
    powershell -NoProfile -ExecutionPolicy Bypass -File hotspot.ps1 -Action start
    powershell -NoProfile -ExecutionPolicy Bypass -File hotspot.ps1 -Action stop
    powershell -NoProfile -ExecutionPolicy Bypass -File hotspot.ps1 -Action toggle

  说明：
    * 走 Windows 自带的 WinRT 网络共享接口，等同于设置里"移动热点"的开关。
    * 热点的名称/密码沿用系统设置里已经配置好的那份，本脚本不写入任何凭据。
    * 本脚本必须在 Windows PowerShell 5.1 下运行（WinRT 投影依赖它），
      若用 PowerShell 7 调用会自动降级转交给 5.1。
#>

param(
    [ValidateSet('start', 'stop', 'status', 'toggle')]
    [string]$Action = 'status',
    [switch]$Quiet
)

# ---- 保证在 Windows PowerShell 5.1 中运行（WinRT 需要） ----
if ($PSVersionTable.PSEdition -eq 'Core') {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps51) {
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Action', $Action)
        if ($Quiet) { $argv += '-Quiet' }
        & $ps51 @argv
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'
$scriptName = '热点'

function Write-Line([string]$text, [string]$color = 'Gray') {
    if (-not $Quiet) { Write-Host $text -ForegroundColor $color }
}

function Get-TetheringManager {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]

    $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $profile) { throw '当前没有可用的网络连接，热点无法共享上网。' }
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
}

function Await-Operation($operation, $resultType) {
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod
        })[0]
    $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
    $task.Wait(-1) | Out-Null
    $task.Result
}

function Get-State([string]$enumValue) {
    switch ($enumValue) {
        'On' { '已开启' }
        'Off' { '已关闭' }
        'Starting' { '正在开启' }
        'Stopping' { '正在关闭' }
        default { $enumValue }
    }
}

try {
    $manager = Get-TetheringManager
}
catch {
    Write-Line ("[$scriptName] 初始化失败：" + $_.Exception.Message) 'Red'
    exit 1
}

$stateNow = [string]$manager.TetheringOperationalState

switch ($Action) {
    'status' {
        if ($Quiet) {
            # 机读模式：只输出原始状态值（On / Off / Starting / Stopping），供控制台调用
            Write-Output $stateNow
            exit 0
        }
        Write-Line ("[$scriptName] 当前状态：" + (Get-State $stateNow)) 'Cyan'
        Write-Line ("[$scriptName] 已连接设备：" + $manager.TetheringClients.Count) 'Gray'
        exit 0
    }
    'start' {
        if ($stateNow -eq 'On') {
            Write-Line ("[$scriptName] 已经是开启状态，无需重复操作。") 'Yellow'
            exit 0
        }
        $result = Await-Operation ($manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        if ([string]$result.Status -ne 'Success') {
            Write-Line ("[$scriptName] 开启失败：" + $result.Status + ' ' + $result.AdditionalErrorMessage) 'Red'
            exit 2
        }
        Write-Line ("[$scriptName] 热点已开启（已连接设备：" + $manager.TetheringClients.Count + "）") 'Green'
        exit 0
    }
    'stop' {
        if ($stateNow -eq 'Off') {
            Write-Line ("[$scriptName] 已经是关闭状态，无需重复操作。") 'Yellow'
            exit 0
        }
        $result = Await-Operation ($manager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        if ([string]$result.Status -ne 'Success') {
            Write-Line ("[$scriptName] 关闭失败：" + $result.Status + ' ' + $result.AdditionalErrorMessage) 'Red'
            exit 2
        }
        Write-Line ("[$scriptName] 热点已关闭。") 'Green'
        exit 0
    }
    'toggle' {
        if ($stateNow -eq 'On') {
            $result = Await-Operation ($manager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            $okText = '已关闭'
        }
        else {
            $result = Await-Operation ($manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            $okText = '已开启'
        }
        if ([string]$result.Status -ne 'Success') {
            Write-Line ("[$scriptName] 切换失败：" + $result.Status + ' ' + $result.AdditionalErrorMessage) 'Red'
            exit 2
        }
        Write-Line ("[$scriptName] 热点$okText。") 'Green'
        exit 0
    }
}
