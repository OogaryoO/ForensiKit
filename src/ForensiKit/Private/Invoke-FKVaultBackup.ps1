function Invoke-FKVaultBackup {
    <#
    .SYNOPSIS
        把設定中的每個 channel 備份到 vault（排程工作 \ForensiKit\VaultBackup 以 SYSTEM 身分每小時執行）。

    .DESCRIPTION
        每個 channel 產生 <vaultRoot>\<Channel 安全名稱>\<yyyyMMddTHHmmssZ>.evtx（docs/ARCHITECTURE.md 第 5 節）。
        - 第一次備份：wevtutil epl 匯出整個 channel。
        - 之後：只匯出「上一份備份時間 − OverlapMinutes」之後的事件（增量，用相同的 vault 空間保留更長的歷史）。
          保留重疊區間，避免排程延遲或時鐘誤差造成漏失；重複的事件在 T04 匯出時會依時段裁切。
        - channel 不存在（例如沒裝 Sysmon）→ Skipped，不中斷。
        - 備份完成後依 vaultMaxTotalMB 刪除最舊的備份（Limit-FKVaultSize）。
        動作寫入 <vaultRoot>\action_log.jsonl（一般管理員對 vault 只有讀取權限，較不易被竄改）。

    .PARAMETER ConfigPath
        設定檔路徑（安裝時寫入的 preservation.json）。

    .PARAMETER OverlapMinutes
        增量備份往前重疊的分鐘數，預設 5。

    .EXAMPLE
        Invoke-FKVaultBackup -ConfigPath 'C:\ProgramData\ForensiKit\preservation.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [ValidateRange(0, 1440)]
        [int]$OverlapMinutes = 5
    )

    $config = Get-FKConfig -Path $ConfigPath
    $vaultRoot = [string]$config.preservation.vaultRoot
    if (-not (Test-Path -LiteralPath $vaultRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $vaultRoot -Force
    }

    $previousLog = Get-FKActionLogPath
    $null = Open-FKActionLog -PackageRoot $vaultRoot
    try {
        $now = [datetime]::UtcNow
        $stamp = $now.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $results = New-Object System.Collections.Generic.List[object]

        foreach ($channel in @($config.channels)) {
            $channel = [string]$channel
            if ($null -eq (Get-FKLogMaxSize -Channel $channel)) {
                Write-FKAction -Action 'VaultBackup' -Target $channel -Detail 'channel 不存在，略過' -Status 'Skipped'
                $results.Add([pscustomobject]@{ Channel = $channel; Path = $null; Status = 'Skipped' })
                continue
            }

            $channelDir = Join-Path $vaultRoot (ConvertTo-FKSafeChannelName -Channel $channel)
            if (-not (Test-Path -LiteralPath $channelDir -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $channelDir -Force
            }
            $dest = Join-Path $channelDir "$stamp.evtx"

            $arguments = @('epl', $channel, $dest)
            $lastBackupUtc = Get-FKLatestVaultBackupTime -ChannelDir $channelDir
            if ($lastBackupUtc) {
                $since = $lastBackupUtc.AddMinutes(-$OverlapMinutes).ToString("yyyy-MM-dd'T'HH:mm:ss'.000Z'", [System.Globalization.CultureInfo]::InvariantCulture)
                $arguments += "/q:*[System[TimeCreated[@SystemTime>='$since']]]"
            }

            $r = Invoke-FKNative -FilePath 'wevtutil.exe' -ArgumentList $arguments
            if ($r.ExitCode -eq 0) {
                Write-FKAction -Action 'VaultBackup' -Target $channel -Detail $r.CommandLine -Status 'OK'
                $results.Add([pscustomobject]@{ Channel = $channel; Path = $dest; Status = 'OK' })
            }
            else {
                Write-FKAction -Action 'VaultBackup' -Target $channel -Detail ("{0} → exit {1}：{2}" -f $r.CommandLine, $r.ExitCode, $r.Output) -Status 'Failed'
                $results.Add([pscustomobject]@{ Channel = $channel; Path = $null; Status = 'Failed' })
            }
        }

        Limit-FKVaultSize -VaultRoot $vaultRoot -MaxTotalMB ([int]$config.preservation.vaultMaxTotalMB)
        return $results.ToArray()
    }
    finally {
        if ($previousLog) { $null = Open-FKActionLog -PackageRoot (Split-Path -Path $previousLog -Parent) }
        else { Close-FKActionLog }
    }
}

function Get-FKLatestVaultBackupTime {
    <#
    .SYNOPSIS
        依檔名（yyyyMMddTHHmmssZ.evtx）回傳 channel 目錄中最新一份備份的 UTC 時間；沒有備份時回傳 $null。

    .PARAMETER ChannelDir
        vault 中某個 channel 的目錄。

    .EXAMPLE
        Get-FKLatestVaultBackupTime -ChannelDir 'C:\ProgramData\ForensiKit\vault\Security'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ChannelDir
    )

    $latest = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $ChannelDir -Filter '*.evtx' -File -ErrorAction SilentlyContinue)) {
        $t = ConvertFrom-FKVaultFileName -Name $file.Name
        if ($t -and (-not $latest -or $t -gt $latest)) { $latest = $t }
    }
    return $latest
}

function ConvertFrom-FKVaultFileName {
    <#
    .SYNOPSIS
        把 vault 備份檔名 yyyyMMddTHHmmssZ.evtx 轉成 Kind = Utc 的 [datetime]；格式不符時回傳 $null。

    .PARAMETER Name
        檔名（含或不含 .evtx）。

    .EXAMPLE
        ConvertFrom-FKVaultFileName -Name '20261120T031500Z.evtx'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal'
    if ([datetime]::TryParseExact($base, "yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Limit-FKVaultSize {
    <#
    .SYNOPSIS
        vault 中 .evtx 總大小超過 MaxTotalMB 時，從最舊的備份開始刪除；每個 channel 至少保留最新一份。

    .PARAMETER VaultRoot
        vault 根目錄。

    .PARAMETER MaxTotalMB
        vault 容量上限（MB）。

    .EXAMPLE
        Limit-FKVaultSize -VaultRoot 'C:\ProgramData\ForensiKit\vault' -MaxTotalMB 2048
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultRoot,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxTotalMB
    )

    $limit = [long]$MaxTotalMB * 1MB
    $files = @(Get-ChildItem -LiteralPath $VaultRoot -Filter '*.evtx' -File -Recurse -ErrorAction SilentlyContinue)
    $total = [long](($files | Measure-Object -Property Length -Sum).Sum)
    if ($total -le $limit) { return }

    # 每個 channel 目錄中最新的一份不刪
    $keep = @{}
    foreach ($group in ($files | Group-Object -Property DirectoryName)) {
        $newest = $group.Group | Sort-Object -Property Name -Descending | Select-Object -First 1
        $keep[$newest.FullName] = $true
    }

    $candidates = $files | Where-Object { -not $keep.ContainsKey($_.FullName) } | Sort-Object -Property Name, DirectoryName
    foreach ($file in $candidates) {
        if ($total -le $limit) { break }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $total -= $file.Length
            Write-FKAction -Action 'VaultPrune' -Target $file.FullName -Detail ("超過 vaultMaxTotalMB={0}，刪除最舊備份（{1} bytes）" -f $MaxTotalMB, $file.Length) -Status 'OK'
        }
        catch {
            Write-FKAction -Action 'VaultPrune' -Target $file.FullName -Detail $_.Exception.Message -Status 'Failed'
        }
    }

    if ($total -gt $limit) {
        Write-FKAction -Action 'VaultPrune' -Target $VaultRoot -Detail ("只剩每個 channel 的最新備份，仍超過上限（{0} bytes > {1} bytes）" -f $total, $limit) -Status 'Partial'
    }
}
