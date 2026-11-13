function Write-FKAction {
    <#
    .SYNOPSIS
        把一筆工具動作寫進目前證據包的 action_log.jsonl（監管鏈的一部分）。

    .DESCRIPTION
        每次呼叫在 action_log.jsonl 附加一行 JSON（UTF-8 無 BOM、LF 結尾），格式依 docs/ARCHITECTURE.md 第 4 節：
        {"timeUtc":"2026-11-21T02:03:04Z","action":"...","target":"...","detail":"...","status":"OK"}

        「目前證據包」由模組內部函式 Open-FKActionLog -PackageRoot <路徑> 指定（Invoke-ForensiKit 開始時呼叫），
        Close-FKActionLog 結束。尚未指定證據包時（例如單獨呼叫 Export-FKEventLog 做測試）不寫檔，只輸出 Verbose 訊息，
        不會中斷蒐證流程。寫檔失敗時輸出 Warning，同樣不中斷流程（契約第 3 節）。

    .PARAMETER Action
        動作名稱，例如 ExportEventLog、CopyPrefetch、ComputeHash。

    .PARAMETER Target
        動作對象，例如 channel 名稱或檔案路徑。可為空字串。

    .PARAMETER Detail
        細節；呼叫外部指令時要放完整命令列（CONTRIBUTING.md 第 5 節）。可為空字串。

    .PARAMETER Status
        OK、Partial、Failed 或 Skipped。

    .EXAMPLE
        Write-FKAction -Action 'ExportEventLog' -Target 'Security' -Detail 'wevtutil epl Security C:\out\Security.evtx /q:...' -Status 'OK'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Target,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Detail,

        [Parameter(Mandatory)]
        [ValidateSet('OK', 'Partial', 'Failed', 'Skipped')]
        [string]$Status
    )

    $entry = [ordered]@{
        timeUtc = ConvertTo-FKIsoUtc -Date ([datetime]::UtcNow)
        action  = $Action
        target  = $Target
        detail  = $Detail
        status  = $Status
    }
    $line = ConvertTo-Json -InputObject $entry -Compress

    $logPath = $script:FKActionLogPath
    if (-not $logPath) {
        Write-Verbose "未指定證據包（Open-FKActionLog），action 未寫檔：$line"
        return
    }

    try {
        [System.IO.File]::AppendAllText($logPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Warning "無法寫入 action log ($logPath)：$($_.Exception.Message)；內容：$line"
    }
}
