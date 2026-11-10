#Requires -Version 5.1
<#
.SYNOPSIS
    S2 建立後門帳號模擬：新增本機帳號 fk_backdoor 並加入系統管理員群組。

.DESCRIPTION
    產生「看起來像建立後門」的事件紀錄（TEST_PLAN.md 第 3 節 S2）：
      1. 建立本機帳號 fk_backdoor（隨機密碼）（產生 Security 4720）。
      2. 把 fk_backdoor 加入系統管理員群組（產生 Security 4732）。
    以 New-LocalUser／Add-LocalGroupMember 實作而非 net user——net user 遇到超過 14 字元的
    密碼會跳 Y/N 確認並等待輸入，在非互動批次中會卡住；cmdlet 不會，且產生相同的 Security 事件。

    不安裝任何服務、不留下後門；fk_backdoor 只是用來觸發帳號／群組異動事件的測試帳號，
    測試後請用 -Cleanup 移除。密碼隨機、只存在記憶體，不寫入 repo（安全規則第 4 條）。

.PARAMETER Cleanup
    還原：把 fk_backdoor 移出 Administrators 並刪除帳號，不執行攻擊模擬。

.EXAMPLE
    .\S2-BackdoorAccount.ps1

.EXAMPLE
    .\S2-BackdoorAccount.ps1 -Cleanup

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
#>
[CmdletBinding()]
param([switch]$Cleanup)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

$UserName  = 'fk_backdoor'
# 用 SID 取得系統管理員群組的在地化名稱（中文版是「Administrators」以外的顯示名時仍正確）
$AdminGroup = (Get-LocalGroup -SID 'S-1-5-32-544').Name

function Remove-FKBackdoor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '內部清理輔助函式，由 -Cleanup 或情境準備階段明確觸發')]
    [CmdletBinding()]
    param()
    $existed = [bool](Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)
    if (Get-LocalGroupMember -Group $AdminGroup -Member $UserName -ErrorAction SilentlyContinue) {
        Remove-LocalGroupMember -Group $AdminGroup -Member $UserName -ErrorAction SilentlyContinue
    }
    Remove-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    return $existed
}

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    $removed = Remove-FKBackdoor
    Write-FKScenarioLine ("S2 清理完成：{0}" -f $(if ($removed) { "已刪除 $UserName" } else { "$UserName 不存在" })) -Color Yellow
    return
}

Assert-FKTestVM
$ctx = Start-FKScenario -Scenario 'S2' -Title '建立後門帳號'

$null = Remove-FKBackdoor
$password = New-FKScenarioPassword
try {
    # ---- 新增帳號 → Security 4720 ----
    # 用 New-LocalUser 而非 net user：net user 遇到 >14 字元密碼會跳 Y/N 確認並等 stdin，批次執行會卡住。
    $securePw = New-Object -TypeName System.Security.SecureString
    foreach ($ch in $password.ToCharArray()) { $securePw.AppendChar($ch) }
    $securePw.MakeReadOnly()
    $null = New-LocalUser -Name $UserName -Password $securePw -AccountNeverExpires -ErrorAction Stop
    Add-FKScenarioStep -Context $ctx -Message ("New-LocalUser {0}（預期 Security 4720）" -f $UserName)

    # ---- 加入系統管理員群組 → Security 4732 ----
    Add-LocalGroupMember -Group $AdminGroup -Member $UserName -ErrorAction Stop
    Add-FKScenarioStep -Context $ctx -Message ("加入 {0} 群組（預期 Security 4732）" -f $AdminGroup)
}
finally {
    $password = $null
    $securePw = $null
}

$null = Stop-FKScenario -Context $ctx -Note '測試後請用 -Cleanup 移除 fk_backdoor。'
Write-FKScenarioLine 'S2 完成。' -Color Green
