function Invoke-ForensiKit {
    <#
    .SYNOPSIS
        一鍵蒐證：建立證據包、依時段匯出事件記錄、產生 manifest 與監管鏈表單。

    .DESCRIPTION
        主流程（TASKS.md T09）：
          1. 檢查參數與管理員權限（不符就 throw，不建立任何檔案）
          2. 在 OutputRoot 下建立 FK_<CaseId>_<ComputerName>_<yyyyMMddTHHmmssZ>（docs/ARCHITECTURE.md 第 4 節）
          3. 開始 action log（Open-FKActionLog），記錄案號、操作者與時段
          4. Export-FKEventLog -IncludeVault：設定檔（Get-FKConfig）中所有 channel 的指定時段 → <PackageRoot>\evtx\live\，
             vault 備份中同一時段的事件 → <PackageRoot>\evtx\vault\（尚未安裝常駐保全時 vault 結果為 Skipped）
          5. Get-FKArtifact：7 種 artifact → <PackageRoot>\artifacts\
          6. New-FKManifest：manifest.json 與 chain_of_custody.txt；之後立刻結束 action log
          7. 除非 -NoEncrypt：Protect-FKPackage 產生 <PackageRoot>.fkpkg（在 action log 關閉之後，docs/ARCHITECTURE.md 第 4 節）
        任何步驟 Failed 或 Partial 時整體 Status = 'Partial'，仍會產出 manifest；manifest 本身失敗時 Status = 'Failed'。
        Skipped（例如沒裝 Sysmon、沒有 vault）不影響整體狀態。

        加密（契約第 4 節的 manifest 規則）：
          - 要加密時，在產生 manifest 之前先寫一筆 EncryptPackage（detail 註明「將於 manifest 之後加密」），
            加密本身在 manifest 與 Close-FKActionLog 之後執行，不寫入證據包內的 action log。
          - 加密結果只出現在回傳值：成功時 PackagePath 為 .fkpkg 路徑，Results 多一筆 Name = 'EncryptPackage'；
            失敗時 PackagePath = $null、該筆 Status = 'Failed'、整體 Status 至少為 'Partial'（明文證據包仍保留）。
          - 明文證據包目錄會保留（不使用 -RemovePlaintext），由操作者依 SOP 決定是否刪除。
          - -NoEncrypt：不加密，PackagePath = $null。兩者都沒有：throw（參數錯誤）。

    .PARAMETER CaseId
        案號。用於證據包目錄名稱（檔名不允許的字元與 [ ] 會換成 _）與 manifest。

    .PARAMETER Operator
        操作者姓名。

    .PARAMETER StartUtc
        蒐證時段起點（UTC）。Kind = Local 的時間會先轉成 UTC；Kind = Unspecified 視為 UTC。

    .PARAMETER EndUtc
        蒐證時段終點（UTC）。不得早於 StartUtc。

    .PARAMETER OutputRoot
        證據包要放的位置（例如隨身碟根目錄），必須已存在。

    .PARAMETER Password
        加密證據包用的密碼（Protect-FKPackage）。請另行安全地交給接收方。

    .PARAMETER NoEncrypt
        不加密證據包。

    .OUTPUTS
        [pscustomobject] @{ PackageRoot; PackagePath; ManifestSha256; Results; DurationSec; Status }

    .EXAMPLE
        $start = [datetime]::SpecifyKind([datetime]'2026-11-20 00:00:00', 'Utc')
        $end   = [datetime]::SpecifyKind([datetime]'2026-11-21 00:00:00', 'Utc')
        Invoke-ForensiKit -CaseId '2026-001' -Operator '王小明' -StartUtc $start -EndUtc $end -OutputRoot 'E:\' -NoEncrypt
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CaseId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Operator,

        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputRoot,

        [Parameter()]
        [System.Security.SecureString]$Password,

        [Parameter()]
        [switch]$NoEncrypt
    )

    function ConvertTo-FKUtcKind {
        param([datetime]$Date)
        if ($Date.Kind -eq [System.DateTimeKind]::Local) { return $Date.ToUniversalTime() }
        return [datetime]::SpecifyKind($Date, [System.DateTimeKind]::Utc)
    }

    # ---- 參數與權限檢查（不符就 throw，尚未建立任何檔案） ----

    $StartUtc = ConvertTo-FKUtcKind -Date $StartUtc
    $EndUtc = ConvertTo-FKUtcKind -Date $EndUtc
    if ($StartUtc -gt $EndUtc) {
        throw ("StartUtc（{0}）晚於 EndUtc（{1}）。" -f (ConvertTo-FKIsoUtc -Date $StartUtc), (ConvertTo-FKIsoUtc -Date $EndUtc))
    }
    if (-not $NoEncrypt -and -not $Password) {
        throw '請指定 -Password（加密證據包）或 -NoEncrypt（不加密）。'
    }
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        throw "輸出位置不存在：$OutputRoot"
    }
    Assert-FKAdmin

    # ---- 建立證據包 ----

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stamp = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $safeCaseId = $CaseId
    foreach ($ch in ([System.IO.Path]::GetInvalidFileNameChars() + [char[]]'[]')) { $safeCaseId = $safeCaseId.Replace([string]$ch, '_') }
    $outRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $packageRoot = Join-Path $outRoot ('FK_{0}_{1}_{2}' -f $safeCaseId, $env:COMPUTERNAME, $stamp)
    $null = New-Item -ItemType Directory -Path $packageRoot -ErrorAction Stop

    $results = New-Object System.Collections.Generic.List[object]
    $manifestSha = $null
    $status = 'OK'
    $previousLog = Get-FKActionLogPath
    $null = Open-FKActionLog -PackageRoot $packageRoot
    try {
        Write-FKAction -Action 'StartCollection' -Target $packageRoot -Detail ('案號={0}；操作者={1}；時段={2} ～ {3}；電腦={4}' -f $CaseId, $Operator, (ConvertTo-FKIsoUtc -Date $StartUtc), (ConvertTo-FKIsoUtc -Date $EndUtc), $env:COMPUTERNAME) -Status 'OK'

        # 單一步驟失敗不中斷，仍要產出 manifest（契約第 3 節、TASKS.md T09）
        try {
            foreach ($r in @(Export-FKEventLog -StartUtc $StartUtc -EndUtc $EndUtc -Destination (Join-Path $packageRoot 'evtx') -IncludeVault)) {
                $results.Add($r)
            }
        }
        catch {
            Write-FKAction -Action 'ExportEventLog' -Target 'evtx' -Detail ('Export-FKEventLog 發生錯誤：{0}' -f $_.Exception.Message) -Status 'Failed'
            $results.Add([pscustomobject]@{ Channel = '*'; Source = 'Live'; Path = $null; EventCount = $null; Status = 'Failed' })
        }

        try {
            foreach ($r in @(Get-FKArtifact -StartUtc $StartUtc -EndUtc $EndUtc -Destination (Join-Path $packageRoot 'artifacts'))) {
                $results.Add($r)
            }
        }
        catch {
            Write-FKAction -Action 'CollectArtifact' -Target 'artifacts' -Detail ('Get-FKArtifact 發生錯誤：{0}' -f $_.Exception.Message) -Status 'Failed'
            $results.Add([pscustomobject]@{ Name = '*'; Path = $null; ItemCount = $null; Status = 'Failed' })
        }

        if (-not $NoEncrypt) {
            # 加密在 manifest 與關閉 action log 之後執行，結果無法再寫進證據包內的 action log，所以先記錄意圖（#28 第 4 節）
            Write-FKAction -Action 'EncryptPackage' -Target ($packageRoot + '.fkpkg') -Detail '將於 manifest 之後以 Protect-FKPackage 加密（Deflate + AES-256-CBC + HMAC-SHA256），結果見回傳值 PackagePath' -Status 'OK'
        }

        foreach ($r in $results) {
            if ($r.Status -eq 'Failed' -or $r.Status -eq 'Partial') { $status = 'Partial' }
        }

        # manifest 會把 action_log.jsonl 一起雜湊，所以之後不可再寫 action log
        try {
            $manifest = New-FKManifest -PackageRoot $packageRoot -CaseId $CaseId -Operator $Operator -StartUtc $StartUtc -EndUtc $EndUtc
            $manifestSha = $manifest.ManifestSha256
        }
        catch {
            Write-Warning ("無法產生 manifest：{0}" -f $_.Exception.Message)
            $status = 'Failed'
        }
    }
    finally {
        if ($previousLog) { $null = Open-FKActionLog -PackageRoot (Split-Path -Path $previousLog -Parent) }
        else { Close-FKActionLog }
    }

    # ---- 加密（action log 已關閉） ----

    $packagePath = $null
    if (-not $NoEncrypt) {
        try {
            $enc = Protect-FKPackage -PackageRoot $packageRoot -Password $Password
            $packagePath = $enc.PackagePath
            $results.Add([pscustomobject]@{ Name = 'EncryptPackage'; Path = $packagePath; ItemCount = $null; Status = 'OK' })
        }
        catch {
            Write-Warning ("加密失敗，明文證據包仍保留在 {0}：{1}" -f $packageRoot, $_.Exception.Message)
            $results.Add([pscustomobject]@{ Name = 'EncryptPackage'; Path = $null; ItemCount = $null; Status = 'Failed' })
            if ($status -eq 'OK') { $status = 'Partial' }
        }
    }
    $stopwatch.Stop()

    return [pscustomobject]@{
        PackageRoot    = $packageRoot
        PackagePath    = $packagePath
        ManifestSha256 = $manifestSha
        Results        = $results.ToArray()
        DurationSec    = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        Status         = $status
    }
}
