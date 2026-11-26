<#
    T08：Protect-FKPackage／Unprotect-FKPackage 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11）。
    含「只照文件的 .fkpkg 格式自己解密／自己組加密檔」的測試，確保 docs/ARCHITECTURE.md 的格式說明正確，
    並用正確 HMAC 的惡意加密檔（..、絕對路徑、重複路徑、缺結束記錄）確認還原時會拒絕。
    密碼只存在記憶體，檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression

    function New-Secure([string]$Text) {
        $s = New-Object System.Security.SecureString
        foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }
        $s.MakeReadOnly()
        return $s
    }
    $script:pwText = 'unit-test 密碼-' + [guid]::NewGuid().ToString('N')
    $script:pw = New-Secure $script:pwText

    function Get-Sha([string]$Path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })) }
        finally { $sha.Dispose() }
    }

    function New-Pkg {
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $case 'FK_2026-001_UNIT_20261121T020304Z'
        foreach ($rel in 'manifest.json', 'action_log.jsonl', 'chain_of_custody.txt', 'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx', 'artifacts/說明.txt', 'artifacts/prefetch/CMD.EXE-0BD30981.pf') {
            $full = Join-Path $root ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [System.IO.File]::WriteAllText($full, "內容 $rel " + ('x' * 500))
        }
        New-Item -ItemType File -Path (Join-Path $root 'artifacts\empty.json') | Out-Null   # 0 位元組的檔案
        return $root
    }

    function Get-HashMap([string]$Root) {
        $base = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
        $map = @{}
        foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File) { $map[$f.FullName.Substring($base.Length + 1).Replace('\', '/')] = Get-Sha $f.FullName }
        return $map
    }

    function Get-Keys([byte[]]$Salt, [int]$Iterations) {
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes -ArgumentList ([System.Text.Encoding]::UTF8.GetBytes($script:pwText)), $Salt, $Iterations, ([System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try { $km = $kdf.GetBytes(64) } finally { $kdf.Dispose() }
        return @{ Enc = [byte[]]$km[0..31]; Mac = [byte[]]$km[32..63] }
    }

    function New-CraftedFkpkg {
        # 只照 ARCHITECTURE.md 的格式組出 .fkpkg（HMAC 正確），Records 為 @(@{Path; Bytes})；-NoEndRecord 省略結束記錄
        param([string]$OutPath, [object[]]$Records, [switch]$NoEndRecord)
        $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
        $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider; $rng.GetBytes($salt); $rng.GetBytes($iv); $rng.Dispose()
        $k = Get-Keys -Salt $salt -Iterations 100000

        $plain = New-Object System.IO.MemoryStream
        $deflate = New-Object System.IO.Compression.DeflateStream -ArgumentList $plain, ([System.IO.Compression.CompressionMode]::Compress), $true
        $w = New-Object System.IO.BinaryWriter -ArgumentList $deflate, ([System.Text.Encoding]::UTF8), $true
        foreach ($r in $Records) {
            $p = [System.Text.Encoding]::UTF8.GetBytes($r.Path)
            $w.Write([uint16]$p.Length); $w.Write($p); $w.Write([long]$r.Bytes.Length); $w.Write([byte[]]$r.Bytes)
        }
        if (-not $NoEndRecord) { $w.Write([uint16]0) }
        $w.Dispose(); $deflate.Dispose()

        $aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
        $aes.Key = $k.Enc; $aes.IV = $iv
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain.ToArray(), 0, [int]$plain.Length); $aes.Dispose()

        $header = New-Object byte[] 43
        [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('FKPKG'), 0, $header, 0, 5)
        $header[5] = 1; $header[6] = 1
        [Array]::Copy([System.BitConverter]::GetBytes([uint32]100000), 0, $header, 7, 4)
        [Array]::Copy($salt, 0, $header, 11, 16); [Array]::Copy($iv, 0, $header, 27, 16)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $k.Mac)
        [void]$hmac.TransformBlock($header, 0, 43, $null, 0)
        [void]$hmac.TransformFinalBlock($cipher, 0, $cipher.Length)
        $out = New-Object System.IO.MemoryStream
        $out.Write($header, 0, 43); $out.Write($hmac.Hash, 0, 32); $out.Write($cipher, 0, $cipher.Length)
        $hmac.Dispose()
        [System.IO.File]::WriteAllBytes($OutPath, $out.ToArray())
    }

    function Get-FileCountUnder([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force).Count
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'Protect-FKPackage／Unprotect-FKPackage 實作細節（T08）' -Tag 'T08' {

    BeforeEach {
        Mock Write-FKAction -ModuleName ForensiKit { }
    }

    Context '往返與格式' {

        It '加密再解密：檔案（含中文、%4、子目錄、0 位元組檔案）完全一致，沒有殘留暫存目錄' {
            $root = New-Pkg
            $expected = Get-HashMap $root
            $enc = Protect-FKPackage -PackageRoot $root -Password $script:pw
            $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $r = Unprotect-FKPackage -Path $enc.PackagePath -Password $script:pw -Destination $dest
            $r.PackageRoot | Should -Be (Join-Path $dest 'FK_2026-001_UNIT_20261121T020304Z')
            $actual = Get-HashMap $r.PackageRoot
            @($actual.Keys | Sort-Object) | Should -Be @($expected.Keys | Sort-Object)
            foreach ($k in $expected.Keys) { $actual[$k] | Should -Be $expected[$k] -Because $k }
            @(Get-ChildItem -LiteralPath $dest -Force | ForEach-Object Name) | Should -Be @('FK_2026-001_UNIT_20261121T020304Z')
        }

        It '檔頭：FKPKG、版本 1、KDF 1、迭代 ≥ 100000；長度 = 75 + 16 的倍數' {
            $enc = Protect-FKPackage -PackageRoot (New-Pkg) -Password $script:pw
            $b = [System.IO.File]::ReadAllBytes($enc.PackagePath)
            [System.Text.Encoding]::ASCII.GetString($b, 0, 5) | Should -Be 'FKPKG'
            $b[5] | Should -Be 1
            $b[6] | Should -Be 1
            [System.BitConverter]::ToUInt32($b, 7) | Should -BeGreaterOrEqual 100000
            (($b.Length - 75) % 16) | Should -Be 0
        }

        It '只照文件格式自己解密（不呼叫 Unprotect-FKPackage）：HMAC 相符，記錄串流含所有檔案與結束記錄' {
            $root = New-Pkg
            $expected = Get-HashMap $root
            $enc = Protect-FKPackage -PackageRoot $root -Password $script:pw
            $b = [System.IO.File]::ReadAllBytes($enc.PackagePath)
            $k = Get-Keys -Salt ([byte[]]$b[11..26]) -Iterations ([int][System.BitConverter]::ToUInt32($b, 7))

            $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $k.Mac)
            [void]$hmac.TransformBlock($b, 0, 43, $null, 0)
            [void]$hmac.TransformFinalBlock($b, 75, $b.Length - 75)
            [Convert]::ToBase64String($hmac.Hash) | Should -Be ([Convert]::ToBase64String([byte[]]$b[43..74]))
            $hmac.Dispose()

            $aes = New-Object System.Security.Cryptography.AesCryptoServiceProvider
            $aes.Key = $k.Enc; $aes.IV = [byte[]]$b[27..42]
            $compressed = $aes.CreateDecryptor().TransformFinalBlock($b, 75, $b.Length - 75); $aes.Dispose()
            $inflate = New-Object System.IO.Compression.DeflateStream -ArgumentList (New-Object System.IO.MemoryStream (, $compressed)), ([System.IO.Compression.CompressionMode]::Decompress)
            $plain = New-Object System.IO.MemoryStream
            $inflate.CopyTo($plain); $inflate.Dispose()
            $r = New-Object System.IO.BinaryReader -ArgumentList $plain
            $plain.Position = 0
            $found = @{}
            while ($true) {
                $len = $r.ReadUInt16()
                if ($len -eq 0) { break }
                $path = [System.Text.Encoding]::UTF8.GetString($r.ReadBytes($len))
                $size = $r.ReadInt64()
                $data = $r.ReadBytes([int]$size)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $found[$path] = -join ($sha.ComputeHash($data) | ForEach-Object { $_.ToString('x2') }); $sha.Dispose()
            }
            $plain.Position | Should -Be $plain.Length -Because '結束記錄之後不應有資料'
            @($found.Keys | Sort-Object) | Should -Be @($expected.Keys | Sort-Object)
            foreach ($key in $expected.Keys) { $found[$key] | Should -Be $expected[$key] -Because $key }
            @($found.Keys | Where-Object { $_ -match '\\' }) | Should -BeNullOrEmpty
        }

        It '依文件格式自己組的 .fkpkg 可以被 Unprotect-FKPackage 還原' {
            $p = Join-Path $TestDrive ('FK_CRAFTED_' + [guid]::NewGuid().ToString('N') + '.fkpkg')
            New-CraftedFkpkg -OutPath $p -Records @(@{ Path = 'a/b.txt'; Bytes = [System.Text.Encoding]::UTF8.GetBytes('hello') })
            $r = Unprotect-FKPackage -Path $p -Password $script:pw -Destination (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::ReadAllText((Join-Path $r.PackageRoot 'a\b.txt')) | Should -Be 'hello'
        }

        It '每次加密的 salt 與 IV 都不同' {
            $root = New-Pkg
            $a = Protect-FKPackage -PackageRoot $root -Password $script:pw
            $first = [System.IO.File]::ReadAllBytes($a.PackagePath)[11..42]
            Remove-Item -LiteralPath $a.PackagePath
            $second = [System.IO.File]::ReadAllBytes((Protect-FKPackage -PackageRoot $root -Password $script:pw).PackagePath)[11..42]
            [Convert]::ToBase64String([byte[]]$first) | Should -Not -Be ([Convert]::ToBase64String([byte[]]$second))
        }
    }

    Context '加密端的檢查' {

        It '.fkpkg 已存在時 throw，且不改動既有檔案' {
            $root = New-Pkg
            $a = Protect-FKPackage -PackageRoot $root -Password $script:pw
            $before = Get-Sha $a.PackagePath
            { Protect-FKPackage -PackageRoot $root -Password $script:pw } | Should -Throw
            Get-Sha $a.PackagePath | Should -Be $before
        }

        It '空密碼時 throw' {
            { Protect-FKPackage -PackageRoot (New-Pkg) -Password (New-Object System.Security.SecureString) } | Should -Throw
        }

        It '-RemovePlaintext：驗證後刪除明文目錄，且仍可解密' {
            $root = New-Pkg
            $expected = Get-HashMap $root
            $enc = Protect-FKPackage -PackageRoot $root -Password $script:pw -RemovePlaintext
            $root | Should -Not -Exist
            $r = Unprotect-FKPackage -Path $enc.PackagePath -Password $script:pw -Destination (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            (Get-HashMap $r.PackageRoot).Count | Should -Be $expected.Count
        }

        It '目前開啟的 action log 在證據包內時，加密不寫 action log（manifest 雜湊不受影響）' {
            $root = New-Pkg
            InModuleScope ForensiKit -Parameters @{ Root = $root } { param($Root) Open-FKActionLog -PackageRoot $Root } | Out-Null
            try { Protect-FKPackage -PackageRoot $root -Password $script:pw | Out-Null }
            finally { InModuleScope ForensiKit { Close-FKActionLog } }
            Should -Invoke Write-FKAction -ModuleName ForensiKit -Times 0 -Exactly -Scope It
        }
    }

    Context '解密端的檢查（失敗時不輸出任何檔案）' {

        It '密碼錯誤時 throw，Destination 根本不會被建立' {
            $enc = Protect-FKPackage -PackageRoot (New-Pkg) -Password $script:pw
            $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            { Unprotect-FKPackage -Path $enc.PackagePath -Password (New-Secure 'wrong') -Destination $dest } | Should -Throw -ExpectedMessage '*HMAC*'
            $dest | Should -Not -Exist
        }

        It '竄改檔頭的迭代次數時 throw（HMAC 涵蓋檔頭）' {
            $enc = Protect-FKPackage -PackageRoot (New-Pkg) -Password $script:pw
            $b = [System.IO.File]::ReadAllBytes($enc.PackagePath)
            [Array]::Copy([System.BitConverter]::GetBytes([uint32]150000), 0, $b, 7, 4)
            [System.IO.File]::WriteAllBytes($enc.PackagePath, $b)
            $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            { Unprotect-FKPackage -Path $enc.PackagePath -Password $script:pw -Destination $dest } | Should -Throw
            $dest | Should -Not -Exist
        }

        It '不是 .fkpkg 的檔案 throw' {
            $p = Join-Path $TestDrive 'not-a-package.fkpkg'
            [System.IO.File]::WriteAllBytes($p, [byte[]](1..200))
            { Unprotect-FKPackage -Path $p -Password $script:pw -Destination (Join-Path $TestDrive 'x2') } | Should -Throw -ExpectedMessage '*魔術字*'
        }

        It '目的地已有同名證據包時 throw，不覆寫' {
            $enc = Protect-FKPackage -PackageRoot (New-Pkg) -Password $script:pw
            $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Unprotect-FKPackage -Path $enc.PackagePath -Password $script:pw -Destination $dest | Out-Null
            { Unprotect-FKPackage -Path $enc.PackagePath -Password $script:pw -Destination $dest } | Should -Throw
        }

        It '惡意記錄路徑 <Name>：throw，目的地沒有檔案、目的地外也沒有寫出檔案' -TestCases @(
            @{ Name = '../'; Path = '../escaped.txt' }
            @{ Name = '中間的 ..'; Path = 'evtx/../../escaped.txt' }
            @{ Name = '絕對路徑'; Path = 'C:/Windows/escaped.txt' }
            @{ Name = '開頭的 /'; Path = '/escaped.txt' }
            @{ Name = '反斜線'; Path = '..\escaped.txt' }
            @{ Name = 'NTFS 替代資料流'; Path = 'a.txt:hidden' }
            @{ Name = '空的路徑片段'; Path = 'evtx//x.txt' }
        ) {
            param($Name, $Path)
            $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $work | Out-Null
            $p = Join-Path $work 'FK_EVIL.fkpkg'
            New-CraftedFkpkg -OutPath $p -Records @(
                @{ Path = 'ok.txt'; Bytes = [byte[]](1, 2, 3) }
                @{ Path = $Path; Bytes = [System.Text.Encoding]::UTF8.GetBytes('pwned') }
            )
            $dest = Join-Path $work 'dest'
            { Unprotect-FKPackage -Path $p -Password $script:pw -Destination $dest } | Should -Throw
            Get-FileCountUnder $dest | Should -Be 0
            Join-Path $work 'escaped.txt' | Should -Not -Exist
            Join-Path $dest 'escaped.txt' | Should -Not -Exist
        }

        It '重複的路徑 throw，不輸出檔案' {
            $p = Join-Path $TestDrive ('FK_DUP_' + [guid]::NewGuid().ToString('N') + '.fkpkg')
            New-CraftedFkpkg -OutPath $p -Records @(@{ Path = 'a.txt'; Bytes = [byte[]](1) }, @{ Path = 'a.txt'; Bytes = [byte[]](2) })
            $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            { Unprotect-FKPackage -Path $p -Password $script:pw -Destination $dest } | Should -Throw -ExpectedMessage '*重複*'
            Get-FileCountUnder $dest | Should -Be 0
        }

        It '缺少結束記錄（內容被截斷）時 throw，不輸出檔案' {
            $p = Join-Path $TestDrive ('FK_TRUNC_' + [guid]::NewGuid().ToString('N') + '.fkpkg')
            New-CraftedFkpkg -OutPath $p -Records @(@{ Path = 'a.txt'; Bytes = [byte[]](1, 2, 3) }) -NoEndRecord
            $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            { Unprotect-FKPackage -Path $p -Password $script:pw -Destination $dest } | Should -Throw -ExpectedMessage '*截斷*'
            Get-FileCountUnder $dest | Should -Be 0
        }
    }
}
