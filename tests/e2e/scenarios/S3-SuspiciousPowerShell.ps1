#Requires -Version 5.1
<#
.SYNOPSIS
    S3 可疑 PowerShell 模擬：以 -EncodedCommand 執行一段無害指令（whoami）。

.DESCRIPTION
    用 Base64 編碼的指令列啟動 PowerShell，模擬攻擊者常見的 -EncodedCommand 混淆手法，
    但內容只是無害的 whoami（TEST_PLAN.md 第 3 節 S3）。預期事件：
      - Security 4688（新程序，含命令列，可看到 powershell.exe -EncodedCommand ...）
      - Microsoft-Windows-PowerShell/Operational 4104（Script Block Logging）
      - Microsoft-Windows-Sysmon/Operational 1（程序建立）

    不下載、不執行任何惡意內容；編碼的內容固定為 whoami。此情境不建立任何帳號或持久化項目，
    因此 -Cleanup 無事可做（保留參數以符合所有情境一致的介面）。

.PARAMETER Cleanup
    無副作用情境，-Cleanup 只印出訊息後結束。

.EXAMPLE
    .\S3-SuspiciousPowerShell.ps1

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
#>
[CmdletBinding()]
param([switch]$Cleanup)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    Write-FKScenarioLine 'S3 無持久化項目，無需清理。' -Color Yellow
    return
}

Assert-FKTestVM
$ctx = Start-FKScenario -Scenario 'S3' -Title '可疑 PowerShell（-EncodedCommand）'

# 固定為無害指令 whoami；-EncodedCommand 需要 UTF-16LE 的 Base64
$innerCommand = 'whoami'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerCommand))

$psExe = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
& $psExe -NoProfile -NonInteractive -EncodedCommand $encoded | Out-Null
Add-FKScenarioStep -Context $ctx -Message ("powershell.exe -EncodedCommand（內容：{0}）（預期 4688／4104／Sysmon 1）" -f $innerCommand)

$null = Stop-FKScenario -Context $ctx -Note '無害 whoami；用於觸發命令列稽核與 Script Block Logging。'
Write-FKScenarioLine 'S3 完成。' -Color Green
