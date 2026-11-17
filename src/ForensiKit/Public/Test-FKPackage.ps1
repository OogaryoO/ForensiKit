function Test-FKPackage {
    <#
    .SYNOPSIS
        依 manifest.json 重算證據包中所有檔案的 SHA-256，回報不一致、遺失與多出的檔案（AC6）。

    .DESCRIPTION
        對 manifest.json 的每一筆 files：
          - 檔案不存在 → Missing
          - SHA-256（不分大小寫）或大小與 manifest 不同 → Mismatched
          - manifest 中沒有雜湊（收集時無法讀取）、或路徑指向證據包外面（絕對路徑、..）→ Mismatched
        證據包中有、但 manifest 沒列的檔案 → Extra。manifest.json 與 chain_of_custody.txt 是預期存在的檔案，不算 Extra。
        若有 chain_of_custody.txt，也比對其中記錄的 manifest SHA-256；不同時 manifest.json 列為 Mismatched
        （可偵測「同時竄改檔案與 manifest」）。
        manifest.json 不存在 → Missing 含 manifest.json；不是合法 JSON → Mismatched 含 manifest.json。兩者都回傳 IsValid = $false，不 throw。
        清單中的路徑一律是相對於證據包根目錄、以 / 分隔（與 manifest 相同）。

        本函式只讀取證據包。若目前開啟的 action log 位於這個證據包內，不寫 action log（避免改到受驗證的 action_log.jsonl）。

    .PARAMETER PackageRoot
        證據包根目錄（解密後的資料夾）。

    .OUTPUTS
        [pscustomobject] @{ IsValid <bool>; Mismatched <string[]>; Missing <string[]>; Extra <string[]> }

    .EXAMPLE
        $r = Test-FKPackage -PackageRoot 'E:\FK_2026-001_WIN11-TEST_20261121T020304Z'
        if (-not $r.IsValid) { $r.Mismatched; $r.Missing; $r.Extra }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot
    )

    function Get-FKFileSha256 {
        param([string]$Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { return (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })) }
        finally { $stream.Dispose(); $sha.Dispose() }
    }

    function ConvertTo-FKSortedArray {
        # 逗號運算子讓空陣列也以 string[] 回傳（否則 PowerShell 會把它展開成 $null）
        param($List)
        return , ([string[]]@($List | Sort-Object -Unique))
    }

    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "證據包目錄不存在：$PackageRoot"
    }
    $root = (Resolve-Path -LiteralPath $PackageRoot).ProviderPath.TrimEnd('\')
    $rootPrefix = $root + '\'
    $manifestPath = Join-Path $root 'manifest.json'
    $cocPath = Join-Path $root 'chain_of_custody.txt'

    $mismatched = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $extra = New-Object System.Collections.Generic.List[string]
    $listed = @{}   # 不分大小寫（Windows 檔案系統）

    $manifest = $null
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $missing.Add('manifest.json')
    }
    else {
        try {
            $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if (-not $manifest -or $manifest.PSObject.Properties.Name -notcontains 'files') { throw 'manifest 沒有 files 欄位' }
        }
        catch {
            $manifest = $null
            $mismatched.Add('manifest.json')
        }
    }

    if ($manifest) {
        foreach ($f in @($manifest.files)) {
            if (-not $f) { continue }
            $rel = [string]$f.path
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $listed[$rel] = $true

            # 只允許證據包內的相對路徑
            $full = $null
            try {
                if (-not [System.IO.Path]::IsPathRooted($rel)) {
                    $full = [System.IO.Path]::GetFullPath((Join-Path $root ($rel -replace '/', '\')))
                }
            }
            catch { $full = $null }
            if (-not $full -or -not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $mismatched.Add($rel)
                continue
            }

            if (-not [System.IO.File]::Exists($full)) {
                $missing.Add($rel)
                continue
            }
            $expected = [string]$f.sha256
            if ([string]::IsNullOrWhiteSpace($expected)) {
                $mismatched.Add($rel)
                continue
            }
            try {
                $actual = Get-FKFileSha256 -Path $full
                $sizeOk = $true
                if ($null -ne $f.size) { $sizeOk = ([long]$f.size -eq (New-Object System.IO.FileInfo $full).Length) }
                if (-not $sizeOk -or -not [string]::Equals($actual, $expected.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mismatched.Add($rel)
                }
            }
            catch {
                $mismatched.Add($rel)
            }
        }

        # chain_of_custody.txt 記錄的 manifest 雜湊
        if (Test-Path -LiteralPath $cocPath -PathType Leaf) {
            $coc = [System.IO.File]::ReadAllText($cocPath, [System.Text.Encoding]::UTF8)
            $m = [regex]::Match($coc, 'manifest\.json SHA-256\S*\s*([0-9a-fA-F]{64})')
            if ($m.Success) {
                $manifestSha = Get-FKFileSha256 -Path $manifestPath
                if (-not [string]::Equals($manifestSha, $m.Groups[1].Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mismatched.Add('manifest.json')
                }
            }
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
        if ($rel -eq 'manifest.json' -or $rel -eq 'chain_of_custody.txt') { continue }
        if (-not $listed.ContainsKey($rel)) { $extra.Add($rel) }
    }

    $isValid = ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0)

    $openLog = Get-FKActionLogPath
    if (-not ($openLog -and $openLog.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        $status = 'OK'
        if (-not $isValid) { $status = 'Failed' }
        Write-FKAction -Action 'VerifyPackage' -Target $root -Detail ('IsValid={0}；Mismatched={1}；Missing={2}；Extra={3}' -f $isValid, $mismatched.Count, $missing.Count, $extra.Count) -Status $status
    }

    return [pscustomobject]@{
        IsValid    = [bool]$isValid
        Mismatched = (ConvertTo-FKSortedArray $mismatched)
        Missing    = (ConvertTo-FKSortedArray $missing)
        Extra      = (ConvertTo-FKSortedArray $extra)
    }
}
