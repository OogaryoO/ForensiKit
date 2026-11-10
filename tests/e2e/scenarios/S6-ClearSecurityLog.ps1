#Requires -Version 5.1
<#
.SYNOPSIS
    S6 清除紀錄模擬：清空 Security 事件記錄（反鑑識），驗證 vault 仍可取回（AC5）。

.DESCRIPTION
    模擬攻擊者清除紀錄湮滅證據（TEST_PLAN.md 第 3 節 S6）：執行 wevtutil cl Security，
    這會產生 Security 1102（記錄檔已清除）。前提是常駐保全（T06）至少已把 Security 備份到
    vault 一次，如此清除後仍能從 evtx/vault/ 取回 S1–S4 的 4625／4720 等事件（AC5）。

    這是破壞性動作，只在測試 VM 內有意義。預設會先確認 vault 裡至少有一份 Security 備份，
    沒有就拒絕執行（避免清掉唯一的紀錄）；確定要測可加 -Force 略過這項檢查。
    因為清除無法還原，-Cleanup 不做任何事（還原請改用快照 clean-baseline）。

.PARAMETER Force
    略過「vault 必須已有 Security 備份」的前置檢查。

.PARAMETER Cleanup
    清除動作無法還原，-Cleanup 只印出提示後結束。

.EXAMPLE
    .\S6-ClearSecurityLog.ps1

.EXAMPLE
    .\S6-ClearSecurityLog.ps1 -Force -Confirm:$false

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
    執行後請以快照 clean-baseline 還原 VM。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Force,
    [switch]$Cleanup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

$VaultSecurityDir = 'C:\ProgramData\ForensiKit\vault\Security'

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    Write-FKScenarioLine 'S6 清除 Security log 無法還原；請用 VirtualBox 快照 clean-baseline 還原 VM。' -Color Yellow
    return
}

Assert-FKTestVM

# ---- 前置檢查：vault 必須已有 Security 備份，否則清除後就真的救不回來 ----
$hasVault = (Test-Path -LiteralPath $VaultSecurityDir) -and
            @(Get-ChildItem -LiteralPath $VaultSecurityDir -Filter '*.evtx' -ErrorAction SilentlyContinue).Count -gt 0
if (-not $hasVault -and -not $Force) {
    throw ("vault 中找不到 Security 備份（{0}）。請先安裝常駐保全（T06）並讓它備份至少一次，" -f $VaultSecurityDir) +
          '再執行 S6；確定仍要清除可加 -Force。'
}

$ctx = Start-FKScenario -Scenario 'S6' -Title '清除 Security 紀錄'
if (-not $hasVault) {
    Write-FKScenarioLine '    警告：vault 無 Security 備份，清除後將無法驗證 AC5（-Force 已略過檢查）。' -Color Red
}

if ($PSCmdlet.ShouldProcess('Security 事件記錄', 'wevtutil cl（清空）')) {
    cmd.exe /c 'wevtutil cl Security' 2>&1 | Out-Null
    Add-FKScenarioStep -Context $ctx -Message 'wevtutil cl Security（預期 Security 1102；vault 仍保有 S1–S4 事件 → AC5）'
    $null = Stop-FKScenario -Context $ctx -Note '已清除 Security log；請從 evtx/vault/ 驗證可取回，再以快照還原 VM。'
    Write-FKScenarioLine 'S6 完成。' -Color Green
}
else {
    Write-FKScenarioLine 'S6 已取消，未清除任何紀錄。' -Color Yellow
}
