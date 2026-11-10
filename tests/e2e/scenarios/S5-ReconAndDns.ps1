#Requires -Version 5.1
<#
.SYNOPSIS
    S5 偵察與外連模擬：執行常見偵察指令並對 example.com 做一次 DNS 查詢。

.DESCRIPTION
    用內建指令模擬攻擊者落地後的偵察行為（TEST_PLAN.md 第 3 節 S5）：
      - whoami /all、net user、ipconfig /all（預期多筆 Sysmon 1 程序建立）
      - Resolve-DnsName example.com（預期 Sysmon 22 DNS 查詢；dns_cache.json 應含 example.com）

    example.com 是 IANA 保留的範例網域，查詢它不連到任何真實服務。此情境無副作用，
    -Cleanup 只清掉可能殘留在 DNS 快取中的 example.com 項目。

.PARAMETER Cleanup
    清除本機 DNS 快取中的 example.com 項目（實際上會清整個快取），不執行偵察模擬。

.EXAMPLE
    .\S5-ReconAndDns.ps1

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
#>
[CmdletBinding()]
param([switch]$Cleanup)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

$DnsTarget = 'example.com'

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-FKScenarioLine 'S5 清理完成：已清除 DNS 用戶端快取。' -Color Yellow
    return
}

Assert-FKTestVM
$ctx = Start-FKScenario -Scenario 'S5' -Title '偵察與外連'

# ---- 偵察指令（各自是一個新程序 → Sysmon 1） ----
cmd.exe /c 'whoami /all'   2>&1 | Out-Null
cmd.exe /c 'net user'      2>&1 | Out-Null
cmd.exe /c 'ipconfig /all' 2>&1 | Out-Null
Add-FKScenarioStep -Context $ctx -Message 'whoami /all、net user、ipconfig /all（預期多筆 Sysmon 1）'

# ---- DNS 查詢 → Sysmon 22；寫入 DNS 快取 ----
$null = Resolve-DnsName -Name $DnsTarget -Type A -ErrorAction SilentlyContinue
Add-FKScenarioStep -Context $ctx -Message ("Resolve-DnsName {0}（預期 Sysmon 22；dns_cache.json 含 {0}）" -f $DnsTarget)

$null = Stop-FKScenario -Context $ctx -Note 'example.com 為 IANA 保留範例網域，不連真實服務。'
Write-FKScenarioLine 'S5 完成。' -Color Green
