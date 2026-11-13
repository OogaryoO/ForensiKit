function Get-FKPreservationStatus {
    <#
    .SYNOPSIS
        查詢常駐保全的狀態：排程是否存在、上次備份時間、vault 大小、各 channel 目前的上限。

    .DESCRIPTION
        回傳 {TaskRegistered, LastRunUtc, VaultSizeMB, LogSizes}（docs/ARCHITECTURE.md 第 7 節）。
        - LastRunUtc：Kind = Utc 的 [datetime]；從未執行或未安裝時為 $null。
        - VaultSizeMB：vault 中所有 .evtx 的總大小（MB，小數兩位）；vault 不存在為 0，無權限讀取為 $null。
        - LogSizes：設定中每個 channel 一筆 {Channel, MaxSizeMB, Exists}。
        設定以安裝時寫入的 preservation.json 為準，尚未安裝時用內建預設值。
        不修改任何東西，未安裝時也不 throw。讀取 vault 需要系統管理員權限。

    .EXAMPLE
        Get-FKPreservationStatus

    .EXAMPLE
        (Get-FKPreservationStatus).LogSizes | Format-Table
    #>
    [CmdletBinding()]
    param()

    $configPath = Join-Path (Get-FKInstallRoot) 'preservation.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) { $config = Get-FKConfig -Path $configPath }
    else { $config = Get-FKConfig }

    $taskInfo = Get-FKVaultTaskInfo

    $vaultRoot = [string]$config.preservation.vaultRoot
    $vaultSizeMB = 0
    if (Test-Path -LiteralPath $vaultRoot -PathType Container) {
        try {
            $files = @(Get-ChildItem -LiteralPath $vaultRoot -Filter '*.evtx' -File -Recurse -ErrorAction Stop)
            $bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
            $vaultSizeMB = [math]::Round($bytes / 1MB, 2)
        }
        catch {
            Write-Warning "無法讀取 vault（$vaultRoot），請以系統管理員身分執行：$($_.Exception.Message)"
            $vaultSizeMB = $null
        }
    }

    $logSizes = foreach ($channel in @($config.channels)) {
        $bytes = Get-FKLogMaxSize -Channel ([string]$channel)
        $sizeMB = $null
        if ($null -ne $bytes) { $sizeMB = [math]::Round($bytes / 1MB, 2) }
        [pscustomobject]@{
            Channel   = [string]$channel
            MaxSizeMB = $sizeMB
            Exists    = ($null -ne $bytes)
        }
    }

    return [pscustomobject]@{
        TaskRegistered = [bool]$taskInfo.Registered
        LastRunUtc     = $taskInfo.LastRunUtc
        VaultSizeMB    = $vaultSizeMB
        LogSizes       = @($logSizes)
    }
}
