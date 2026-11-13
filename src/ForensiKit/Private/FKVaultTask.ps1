# 排程工作 \ForensiKit\VaultBackup 的包裝函式（docs/ARCHITECTURE.md 第 5 節）。
# 獨立成內部函式，讓單元測試可以 Mock，不會真的註冊排程。

$script:FKTaskPath = '\ForensiKit\'
$script:FKTaskName = 'VaultBackup'

function Register-FKVaultTask {
    <#
    .SYNOPSIS
        以 SYSTEM 身分註冊（或覆寫）排程工作 \ForensiKit\VaultBackup，並立即執行一次。

    .DESCRIPTION
        觸發條件：從現在起每 IntervalMinutes 分鐘一次，無限期重複；另加開機時執行。
        已存在時以 -Force 覆寫，所以重複安裝不會產生第二個排程。
        立即執行一次，讓 vault 在安裝後馬上就有第一份備份。

    .PARAMETER RunnerPath
        排程要執行的 PowerShell 腳本完整路徑。

    .PARAMETER IntervalMinutes
        執行間隔（分鐘）。

    .EXAMPLE
        Register-FKVaultTask -RunnerPath 'C:\ProgramData\ForensiKit\bin\VaultBackup.ps1' -IntervalMinutes 60
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunnerPath,

        [Parameter(Mandatory)]
        [ValidateRange(1, 1440)]
        [int]$IntervalMinutes
    )

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $RunnerPath
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $argument

    $repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $boot = New-ScheduledTaskTrigger -AtStartup

    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $null = Register-ScheduledTask -TaskPath $script:FKTaskPath -TaskName $script:FKTaskName -Action $action `
        -Trigger @($repeat, $boot) -Principal $principal -Settings $settings `
        -Description 'ForensiKit：定時把事件記錄備份到 vault（Install-FKPreservation 建立）' -Force -ErrorAction Stop

    Start-ScheduledTask -TaskPath $script:FKTaskPath -TaskName $script:FKTaskName -ErrorAction Stop
}

function Unregister-FKVaultTask {
    <#
    .SYNOPSIS
        刪除排程工作 \ForensiKit\VaultBackup 與空的 \ForensiKit 資料夾。回傳是否真的刪除了排程。

    .EXAMPLE
        Unregister-FKVaultTask
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $task = Get-ScheduledTask -TaskPath $script:FKTaskPath -TaskName $script:FKTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $false }

    Unregister-ScheduledTask -TaskPath $script:FKTaskPath -TaskName $script:FKTaskName -Confirm:$false -ErrorAction Stop

    # 資料夾是空的才刪；失敗（例如裡面還有別的工作）不影響結果
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $service.GetFolder('\').DeleteFolder($script:FKTaskPath.Trim('\'), 0)
    }
    catch {
        Write-Verbose "未刪除排程資料夾 $($script:FKTaskPath)：$($_.Exception.Message)"
    }
    return $true
}

function Get-FKVaultTaskInfo {
    <#
    .SYNOPSIS
        回傳 {Registered, LastRunUtc, LastResult}；LastRunUtc 為 Kind = Utc 的 [datetime]，從未執行時為 $null。

    .EXAMPLE
        Get-FKVaultTaskInfo
    #>
    [CmdletBinding()]
    param()

    $task = Get-ScheduledTask -TaskPath $script:FKTaskPath -TaskName $script:FKTaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [pscustomobject]@{ Registered = $false; LastRunUtc = $null; LastResult = $null }
    }

    $lastRunUtc = $null
    $lastResult = $null
    $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
    if ($info) {
        $lastResult = $info.LastTaskResult
        # 從未執行時 Windows 回傳 1999-11-30 之類的佔位時間
        if ($info.LastRunTime -and $info.LastRunTime.Year -ge 2000) {
            $lastRunUtc = $info.LastRunTime.ToUniversalTime()
        }
    }
    return [pscustomobject]@{ Registered = $true; LastRunUtc = $lastRunUtc; LastResult = $lastResult }
}
