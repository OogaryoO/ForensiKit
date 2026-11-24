# GUI（T10）用的內部函式：不含任何 WinForms 程式碼，方便單元測試。

function ConvertFrom-FKTaipeiTime {
    <#
    .SYNOPSIS
        把操作者輸入的台灣時間（UTC+8）轉成 Kind = Utc 的 [datetime]。

    .DESCRIPTION
        台灣沒有日光節約時間，固定以 +08:00 換算，不受執行電腦時區設定影響。
        輸入的 Kind 會被忽略（DateTimePicker 回傳 Unspecified 或 Local），只取年月日時分秒。

    .PARAMETER Date
        台灣時間。

    .EXAMPLE
        ConvertFrom-FKTaipeiTime -Date ([datetime]'2026-11-20 11:15')   # 2026-11-20T03:15:00Z
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    $wallClock = [datetime]::SpecifyKind($Date, [System.DateTimeKind]::Unspecified)
    $offset = New-Object System.DateTimeOffset($wallClock, [timespan]::FromHours(8))
    return $offset.UtcDateTime
}

function ConvertTo-FKTaipeiTime {
    <#
    .SYNOPSIS
        把 UTC 時間轉成台灣時間（UTC+8），回傳 Kind = Unspecified 的 [datetime]，供 GUI 顯示。

    .PARAMETER Date
        UTC 時間（Kind = Local 時會先轉成 UTC）。

    .EXAMPLE
        ConvertTo-FKTaipeiTime -Date ([datetime]::UtcNow)
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    if ($Date.Kind -eq [System.DateTimeKind]::Local) { $Date = $Date.ToUniversalTime() }
    return [datetime]::SpecifyKind($Date.AddHours(8), [System.DateTimeKind]::Unspecified)
}

function Get-FKDefaultOutputRoot {
    <#
    .SYNOPSIS
        決定 GUI 的預設輸出位置：優先選擇剩餘空間最大的卸除式磁碟（隨身碟）。

    .DESCRIPTION
        回傳 {Path, IsRemovable, Note}。找不到卸除式磁碟時改用目前使用者的桌面，並在 Note 提醒：
        寫入本機磁碟會改動被調查電腦的磁碟內容，正式蒐證請插入隨身碟。

    .EXAMPLE
        (Get-FKDefaultOutputRoot).Path
    #>
    [CmdletBinding()]
    param()

    $drives = @()
    try {
        $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop |
                Where-Object { $_.FreeSpace -gt 0 } |
                Sort-Object -Property FreeSpace -Descending)
    }
    catch {
        Write-Verbose "無法列出卸除式磁碟：$($_.Exception.Message)"
    }

    if ($drives.Count -gt 0) {
        $d = $drives[0]
        return [pscustomobject]@{
            Path        = "$($d.DeviceID)\"
            IsRemovable = $true
            Note        = ('已選擇隨身碟 {0}（剩餘 {1:N1} GB）' -f $d.DeviceID, ($d.FreeSpace / 1GB))
        }
    }

    return [pscustomobject]@{
        Path        = [Environment]::GetFolderPath('Desktop')
        IsRemovable = $false
        Note        = '未偵測到隨身碟，暫時存到桌面。正式蒐證請插入隨身碟後按「瀏覽」重新選擇（寫入本機會改動被調查電腦的磁碟）。'
    }
}

function Test-FKGuiInput {
    <#
    .SYNOPSIS
        檢查 GUI 輸入，回傳錯誤訊息陣列；沒有錯誤時回傳空陣列。

    .PARAMETER CaseId
        案號；會成為證據包資料夾名稱的一部分，只允許英數字、點、底線、連字號。

    .PARAMETER Operator
        操作者姓名。

    .PARAMETER StartUtc
        匯出時段起點（UTC）。

    .PARAMETER EndUtc
        匯出時段終點（UTC）。

    .PARAMETER OutputRoot
        輸出位置，必須是已存在的資料夾。

    .PARAMETER NoEncrypt
        不加密；此時不檢查密碼。

    .PARAMETER Password
        加密密碼（明文，只在記憶體中比對）。

    .PARAMETER ConfirmPassword
        再次輸入的密碼。

    .PARAMETER NowUtc
        目前時間（測試用）；省略時用 [datetime]::UtcNow。

    .EXAMPLE
        $errors = Test-FKGuiInput -CaseId '2026-001' -Operator '王小明' -StartUtc $s -EndUtc $e -OutputRoot 'E:\' -NoEncrypt
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'WinForms TextBox 只提供明文；只在記憶體中比對長度與一致性，之後立即轉成 SecureString')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'ConfirmPassword', Justification = '同上')]
    param(
        [AllowEmptyString()][string]$CaseId,
        [AllowEmptyString()][string]$Operator,
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [AllowEmptyString()][string]$OutputRoot,
        [switch]$NoEncrypt,
        [AllowEmptyString()][string]$Password,
        [AllowEmptyString()][string]$ConfirmPassword,
        [Nullable[datetime]]$NowUtc
    )

    if ($null -eq $NowUtc) { $NowUtc = [datetime]::UtcNow }
    $errors = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($CaseId)) { $errors.Add('請輸入案號。') }
    elseif ($CaseId -notmatch '^[A-Za-z0-9._-]{1,40}$') { $errors.Add('案號只能使用英文字母、數字、點、底線或連字號（最多 40 字），例如 2026-001。') }

    if ([string]::IsNullOrWhiteSpace($Operator)) { $errors.Add('請輸入操作者姓名。') }
    elseif ($Operator.Length -gt 50) { $errors.Add('操作者姓名最多 50 字。') }

    if ($StartUtc -ge $EndUtc) { $errors.Add('開始時間必須早於結束時間。') }
    if ($EndUtc -gt $NowUtc.AddMinutes(5)) { $errors.Add('結束時間不能晚於現在。') }

    if ([string]::IsNullOrWhiteSpace($OutputRoot) -or -not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        $errors.Add('輸出位置不存在，請按「瀏覽」選擇隨身碟或資料夾。')
    }

    if (-not $NoEncrypt) {
        if ([string]::IsNullOrEmpty($Password) -or $Password.Length -lt 8) { $errors.Add('密碼至少 8 個字元（或勾選「不加密」）。') }
        elseif ($Password -cne $ConfirmPassword) { $errors.Add('兩次輸入的密碼不一致。') }
    }

    return $errors.ToArray()
}

function Get-FKDemoResult {
    <#
    .SYNOPSIS
        DEMO 模式用的假 Invoke-ForensiKit 結果（契約第 7 節格式），讓 GUI 在 T09 完成前可以開發與展示。

    .DESCRIPTION
        只有設定環境變數 FK_GUI_DEMO=1 時，GUI 才會呼叫本函式。不會建立任何檔案；
        ManifestSha256 是隨機值，畫面會標示「DEMO：非真實證據」。

    .PARAMETER CaseId
        案號。

    .PARAMETER Operator
        操作者。

    .PARAMETER StartUtc
        時段起點（UTC）。

    .PARAMETER EndUtc
        時段終點（UTC）。

    .PARAMETER OutputRoot
        輸出位置。

    .PARAMETER Password
        密碼（DEMO 模式不使用，只為了與 Invoke-ForensiKit 參數一致）。

    .PARAMETER NoEncrypt
        不加密。

    .PARAMETER DelaySeconds
        模擬執行時間（秒）。

    .EXAMPLE
        Get-FKDemoResult -CaseId '2026-001' -Operator 'demo' -StartUtc $s -EndUtc $e -OutputRoot 'E:\' -NoEncrypt -DelaySeconds 0
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Operator', Justification = '與 Invoke-ForensiKit 參數一致')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'StartUtc', Justification = '與 Invoke-ForensiKit 參數一致')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EndUtc', Justification = '與 Invoke-ForensiKit 參數一致')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Password', Justification = '與 Invoke-ForensiKit 參數一致')]
    param(
        [string]$CaseId,
        [string]$Operator,
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [string]$OutputRoot,
        [System.Security.SecureString]$Password,
        [switch]$NoEncrypt,
        [int]$DelaySeconds = 3
    )

    if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    $stamp = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $root = Join-Path $OutputRoot ('FK_{0}_{1}_{2}' -f $CaseId, $env:COMPUTERNAME, $stamp)
    $bytes = New-Object byte[] 32
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sha = -join ($bytes | ForEach-Object { $_.ToString('x2') })

    $packagePath = $null
    if (-not $NoEncrypt) { $packagePath = "$root.fkpkg" }

    return [pscustomobject]@{
        PackageRoot    = $root
        PackagePath    = $packagePath
        ManifestSha256 = $sha
        Results        = @(
            [pscustomobject]@{ Channel = 'Security'; Source = 'Live'; Path = 'evtx/live/Security.evtx'; EventCount = 1234; Status = 'OK' }
            [pscustomobject]@{ Channel = 'Microsoft-Windows-Sysmon/Operational'; Source = 'Live'; Path = $null; EventCount = 0; Status = 'Skipped' }
            [pscustomobject]@{ Name = 'Processes'; Path = 'artifacts/processes.json'; ItemCount = 187; Status = 'OK' }
        )
        DurationSec    = $DelaySeconds
        Status         = 'OK'
    }
}

function Format-FKHashForDisplay {
    <#
    .SYNOPSIS
        把 SHA-256 每 4 個字元分一組（16 組，兩行），方便操作者抄寫到監管鏈表單。

    .PARAMETER Hash
        64 字元的十六進位雜湊值。

    .EXAMPLE
        Format-FKHashForDisplay -Hash ('ab' * 32)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Hash
    )

    $groups = [regex]::Matches($Hash.ToLowerInvariant(), '.{1,4}') | ForEach-Object { $_.Value }
    if (@($groups).Count -le 8) { return ($groups -join ' ') }
    return (($groups[0..7] -join ' ') + [Environment]::NewLine + ($groups[8..($groups.Count - 1)] -join ' '))
}
