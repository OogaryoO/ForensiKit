function Protect-FKPackage {
    <#
    .SYNOPSIS
        把證據包目錄打包並以密碼加密成單一 .fkpkg 檔（Deflate + AES-256-CBC + PBKDF2 + HMAC-SHA256）。

    .DESCRIPTION
        輸出：與證據包目錄同層的 <目錄名稱>.fkpkg（docs/ARCHITECTURE.md 第 4 節）。已存在時 throw，不覆寫。

        檔案格式（.fkpkg；整數一律 little-endian；完整說明見 docs/ARCHITECTURE.md）：
          offset  長度  內容
          0       5     魔術字 ASCII "FKPKG"
          5       1     格式版本 = 1
          6       1     KDF：1 = PBKDF2-HMAC-SHA256
          7       4     PBKDF2 迭代次數（UInt32；目前 200000，至少 100000）
          11      16    salt（隨機）
          27      16    AES IV（隨機）
          43      32    HMAC-SHA256( bytes 0–42 ‖ 密文 )
          75      到檔尾 密文：AES-256-CBC、PKCS7；明文是 Deflate 壓縮後的「記錄串流」
        金鑰：PBKDF2(密碼的 UTF-8 bytes, salt, 迭代次數) 推導 64 bytes，前 32 為 AES 金鑰、後 32 為 HMAC 金鑰。
        記錄串流：每個檔案一筆「UInt16 路徑長度 ‖ 路徑（UTF-8，/ 分隔，相對於證據包根目錄）‖ Int64 大小 ‖ 內容」，
                  最後一筆路徑長度為 0 的結束記錄。

        打包、壓縮、加密、HMAC 以串流一次完成（記錄 → DeflateStream → AES CryptoStream → HMAC CryptoStream → 檔案），
        磁碟上不會出現未加密的副本（PM 於 #11 決定，取代 TASKS.md 原本的「先 Compress-Archive 成 zip」）。

        -RemovePlaintext：寫完後重新讀回 .fkpkg 驗證 HMAC，通過才刪除明文目錄。

        依契約第 4 節，本函式在 New-FKManifest 與 Close-FKActionLog 之後執行；若目前開啟的 action log 位於這個證據包內，
        不寫 action log（否則 manifest 的雜湊會對不上）。

    .PARAMETER PackageRoot
        證據包根目錄。

    .PARAMETER Password
        加密密碼（不可為空）。請另行安全地交給接收方。

    .PARAMETER RemovePlaintext
        加密並驗證成功後刪除明文證據包目錄。

    .OUTPUTS
        [pscustomobject] @{ PackagePath; Sha256 }（Sha256 為 .fkpkg 檔案本身的 SHA-256，小寫）

    .EXAMPLE
        $pw = Read-Host -AsSecureString '證據包密碼'
        Protect-FKPackage -PackageRoot 'E:\FK_2026-001_WIN11-TEST_20261121T020304Z' -Password $pw -RemovePlaintext
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Password,

        [Parameter()]
        [switch]$RemovePlaintext
    )

    Add-Type -AssemblyName System.IO.Compression

    $iterations = 200000
    $headerLength = 43
    $macLength = 32

    function Get-FKPasswordByte {
        param([System.Security.SecureString]$Secure)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { return , [System.Text.Encoding]::UTF8.GetBytes([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    function Test-FKPackageMac {
        # 重新讀回檔案驗證 HMAC（-RemovePlaintext 刪除前使用）
        param([string]$Path, [byte[]]$MacKey)
        $fs = [System.IO.File]::OpenRead($Path)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $MacKey)
        try {
            $head = New-Object byte[] ($headerLength + $macLength)
            if ($fs.Read($head, 0, $head.Length) -ne $head.Length) { return $false }
            [void]$hmac.TransformBlock($head, 0, $headerLength, $null, 0)
            $buffer = New-Object byte[] 1048576
            while (($n = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) { [void]$hmac.TransformBlock($buffer, 0, $n, $null, 0) }
            [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $diff = 0
            for ($i = 0; $i -lt $macLength; $i++) { $diff = $diff -bor ($head[$headerLength + $i] -bxor $hmac.Hash[$i]) }
            return ($diff -eq 0)
        }
        finally { $hmac.Dispose(); $fs.Dispose() }
    }

    # ---- 參數檢查 ----

    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "證據包目錄不存在：$PackageRoot"
    }
    if ($Password.Length -lt 1) { throw '密碼不可為空。' }
    $root = (Resolve-Path -LiteralPath $PackageRoot).ProviderPath.TrimEnd('\')
    $rootPrefix = $root + '\'
    $packagePath = Join-Path (Split-Path -Parent $root) ((Split-Path -Leaf $root) + '.fkpkg')
    if (Test-Path -LiteralPath $packagePath) { throw "加密檔已存在，不覆寫：$packagePath" }

    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop | Sort-Object -Property FullName)
    foreach ($f in $files) {
        if ([System.Text.Encoding]::UTF8.GetByteCount($f.FullName.Substring($rootPrefix.Length)) -gt 65535) { throw "路徑太長，無法打包：$($f.FullName)" }
    }

    # ---- 金鑰 ----

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
    $rng.Dispose()

    $pwBytes = Get-FKPasswordByte -Secure $Password
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes -ArgumentList $pwBytes, $salt, $iterations, ([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $keyMaterial = $kdf.GetBytes(64) }
    finally { $kdf.Dispose(); [Array]::Clear($pwBytes, 0, $pwBytes.Length) }
    $encKey = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    [Array]::Copy($keyMaterial, 0, $encKey, 0, 32)
    [Array]::Copy($keyMaterial, 32, $macKey, 0, 32)
    [Array]::Clear($keyMaterial, 0, $keyMaterial.Length)

    $header = New-Object byte[] $headerLength
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('FKPKG'), 0, $header, 0, 5)
    $header[5] = 1
    $header[6] = 1
    [Array]::Copy([System.BitConverter]::GetBytes([uint32]$iterations), 0, $header, 7, 4)
    [Array]::Copy($salt, 0, $header, 11, 16)
    [Array]::Copy($iv, 0, $header, 27, 16)

    # ---- 記錄 → Deflate → AES → HMAC → 檔案（串流，不落地明文） ----

    $aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $encKey
    $aes.IV = $iv
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $macKey)

    $fs = $null; $macStream = $null; $encStream = $null; $deflate = $null; $writer = $null
    $ok = $false
    try {
        $fs = New-Object System.IO.FileStream -ArgumentList $packagePath, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::ReadWrite), ([System.IO.FileShare]::None)
        # 檔頭與 HMAC 預留位置直接寫入；HMAC 先算檔頭，之後的密文由 CryptoStream 接著算
        $fs.Write($header, 0, $headerLength)
        $fs.Write((New-Object byte[] $macLength), 0, $macLength)
        [void]$hmac.TransformBlock($header, 0, $headerLength, $null, 0)

        $macStream = New-Object System.Security.Cryptography.CryptoStream -ArgumentList $fs, $hmac, ([System.Security.Cryptography.CryptoStreamMode]::Write), $true
        $encStream = New-Object System.Security.Cryptography.CryptoStream -ArgumentList $macStream, $aes.CreateEncryptor(), ([System.Security.Cryptography.CryptoStreamMode]::Write), $true
        $deflate = New-Object System.IO.Compression.DeflateStream -ArgumentList $encStream, ([System.IO.Compression.CompressionLevel]::Optimal), $true
        $writer = New-Object System.IO.BinaryWriter -ArgumentList $deflate, ([System.Text.Encoding]::UTF8), $true

        $buffer = New-Object byte[] 1048576
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($rootPrefix.Length).Replace('\', '/')
            $relBytes = [System.Text.Encoding]::UTF8.GetBytes($rel)
            $size = [long]$f.Length
            $writer.Write([uint16]$relBytes.Length)
            $writer.Write($relBytes)
            $writer.Write([long]$size)
            $writer.Flush()
            $in = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $remaining = $size
                while ($remaining -gt 0) {
                    $n = $in.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
                    if ($n -le 0) { throw "檔案在加密過程中被改短了：$($f.FullName)" }
                    $deflate.Write($buffer, 0, $n)
                    $remaining -= $n
                }
            }
            finally { $in.Dispose() }
        }
        $writer.Write([uint16]0)   # 結束記錄
        $writer.Flush()

        $writer.Dispose(); $writer = $null
        $deflate.Dispose(); $deflate = $null
        $encStream.FlushFinalBlock(); $encStream.Dispose(); $encStream = $null
        # .NET Framework 的 CryptoStream.FlushFinalBlock 會連帶對下層的 CryptoStream 收尾，這裡只在還沒收尾時呼叫
        if (-not $macStream.HasFlushedFinalBlock) { $macStream.FlushFinalBlock() }
        $macStream.Dispose(); $macStream = $null
        [void]$fs.Seek($headerLength, [System.IO.SeekOrigin]::Begin)
        $fs.Write($hmac.Hash, 0, $macLength)
        $fs.Flush($true)
        $fs.Dispose(); $fs = $null
        $ok = $true
    }
    finally {
        if ($writer) { $writer.Dispose() }
        if ($deflate) { $deflate.Dispose() }
        if ($encStream) { $encStream.Dispose() }
        if ($macStream) { $macStream.Dispose() }
        if ($fs) { $fs.Dispose() }
        $aes.Dispose()
        $hmac.Dispose()
        [Array]::Clear($encKey, 0, $encKey.Length)
        if (-not $ok) {
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
            [Array]::Clear($macKey, 0, $macKey.Length)
        }
    }

    # ---- 雜湊、刪除明文、action log ----

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $pkgStream = [System.IO.File]::OpenRead($packagePath)
    try { $pkgSha = -join ($sha.ComputeHash($pkgStream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $pkgStream.Dispose(); $sha.Dispose() }

    $removed = $false
    if ($RemovePlaintext) {
        $verified = Test-FKPackageMac -Path $packagePath -MacKey $macKey
        [Array]::Clear($macKey, 0, $macKey.Length)
        if (-not $verified) { throw "加密檔讀回驗證失敗，未刪除明文目錄：$packagePath" }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        $removed = $true
    }
    [Array]::Clear($macKey, 0, $macKey.Length)

    $openLog = Get-FKActionLogPath
    if (-not ($openLog -and $openLog.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
        Write-FKAction -Action 'EncryptPackage' -Target $packagePath -Detail ('Deflate + AES-256-CBC + HMAC-SHA256，PBKDF2-SHA256 {0} 次；{1} 個檔案；.fkpkg SHA-256={2}；刪除明文={3}' -f $iterations, $files.Count, $pkgSha, $removed) -Status 'OK'
    }

    return [pscustomobject]@{
        PackagePath = $packagePath
        Sha256      = $pkgSha
    }
}
