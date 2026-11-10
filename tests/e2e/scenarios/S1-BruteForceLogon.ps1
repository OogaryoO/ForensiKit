#Requires -Version 5.1
<#
.SYNOPSIS
    S1 暴力破解登入模擬：對本機帳號 fk_victim 連續多次密碼錯誤，最後一次成功。

.DESCRIPTION
    只用 Windows 內建指令產生「看起來像暴力破解」的事件紀錄（TEST_PLAN.md 第 3 節 S1）：
      1. 建立本機測試帳號 fk_victim（隨機密碼，只存在記憶體）。
      2. 透過 net use 連到 \\localhost\IPC$，以錯誤密碼嘗試 -FailedAttempts 次（每次產生 Security 4625）。
      3. 最後一次以正確密碼連線成功（產生 Security 4624，LogonType 3），隨即中斷連線。

    不下載、不撰寫任何惡意程式；全程僅操作本機測試帳號與 IPC$ 共用。
    每次執行都會把 UTC 起訖時間寫到 tests/e2e/run/S1.time.json，供 E2E 決定匯出時段。

.PARAMETER FailedAttempts
    錯誤密碼嘗試次數，預設 6（對應預期事件 minCount 5，留一次緩衝）。

.PARAMETER Cleanup
    還原：刪除本機帳號 fk_victim 並結束，不執行攻擊模擬。

.EXAMPLE
    .\S1-BruteForceLogon.ps1

.EXAMPLE
    .\S1-BruteForceLogon.ps1 -Cleanup

.NOTES
    只在測試 VM 內以系統管理員身分執行（TEST_PLAN.md 安全規則第 1、2 條）。
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$FailedAttempts = 6,

    [switch]$Cleanup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\FKScenario.Common.ps1')

$UserName = 'fk_victim'
$Share    = '\\localhost\IPC$'

function Remove-FKVictim {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '內部清理輔助函式，由 -Cleanup 或情境準備階段明確觸發')]
    [CmdletBinding()]
    param()
    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
        cmd.exe /c "net use $Share /delete /y" 2>&1 | Out-Null
        Remove-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

if ($Cleanup) {
    Assert-FKTestVM -NoAdmin
    $removed = Remove-FKVictim
    Write-FKScenarioLine ("S1 清理完成：{0}" -f $(if ($removed) { "已刪除 $UserName" } else { "$UserName 不存在" })) -Color Yellow
    return
}

Assert-FKTestVM
$ctx = Start-FKScenario -Scenario 'S1' -Title '暴力破解登入'

# ---- 準備：建立測試帳號 ----
$null = Remove-FKVictim
$password = New-FKScenarioPassword
# 直接以 AppendChar 建 SecureString，避免在原始碼留下明文轉換；成功登入步驟仍需明文 $password
$securePw = New-Object -TypeName System.Security.SecureString
foreach ($ch in $password.ToCharArray()) { $securePw.AppendChar($ch) }
$securePw.MakeReadOnly()
$null = New-LocalUser -Name $UserName -Password $securePw -AccountNeverExpires -ErrorAction Stop
Add-FKScenarioStep -Context $ctx -Message ("建立本機帳號 {0}" -f $UserName)

try {
    # ---- 多次錯誤密碼 → Security 4625 ----
    for ($i = 1; $i -le $FailedAttempts; $i++) {
        $wrong = "wrong-$i-" + (New-FKScenarioPassword -Length 8)
        cmd.exe /c "net use $Share /user:$UserName `"$wrong`"" 2>&1 | Out-Null
    }
    Add-FKScenarioStep -Context $ctx -Message ("以錯誤密碼嘗試 {0} 次（預期 Security 4625 ×{0}）" -f $FailedAttempts)

    # ---- 最後一次正確密碼 → Security 4624 (LogonType 3) ----
    cmd.exe /c "net use $Share /user:$UserName `"$password`"" 2>&1 | Out-Null
    cmd.exe /c "net use $Share /delete /y" 2>&1 | Out-Null
    Add-FKScenarioStep -Context $ctx -Message '以正確密碼成功登入一次（預期 Security 4624，LogonType 3）'
}
finally {
    # 立即清掉密碼變數
    $password = $null
    $securePw = $null
}

$null = Stop-FKScenario -Context $ctx -Note '結束後請用 -Cleanup 刪除 fk_victim；或情境保留供後續 artifact 比對。'
Write-FKScenarioLine 'S1 完成。' -Color Green
