#Requires -Version 5.1
<#
.SYNOPSIS
    S4 持久化模擬：建立每分鐘執行的排程工作，並寫入 HKCU Run 自啟機碼。

.DESCRIPTION
    模擬攻擊者建立持久化（TEST_PLAN.md 第 3 節 S4），全程只用內建指令、payload 無害：
      1. 在 C:\Users\Public\fk_updater.cmd 放一個無害批次檔（只寫一行時間到暫存 log）。
      2. schtasks /create 每分鐘執行該批次檔（預期 Security 4698、TaskScheduler 106）。
      3. 在 HKCU\...\Run 寫入 fk_updater 自啟項（預期 Sysmon 13）。

    之後 ForensiKit 的 scheduled_tasks.json 與 autoruns.json 應能看到這兩個項目。
    fk_updater.cmd 不做任何破壞性動作；測試後請用 -Cleanup 移除排程、機碼與批次檔。

.PARAMETER Cleanup
    還原：刪除排程工作、HKCU Run 機碼值與 fk_updater.cmd，不執行攻擊模擬。

.EXAMPLE
    .\S4-Persistence.ps1

.EXAMPLE
    .\S4-Persistence.ps1 -Cleanup

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
#>
[CmdletBinding()]
param([switch]$Cleanup)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

$TaskName  = 'fk_updater'
$CmdPath   = 'C:\Users\Public\fk_updater.cmd'
$RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue  = 'fk_updater'

function Remove-FKPersistence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '內部清理輔助函式，由 -Cleanup 或情境準備階段明確觸發')]
    [CmdletBinding()]
    param()
    $did = $false
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $did = $true
    }
    if (Test-Path -LiteralPath $RunKey) {
        $prop = Get-ItemProperty -LiteralPath $RunKey -Name $RunValue -ErrorAction SilentlyContinue
        if ($null -ne $prop) {
            Remove-ItemProperty -LiteralPath $RunKey -Name $RunValue -ErrorAction SilentlyContinue
            $did = $true
        }
    }
    if (Test-Path -LiteralPath $CmdPath) {
        Remove-Item -LiteralPath $CmdPath -Force -ErrorAction SilentlyContinue
        $did = $true
    }
    return $did
}

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    $removed = Remove-FKPersistence
    Write-FKScenarioLine ("S4 清理完成：{0}" -f $(if ($removed) { '已移除排程／機碼／批次檔' } else { '無項目可移除' })) -Color Yellow
    return
}

Assert-FKTestVM
$ctx = Start-FKScenario -Scenario 'S4' -Title '持久化（排程工作＋Run 機碼）'

$null = Remove-FKPersistence

# ---- 1. 無害 payload 批次檔 ----
$cmdBody = @(
    '@echo off',
    'rem ForensiKit S4 測試用無害批次檔，只記錄執行時間',
    'echo %DATE% %TIME% fk_updater ran >> "%TEMP%\fk_updater.log"'
) -join "`r`n"
Set-Content -LiteralPath $CmdPath -Value $cmdBody -Encoding ASCII
Add-FKScenarioStep -Context $ctx -Message ("建立無害批次檔 {0}" -f $CmdPath)

# ---- 2. 排程工作（每分鐘） → Security 4698、TaskScheduler 106 ----
$null = Invoke-FKTool -FilePath 'schtasks.exe' -Arguments @('/create', '/tn', $TaskName, '/tr', $CmdPath, '/sc', 'minute', '/mo', '1', '/ru', 'SYSTEM', '/f')
Add-FKScenarioStep -Context $ctx -Message ("schtasks /create {0}（每分鐘）（預期 4698／TaskScheduler 106）" -f $TaskName)

# ---- 3. HKCU Run 自啟機碼 → Sysmon 13 ----
if (-not (Test-Path -LiteralPath $RunKey)) { $null = New-Item -Path $RunKey -Force }
$null = New-ItemProperty -LiteralPath $RunKey -Name $RunValue -Value $CmdPath -PropertyType String -Force
Add-FKScenarioStep -Context $ctx -Message ("寫入 HKCU Run 機碼 {0}（預期 Sysmon 13）" -f $RunValue)

$null = Stop-FKScenario -Context $ctx -Note 'scheduled_tasks.json／autoruns.json 應含 fk_updater；測試後用 -Cleanup 還原。'
Write-FKScenarioLine 'S4 完成。' -Color Green
