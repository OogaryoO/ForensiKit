#Requires -Version 5.1
<#
.SYNOPSIS
    T03 攻擊模擬情境腳本（S1–S7）共用的輔助函式。

.DESCRIPTION
    由 tests/e2e/scenarios/*.ps1 以 dot-source 載入。提供：

      - Assert-FKTestVM      確認 C:\FK-TEST-VM.marker 存在（安全護欄），不存在就 throw。
      - Test-FKElevated      確認目前以系統管理員身分執行。
      - Get-FKRunDir         取得並建立 tests/e2e/run 目錄（已被 gitignore）。
      - Start-FKScenario     記錄情境開始時間並印出標頭，回傳情境內容物件。
      - Stop-FKScenario      記錄情境結束時間，把 UTC 起訖寫進 run/<情境>.time.json。
      - New-FKScenarioPassword  產生只存在於記憶體的隨機測試密碼（永不寫入 repo）。
      - Write-FKScenarioLine 一致的主控台輸出。

    時間一律以 UTC 處理（ARCHITECTURE.md 第 3 節）；time.json 供 T12 的 E2E 決定匯出時段。

.NOTES
    只在測試 VM 內執行（docs/TEST_PLAN.md 安全規則第 1、2 條）。本檔不自行執行任何攻擊動作。
#>

Set-StrictMode -Version 2.0

$script:FKMarkerPath = 'C:\FK-TEST-VM.marker'

function Write-FKScenarioLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = '互動式情境腳本，需要在主控台顯示進度')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-FKUtcTimestamp {
    <# 以 ISO 8601（…Z）格式回傳目前 UTC 時間字串。 #>
    [CmdletBinding()]
    param([datetime]$Time = [datetime]::UtcNow)
    return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-FKTool {
    <#
    .SYNOPSIS
        直接呼叫外部工具（net、schtasks、wevtutil…），忽略輸出，並避免 native stderr 中斷流程。
    .DESCRIPTION
        由 PowerShell 直接傳遞參數陣列（不經 cmd.exe，免去巢狀引號問題）。某些情境（如暴力破解）
        預期工具會回傳非 0 並寫入 stderr（例如 net 的「系統發生 1326 錯誤」）；為避免在
        $ErrorActionPreference='Stop' 下被當成終止錯誤，這裡在呼叫期間暫時改為 'Continue' 並吞掉輸出。
        回傳工具的 exit code，呼叫端可自行判斷。
    .OUTPUTS
        [int] exit code
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '僅轉呼叫外部工具，狀態改變由情境腳本語意決定')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }
}

function Test-FKElevated {
    <#
    .SYNOPSIS
        目前的 PowerShell 是否以系統管理員身分執行。
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-FKTestVM {
    <#
    .SYNOPSIS
        確認腳本正在 ForensiKit 測試 VM 內執行。
    .DESCRIPTION
        檢查標記檔 C:\FK-TEST-VM.marker（只由 scripts/vm/Setup-TestVM.ps1 在 VM 中建立）。
        找不到就 throw，避免在實體電腦上執行攻擊模擬（TEST_PLAN.md 安全規則第 2 條）。
        預設同時要求系統管理員權限，可用 -NoAdmin 關閉（例如只做 -Cleanup 的乾跑）。
    #>
    [CmdletBinding()]
    param([switch]$NoAdmin)

    if (-not (Test-Path -LiteralPath $script:FKMarkerPath)) {
        throw ("找不到測試 VM 標記檔 {0}。攻擊模擬只能在 ForensiKit 測試 VM 內執行；" -f $script:FKMarkerPath) +
              '請先用 scripts/vm/Setup-TestVM.ps1 建好 VM（TEST_PLAN.md 安全規則第 1、2 條）。'
    }
    if (-not $NoAdmin -and -not (Test-FKElevated)) {
        throw '請以系統管理員身分開啟 Windows PowerShell 後再執行此情境。'
    }
}

function Get-FKRunDir {
    <#
    .SYNOPSIS
        回傳 tests/e2e/run 目錄的絕對路徑，必要時建立它。
    .DESCRIPTION
        以本共用檔的位置（tests/e2e/lib）往上一層推算 tests/e2e/run。此目錄已被 gitignore，
        用來存放情境的時間紀錄與暫存輸出，不得 commit。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $e2eRoot = Split-Path -Path $PSScriptRoot -Parent
    $runDir  = Join-Path -Path $e2eRoot -ChildPath 'run'
    if (-not (Test-Path -LiteralPath $runDir)) {
        $null = New-Item -Path $runDir -ItemType Directory -Force
    }
    return $runDir
}

function New-FKScenarioPassword {
    <#
    .SYNOPSIS
        產生一組符合複雜度要求的隨機測試密碼，只存在於記憶體。
    .DESCRIPTION
        用 RNGCryptoServiceProvider 取亂數組成密碼，供情境建立 fk_ 測試帳號使用。
        呼叫端用完即棄，絕不寫入 repo、檔案或主控台（TEST_PLAN.md 安全規則第 4 條）。
    .OUTPUTS
        [string]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '只產生字串，不改變系統狀態')]
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Length = 20)

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnpqrstuvwxyz',
        '23456789',
        '@#*-_=+'
    )
    $all   = ($sets -join '').ToCharArray()
    $bytes = New-Object 'byte[]' ($Length)
    $rng   = [Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    $chars = New-Object 'System.Collections.Generic.List[char]'
    # 先各放一個，保證每類至少一個字元
    foreach ($set in $sets) { $chars.Add($set[(Get-Random -Maximum $set.Length)]) }
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars.Add($all[[int]$bytes[$i] % $all.Length])
    }
    # 洗牌，避免固定前綴
    $ordered = $chars | Sort-Object { Get-Random }
    return -join $ordered
}

function Start-FKScenario {
    <#
    .SYNOPSIS
        開始一個情境：記錄 UTC 開始時間並印出標頭。
    .OUTPUTS
        情境內容物件 { Scenario, Title, StartUtc, Steps }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '僅記錄開始時間並輸出標頭，不改變系統狀態')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][string]$Title
    )
    $start = [datetime]::UtcNow
    Write-FKScenarioLine ''
    Write-FKScenarioLine ('=== {0} {1} ===' -f $Scenario, $Title) -Color Cyan
    Write-FKScenarioLine ('    開始（UTC）：{0}' -f (Get-FKUtcTimestamp -Time $start)) -Color DarkCyan
    return [pscustomobject]@{
        Scenario = $Scenario
        Title    = $Title
        StartUtc = $start
        Steps    = New-Object 'System.Collections.Generic.List[string]'
    }
}

function Stop-FKScenario {
    <#
    .SYNOPSIS
        結束情境：記錄 UTC 結束時間，並寫入 run/<情境>.time.json。
    .DESCRIPTION
        time.json 內含 scenario、startUtc、endUtc、host、steps，供 T12 的 E2E 決定匯出時段
        與對照「時段外雜訊」（AC2）。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '僅寫入測試用時間紀錄檔，由情境流程明確呼叫')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [string]$Note = ''
    )
    $end     = [datetime]::UtcNow
    $runDir  = Get-FKRunDir
    $outFile = Join-Path -Path $runDir -ChildPath ('{0}.time.json' -f $Context.Scenario)

    $record = [ordered]@{
        scenario = $Context.Scenario
        title    = $Context.Title
        host     = $env:COMPUTERNAME
        startUtc = (Get-FKUtcTimestamp -Time $Context.StartUtc)
        endUtc   = (Get-FKUtcTimestamp -Time $end)
        steps    = @($Context.Steps)
        note     = $Note
    }
    Set-Content -LiteralPath $outFile -Value ($record | ConvertTo-Json -Depth 4) -Encoding UTF8

    Write-FKScenarioLine ('    結束（UTC）：{0}' -f (Get-FKUtcTimestamp -Time $end)) -Color DarkCyan
    Write-FKScenarioLine ('    時間紀錄：{0}' -f $outFile) -Color DarkGray
    return $outFile
}

function Add-FKScenarioStep {
    <# 把一個已完成的步驟描述加入情境內容，並印出。 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $Context.Steps.Add($Message)
    Write-FKScenarioLine ('    - {0}' -f $Message) -Color Gray
}
