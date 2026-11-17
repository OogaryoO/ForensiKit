function Export-FKEventLog {
    <#
    .SYNOPSIS
        依時段把事件記錄匯出成原生 EVTX（現行 log；加 -IncludeVault 時也匯出 vault 備份）。

    .DESCRIPTION
        對每個 channel 執行 wevtutil epl，以 TimeCreated/@SystemTime 篩選 [StartUtc, EndUtc]（含兩端），保留原生 EVTX 格式。
        輸出位置（docs/ARCHITECTURE.md 第 4 節）：
          - 現行 log：<Destination>\live\<Channel 安全名稱>.evtx
          - vault   ：<Destination>\vault\<Channel 安全名稱>\<備份時間>.evtx（檔名與 vault 中的備份檔相同）
        Channel 安全名稱是把 / 改為 %4（ConvertTo-FKSafeChannelName）。

        錯誤處理（契約第 3 節）：
          - channel 不存在（例如沒裝 Sysmon，wevtutil exit code 15007）→ Status = Skipped
          - wevtutil 匯出失敗 → Status = Failed
          - 匯出成功但無法計算筆數 → Status = Partial、EventCount = $null
          單一 channel 失敗不會中斷其他 channel；只有參數錯誤才 throw。
        每次呼叫 wevtutil 的完整命令列都會寫進 action log（Write-FKAction）。

        Vault（-IncludeVault，docs/ARCHITECTURE.md 第 5 節）：
          vault 是增量備份，所以會掃描 channel 目錄下所有 *.evtx，對每一份以相同時段條件匯出（wevtutil epl <file> /lf:true），不去重。
          為了避免備份很多時匯出太慢，依檔名時間略過「一定不含此時段事件」的備份，判斷時保留 60 分鐘的安全邊界：
            - 備份時間 + 60 分鐘 < StartUtc：該份只含備份當下以前的事件
            - 上一份備份時間 - 60 分鐘 > EndUtc：該份只含上一份備份之後（重疊 5 分鐘）的事件
          每個 channel 回傳一筆 Source = 'Vault' 的結果：Path 為輸出目錄、EventCount 為各份的合計。
          全部成功為 OK；部分失敗為 Partial；全部失敗為 Failed；vault 中沒有該 channel 的備份為 Skipped。

    .PARAMETER StartUtc
        時段起點（UTC，含）。Kind = Local 的時間會先轉成 UTC；Kind = Unspecified 視為 UTC。

    .PARAMETER EndUtc
        時段終點（UTC，含）。不得早於 StartUtc。

    .PARAMETER Destination
        證據包中的 evtx 目錄，例如 <PackageRoot>\evtx。不存在時自動建立。

    .PARAMETER Channels
        要匯出的 channel。省略時使用 Get-FKConfig 設定中的 channels。

    .PARAMETER IncludeVault
        同時從 vault（Get-FKConfig 的 preservation.vaultRoot）匯出同一時段的事件，用於 log 已被清除或覆寫的情況。

    .OUTPUTS
        每個 channel 一筆 [pscustomobject]：Channel、Source（'Live' 或 'Vault'）、Path、EventCount、Status。

    .EXAMPLE
        $start = [datetime]::SpecifyKind([datetime]'2026-11-20 00:00:00', 'Utc')
        $end   = [datetime]::SpecifyKind([datetime]'2026-11-21 00:00:00', 'Utc')
        Export-FKEventLog -StartUtc $start -EndUtc $end -Destination 'E:\FK_2026-001_WIN11_20261121T020304Z\evtx' -Channels 'Security'

    .EXAMPLE
        Export-FKEventLog -StartUtc $start -EndUtc $end -Destination "$pkg\evtx" -IncludeVault
        # 匯出設定中的所有 channel，並從 vault 取回同一時段的事件
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$Channels,

        [Parameter()]
        [switch]$IncludeVault
    )

    # ---- 內部輔助（只在本函式內使用） ----

    function ConvertTo-FKUtcKind {
        param([datetime]$Date)
        if ($Date.Kind -eq [System.DateTimeKind]::Local) { return $Date.ToUniversalTime() }
        return [datetime]::SpecifyKind($Date, [System.DateTimeKind]::Utc)
    }

    function Invoke-FKWevtutil {
        # 以 PowerShell 直接傳參呼叫 wevtutil（不經 cmd.exe），回傳 exit code、輸出與完整命令列，不 throw。
        # 呼叫名稱必須是 wevtutil（不是完整路徑），單元測試才能以 Mock 取代。
        param([string[]]$ArgumentList)
        $display = @($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& wevtutil @ArgumentList 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        }
        catch {
            $output = @($_.Exception.Message)
            $exitCode = -1
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }
        return [pscustomobject]@{
            ExitCode    = $exitCode
            Output      = (($output -join ' ') -replace '\s+', ' ').Trim()
            CommandLine = "wevtutil $display"
        }
    }

    function Measure-FKEvtxEvent {
        # 以 Get-WinEvent -Path 計算筆數（TASKS.md T04）。沒有事件時 Get-WinEvent 會 throw NoMatchingEventsFound，視為 0 筆。
        param([string]$Path)
        $escaped = [System.Management.Automation.WildcardPattern]::Escape($Path)
        try {
            # 用管線串流計數，大型 log 不必整個載入記憶體
            return [int](Get-WinEvent -Path $escaped -ErrorAction Stop | Measure-Object).Count
        }
        catch {
            if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return 0 }
            throw
        }
    }

    function Export-FKEvtxFile {
        # 匯出單一來源（channel 名稱或 vault 備份檔），寫 action log，回傳 {Path, EventCount, Status}。
        param(
            [string]$ActionName,
            [string]$Source,
            [string]$OutFile,
            [switch]$LogFile
        )
        $wevArgs = @('epl', $Source, $OutFile, "/q:$query")
        if ($LogFile) { $wevArgs += '/lf:true' }

        $r = Invoke-FKWevtutil -ArgumentList $wevArgs
        if ($r.ExitCode -ne 0) {
            Write-FKAction -Action $ActionName -Target $Source -Detail ('{0} → exit {1}：{2}' -f $r.CommandLine, $r.ExitCode, $r.Output) -Status 'Failed'
            $leftover = $null
            if (Test-Path -LiteralPath $OutFile -PathType Leaf) { $leftover = $OutFile }
            return [pscustomobject]@{ Path = $leftover; EventCount = $null; Status = 'Failed' }
        }

        try {
            $count = Measure-FKEvtxEvent -Path $OutFile
        }
        catch {
            Write-FKAction -Action $ActionName -Target $Source -Detail ('{0} → 已匯出，但無法計算筆數：{1}' -f $r.CommandLine, $_.Exception.Message) -Status 'Partial'
            return [pscustomobject]@{ Path = $OutFile; EventCount = $null; Status = 'Partial' }
        }

        Write-FKAction -Action $ActionName -Target $Source -Detail ('{0} → {1} 筆事件' -f $r.CommandLine, $count) -Status 'OK'
        return [pscustomobject]@{ Path = $OutFile; EventCount = $count; Status = 'OK' }
    }

    function ConvertTo-FKEventLogResult {
        param([string]$Channel, [string]$Source, $Path, $EventCount, [string]$Status)
        return [pscustomobject]@{
            Channel    = $Channel
            Source     = $Source
            Path       = $Path
            EventCount = $EventCount
            Status     = $Status
        }
    }

    # ---- 參數檢查（參數錯誤才 throw） ----

    $StartUtc = ConvertTo-FKUtcKind -Date $StartUtc
    $EndUtc = ConvertTo-FKUtcKind -Date $EndUtc
    if ($StartUtc -gt $EndUtc) {
        throw ("StartUtc（{0}）晚於 EndUtc（{1}）。" -f (ConvertTo-FKIsoUtc -Date $StartUtc), (ConvertTo-FKIsoUtc -Date $EndUtc))
    }

    $config = $null
    if (-not $PSBoundParameters.ContainsKey('Channels') -or $IncludeVault) {
        $config = Get-FKConfig
    }
    if (-not $PSBoundParameters.ContainsKey('Channels')) {
        $Channels = @($config.channels | ForEach-Object { [string]$_ })
    }
    $Channels = @($Channels | Select-Object -Unique)

    $liveDir = Join-Path $Destination 'live'
    if (-not (Test-Path -LiteralPath $liveDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $liveDir -Force -ErrorAction Stop
    }

    # wevtutil 的 XPath 需要毫秒格式（yyyy-MM-ddTHH:mm:ss.fffZ）。事件時間精度是 100 奈秒，
    # 為了不漏掉邊界上的事件：起點捨去到毫秒、終點無條件進位到下一個毫秒（寧可多收不足 1 毫秒的事件）。
    $isoMs = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $subMs = $EndUtc.Ticks % [TimeSpan]::TicksPerMillisecond
    $queryEnd = $EndUtc
    if ($subMs -ne 0) { $queryEnd = $EndUtc.AddTicks([TimeSpan]::TicksPerMillisecond - $subMs) }
    $query = "*[System[TimeCreated[@SystemTime>='{0}' and @SystemTime<='{1}']]]" -f $StartUtc.ToString($isoMs, $inv), $queryEnd.ToString($isoMs, $inv)

    # ---- 現行 log ----

    foreach ($channel in $Channels) {
        $gl = Invoke-FKWevtutil -ArgumentList @('gl', $channel)
        if ($gl.ExitCode -eq 15007) {
            Write-FKAction -Action 'ExportEventLog' -Target $channel -Detail ('{0} → exit 15007：channel 不存在，略過' -f $gl.CommandLine) -Status 'Skipped'
            ConvertTo-FKEventLogResult -Channel $channel -Source 'Live' -Path $null -EventCount $null -Status 'Skipped'
            continue
        }

        $outFile = Join-Path $liveDir ((ConvertTo-FKSafeChannelName -Channel $channel) + '.evtx')
        $one = Export-FKEvtxFile -ActionName 'ExportEventLog' -Source $channel -OutFile $outFile
        ConvertTo-FKEventLogResult -Channel $channel -Source 'Live' -Path $one.Path -EventCount $one.EventCount -Status $one.Status
    }

    if (-not $IncludeVault) { return }

    # ---- Vault ----

    $vaultRoot = [string]$config.preservation.vaultRoot
    $vaultOutRoot = Join-Path $Destination 'vault'
    $margin = [TimeSpan]::FromMinutes(60)
    $nameFormat = "yyyyMMdd'T'HHmmss'Z'"
    $nameStyles = [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal'

    foreach ($channel in $Channels) {
        $safeName = ConvertTo-FKSafeChannelName -Channel $channel
        $channelVault = Join-Path $vaultRoot $safeName
        $backups = @()
        if (Test-Path -LiteralPath $channelVault -PathType Container) {
            $backups = @(Get-ChildItem -LiteralPath $channelVault -Filter '*.evtx' -File -ErrorAction SilentlyContinue)
        }
        if ($backups.Count -eq 0) {
            Write-FKAction -Action 'ExportVaultEventLog' -Target $channel -Detail ('vault 中沒有備份：{0}' -f $channelVault) -Status 'Skipped'
            ConvertTo-FKEventLogResult -Channel $channel -Source 'Vault' -Path $null -EventCount $null -Status 'Skipped'
            continue
        }

        # 依檔名時間排序；檔名不符格式的備份無法判斷時間，一律匯出
        # （PS 5.1 的單一 pscustomobject 沒有 .Count，所以整串用 @() 包起來）
        $items = @(@(foreach ($file in $backups) {
                    $parsed = [datetime]::MinValue
                    $time = $null
                    if ([datetime]::TryParseExact($file.BaseName, $nameFormat, $inv, $nameStyles, [ref]$parsed)) { $time = $parsed }
                    [pscustomobject]@{ File = $file; Time = $time }
                }) | Sort-Object -Property @{ Expression = { if ($_.Time) { $_.Time } else { [datetime]::MinValue } } }, @{ Expression = { $_.File.Name } })

        $channelOutDir = Join-Path $vaultOutRoot $safeName
        $exported = New-Object System.Collections.Generic.List[object]
        $skipped = 0
        $previousTime = $null
        foreach ($item in $items) {
            $tooOld = ($item.Time -and ($item.Time + $margin) -lt $StartUtc)
            $tooNew = ($previousTime -and ($previousTime - $margin) -gt $EndUtc)
            if ($item.Time) { $previousTime = $item.Time }
            if ($tooOld -or $tooNew) { $skipped++; continue }

            if (-not (Test-Path -LiteralPath $channelOutDir -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $channelOutDir -Force -ErrorAction Stop
            }
            $outFile = Join-Path $channelOutDir $item.File.Name
            $exported.Add((Export-FKEvtxFile -ActionName 'ExportVaultEventLog' -Source $item.File.FullName -OutFile $outFile -LogFile))
        }

        if ($skipped -gt 0) {
            Write-FKAction -Action 'ExportVaultEventLog' -Target $channel -Detail ('依備份時間略過 {0} 份不含此時段的備份（共 {1} 份）' -f $skipped, $items.Count) -Status 'OK'
        }

        if ($exported.Count -eq 0) {
            ConvertTo-FKEventLogResult -Channel $channel -Source 'Vault' -Path $null -EventCount 0 -Status 'OK'
            continue
        }

        $ok = @($exported | Where-Object { $_.Status -eq 'OK' }).Count
        $failed = @($exported | Where-Object { $_.Status -eq 'Failed' }).Count
        if ($ok -eq $exported.Count) { $status = 'OK' }
        elseif ($failed -eq $exported.Count) { $status = 'Failed' }
        else { $status = 'Partial' }

        $counted = @($exported | Where-Object { $null -ne $_.EventCount })
        $total = $null
        if ($counted.Count -gt 0) { $total = [int](($counted | Measure-Object -Property EventCount -Sum).Sum) }

        $outPath = $null
        if (Test-Path -LiteralPath $channelOutDir -PathType Container) { $outPath = $channelOutDir }
        ConvertTo-FKEventLogResult -Channel $channel -Source 'Vault' -Path $outPath -EventCount $total -Status $status
    }
}
