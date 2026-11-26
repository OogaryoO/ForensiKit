function Unprotect-FKPackage {
    <#
    .SYNOPSIS
        驗證並解密 .fkpkg，還原成證據包目錄。

    .DESCRIPTION
        格式見 Protect-FKPackage 與 docs/ARCHITECTURE.md。步驟：
          1. 讀檔頭（魔術字、版本、KDF、迭代次數、salt、IV），格式不符或檔案太短 → throw
          2. 以密碼推導金鑰，對「檔頭 ‖ 密文」計算 HMAC-SHA256，與檔頭後的 HMAC 欄位比對（固定時間比較）。
             不一致 → throw「密碼錯誤，或檔案已損毀／遭竄改」，此時**不會在 Destination 建立任何檔案或目錄**。
          3. HMAC 通過後才解密：密文 → AES → Deflate → 逐筆讀出記錄，寫到 Destination 下的暫存目錄；
             全部成功才改名為 <Destination>\<.fkpkg 檔名去掉副檔名>。任何一步失敗都會刪除暫存目錄並 throw。
        還原時逐筆檢查路徑：拒絕 ..、絕對路徑、磁碟代號或 :、反斜線、空的路徑片段與重複路徑，
        並確認完整路徑落在暫存目錄之內，避免把檔案寫到目的地之外。
        還原後可用 Test-FKPackage 驗證每個檔案的雜湊。

    .PARAMETER Path
        加密檔（.fkpkg）的路徑。

    .PARAMETER Password
        加密時使用的密碼。

    .PARAMETER Destination
        還原到的目錄（驗證通過後才建立）。證據包目錄會建立在它底下，已存在時 throw，不覆寫。

    .OUTPUTS
        [pscustomobject] @{ PackageRoot }

    .EXAMPLE
        $pw = Read-Host -AsSecureString '證據包密碼'
        $r = Unprotect-FKPackage -Path 'E:\FK_2026-001_WIN11-TEST_20261121T020304Z.fkpkg' -Password $pw -Destination 'D:\Cases'
        Test-FKPackage -PackageRoot $r.PackageRoot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Password,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression

    $headerLength = 43
    $macLength = 32
    $dataOffset = $headerLength + $macLength

    function Get-FKPasswordByte {
        param([System.Security.SecureString]$Secure)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { return , [System.Text.Encoding]::UTF8.GetBytes([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    function Test-FKSafeRelativePath {
        # 只接受「a/b/c」形式的相對路徑
        param([string]$Rel)
        if ([string]::IsNullOrEmpty($Rel)) { return $false }
        if ($Rel.Contains('\') -or $Rel.Contains(':') -or $Rel.StartsWith('/')) { return $false }
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        foreach ($seg in $Rel.Split('/')) {
            if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { return $false }
            if ($seg.IndexOfAny($invalid) -ge 0) { return $false }
        }
        return $true
    }

    function Read-FKExact {
        # 從串流讀滿 Count 個位元組；不足表示資料被截斷
        param([System.IO.Stream]$Stream, [int]$Count)
        $buf = New-Object byte[] $Count
        $off = 0
        while ($off -lt $Count) {
            $n = $Stream.Read($buf, $off, $Count - $off)
            if ($n -le 0) { throw '加密內容不完整（記錄被截斷）。' }
            $off += $n
        }
        return , $buf
    }

    # ---- 1. 檔頭 ----

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到加密檔：$Path" }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $fileLength = (New-Object System.IO.FileInfo $full).Length
    if ($fileLength -lt ($dataOffset + 16)) { throw "不是有效的 .fkpkg，或檔案已被截斷：$full" }

    $head = New-Object byte[] $dataOffset
    $fs = [System.IO.File]::OpenRead($full)
    try { if ($fs.Read($head, 0, $dataOffset) -ne $dataOffset) { throw "無法讀取檔頭：$full" } }
    finally { $fs.Dispose() }

    if ([System.Text.Encoding]::ASCII.GetString($head, 0, 5) -ne 'FKPKG') { throw "不是 .fkpkg 檔（魔術字不符）：$full" }
    if ($head[5] -ne 1) { throw "不支援的 .fkpkg 格式版本：$($head[5])" }
    if ($head[6] -ne 1) { throw "不支援的金鑰推導演算法：$($head[6])" }
    $iterations = [System.BitConverter]::ToUInt32($head, 7)
    if ($iterations -lt 100000 -or $iterations -gt 10000000) { throw "檔頭的 PBKDF2 迭代次數不合理（$iterations），檔案可能遭竄改。" }
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    [Array]::Copy($head, 11, $salt, 0, 16)
    [Array]::Copy($head, 27, $iv, 0, 16)
    if ((($fileLength - $dataOffset) % 16) -ne 0) { throw "密文長度不正確，檔案可能已被截斷或竄改：$full" }

    # ---- 2. 金鑰與 HMAC 驗證（通過前不寫任何檔案） ----

    $pwBytes = Get-FKPasswordByte -Secure $Password
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes -ArgumentList $pwBytes, $salt, ([int]$iterations), ([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $keyMaterial = $kdf.GetBytes(64) }
    finally { $kdf.Dispose(); [Array]::Clear($pwBytes, 0, $pwBytes.Length) }
    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    [Array]::Copy($keyMaterial, 0, $encKey, 0, 32)
    [Array]::Copy($keyMaterial, 32, $macKey, 0, 32)
    [Array]::Clear($keyMaterial, 0, $keyMaterial.Length)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $macKey)
    $fs = [System.IO.File]::OpenRead($full)
    try {
        [void]$hmac.TransformBlock($head, 0, $headerLength, $null, 0)
        [void]$fs.Seek($dataOffset, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] 1048576
        while (($n = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) { [void]$hmac.TransformBlock($buffer, 0, $n, $null, 0) }
        [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $diff = 0
        for ($i = 0; $i -lt $macLength; $i++) { $diff = $diff -bor ($head[$headerLength + $i] -bxor $hmac.Hash[$i]) }
    }
    finally {
        $fs.Dispose()
        $hmac.Dispose()
        [Array]::Clear($macKey, 0, $macKey.Length)
    }
    if ($diff -ne 0) {
        [Array]::Clear($encKey, 0, $encKey.Length)
        throw '密碼錯誤，或檔案已損毀／遭竄改（HMAC 驗證失敗），未輸出任何檔案。'
    }

    # ---- 3. 解密 → 解壓 → 逐筆寫到暫存目錄 → 改名 ----

    $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop
    }
    $destFull = (Resolve-Path -LiteralPath $Destination).ProviderPath.TrimEnd('\')
    $packageRoot = Join-Path $destFull $name
    if (Test-Path -LiteralPath $packageRoot) {
        [Array]::Clear($encKey, 0, $encKey.Length)
        throw "目的地已有同名的證據包，不覆寫：$packageRoot"
    }
    $staging = Join-Path $destFull ('.' + $name + '.partial')
    $stagingPrefix = $staging + '\'

    $aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $encKey
    $aes.IV = $iv
    [Array]::Clear($encKey, 0, $encKey.Length)

    $done = $false
    $count = 0
    $src = $null; $dec = $null; $inflate = $null
    try {
        $null = New-Item -ItemType Directory -Path $staging -ErrorAction Stop
        $src = [System.IO.File]::OpenRead($full)
        [void]$src.Seek($dataOffset, [System.IO.SeekOrigin]::Begin)
        $dec = New-Object System.Security.Cryptography.CryptoStream -ArgumentList $src, $aes.CreateDecryptor(), ([System.Security.Cryptography.CryptoStreamMode]::Read)
        $inflate = New-Object System.IO.Compression.DeflateStream -ArgumentList $dec, ([System.IO.Compression.CompressionMode]::Decompress)

        $seen = @{}
        $buffer = New-Object byte[] 1048576
        while ($true) {
            $pathLength = [System.BitConverter]::ToUInt16((Read-FKExact -Stream $inflate -Count 2), 0)
            if ($pathLength -eq 0) { break }   # 結束記錄
            $rel = [System.Text.Encoding]::UTF8.GetString((Read-FKExact -Stream $inflate -Count $pathLength))
            $size = [System.BitConverter]::ToInt64((Read-FKExact -Stream $inflate -Count 8), 0)
            if (-not (Test-FKSafeRelativePath -Rel $rel)) { throw "加密檔中有不安全的路徑，拒絕還原：$rel" }
            if ($size -lt 0) { throw "加密檔中的檔案大小不正確：$rel" }
            if ($seen.ContainsKey($rel)) { throw "加密檔中有重複的路徑：$rel" }
            $seen[$rel] = $true
            $target = [System.IO.Path]::GetFullPath((Join-Path $staging ($rel.Replace('/', '\'))))
            if (-not $target.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "加密檔中的路徑跳出目的地，拒絕還原：$rel" }

            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
            $out = New-Object System.IO.FileStream -ArgumentList $target, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
            try {
                $remaining = $size
                while ($remaining -gt 0) {
                    $n = $inflate.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
                    if ($n -le 0) { throw "加密內容不完整（$rel 被截斷）。" }
                    $out.Write($buffer, 0, $n)
                    $remaining -= $n
                }
            }
            finally { $out.Dispose() }
            $count++
        }
        if ($inflate.Read($buffer, 0, 1) -ne 0) { throw '結束記錄之後還有多餘的資料，檔案格式不正確。' }

        $inflate.Dispose(); $inflate = $null
        $dec.Dispose(); $dec = $null
        $src.Dispose(); $src = $null
        [System.IO.Directory]::Move($staging, $packageRoot)
        $done = $true
    }
    finally {
        if ($inflate) { $inflate.Dispose() }
        if ($dec) { try { $dec.Dispose() } catch { $null = $_ } }
        if ($src) { $src.Dispose() }
        $aes.Dispose()
        if (-not $done) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-FKAction -Action 'DecryptPackage' -Target $full -Detail ('HMAC 驗證通過，還原 {0} 個檔案到 {1}' -f $count, $packageRoot) -Status 'OK'

    return [pscustomobject]@{
        PackageRoot = $packageRoot
    }
}
