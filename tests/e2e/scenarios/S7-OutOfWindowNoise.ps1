#Requires -Version 5.1
<#
.SYNOPSIS
    S7 時段外雜訊：在指定匯出時段「開始之前」先產生一批事件，驗證 AC2 不會誤收。

.DESCRIPTION
    這個情境本身的動作與 S3 相同（一次無害的 -EncodedCommand whoami），但用途不同
    （TEST_PLAN.md 第 3 節 S7）：E2E 會「先」跑 S7，再把匯出時段的開始時間訂在 S7 結束之後，
    於是 S7 產生的事件落在 [StartUtc, EndUtc] 之外。證據包的 evtx/live 匯出「不得」包含這些事件，
    藉此證明時段裁切正確（AC2）。

    S7.time.json 記錄的是「時段外」時間，供 E2E 設定窗格與事後比對。無副作用，-Cleanup 無事可做。

.PARAMETER Cleanup
    無副作用情境，-Cleanup 只印出訊息後結束。

.EXAMPLE
    .\S7-OutOfWindowNoise.ps1

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
    E2E 用法：先跑 S7 → 記下 endUtc → 匯出時段 StartUtc 設在其後 → S1–S5 → 匯出。
#>
[CmdletBinding()]
param([switch]$Cleanup)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    Write-FKScenarioLine 'S7 無持久化項目，無需清理。' -Color Yellow
    return
}

Assert-FKTestVM
$ctx = Start-FKScenario -Scenario 'S7' -Title '時段外雜訊（應被裁切）'

# 與 S3 相同的無害動作，但這批事件預期落在匯出時段之外
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('whoami'))
$psExe = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
& $psExe -NoProfile -NonInteractive -EncodedCommand $encoded | Out-Null
Add-FKScenarioStep -Context $ctx -Message '時段外產生一次 -EncodedCommand whoami（AC2：不得出現在 evtx/live）'

$null = Stop-FKScenario -Context $ctx -Note '這批事件應被時段裁切排除；E2E 需在 S7 結束後才設定匯出時段起點。'
Write-FKScenarioLine 'S7 完成。' -Color Green
