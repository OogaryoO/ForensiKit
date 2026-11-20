<#
    T11：Protect-FKPackage（T08）單元測試，依契約第 4、7 節與 TASKS.md T08。
    只用 TestDrive 中的假證據包，密碼只存在記憶體。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Protect-FKPackage')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null

    $script:marker = 'FK-PLAINTEXT-MARKER-' + [guid]::NewGuid().ToString('N')

    function Test-BytesContain {
        param([byte[]]$Haystack, [byte[]]$Needle)
        $limit = $Haystack.Length - $Needle.Length
        for ($i = 0; $i -le $limit; $i++) {
            $match = $true
            for ($j = 0; $j -lt $Needle.Length; $j++) {
                if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
            }
            if ($match) { return $true }
        }
        return $false
    }
}

Describe 'Protect-FKPackage' -Tag 'T08' -Skip:$skip {

    BeforeEach {
        if (Get-Command Write-FKAction -Module ForensiKit -ErrorAction SilentlyContinue) { Mock Write-FKAction -ModuleName ForensiKit { } }
        $caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $caseDir 'FK_2026-001_UNIT-TEST_20261121T020304Z'
        $pkg = New-FKTestPackage -Root $root -Files @{
            'evtx/live/Security.evtx'  = "evtx $script:marker"
            'artifacts/processes.json' = "[`"$script:marker`"]"
        }
        $password = New-FKTestSecureString
    }

    It '回傳 PackagePath 與 Sha256' {
        $r = Protect-FKPackage -PackageRoot $root -Password $password
        $names = $r.PSObject.Properties.Name
        $names | Should -Contain 'PackagePath'
        $names | Should -Contain 'Sha256'
    }

    It '產生單一 .fkpkg 檔，檔名沿用證據包目錄名稱（契約第 4 節）' {
        $r = Protect-FKPackage -PackageRoot $root -Password $password
        $r.PackagePath | Should -Exist
        [System.IO.Path]::GetExtension($r.PackagePath) | Should -Be '.fkpkg'
        [System.IO.Path]::GetFileNameWithoutExtension($r.PackagePath) | Should -Be (Split-Path -Leaf $root)
    }

    It 'Sha256 是 .fkpkg 檔案的 SHA-256' {
        $r = Protect-FKPackage -PackageRoot $root -Password $password
        $r.Sha256 | Should -Match '^[0-9a-fA-F]{64}$'
        $r.Sha256.ToLowerInvariant() | Should -Be (Get-FKTestSha256 -Path $r.PackagePath)
    }

    It '.fkpkg 中找不到明文內容（UTF-8 與 UTF-16 都檢查）' {
        $r = Protect-FKPackage -PackageRoot $root -Password $password
        $bytes = [System.IO.File]::ReadAllBytes($r.PackagePath)
        Test-BytesContain -Haystack $bytes -Needle ([System.Text.Encoding]::UTF8.GetBytes($script:marker)) | Should -BeFalse
        Test-BytesContain -Haystack $bytes -Needle ([System.Text.Encoding]::Unicode.GetBytes($script:marker)) | Should -BeFalse
    }

    It '同一證據包、同一密碼加密兩次，輸出不同（隨機 salt / IV）' {
        $r1 = Protect-FKPackage -PackageRoot $root -Password $password
        $copy = Join-Path $TestDrive ('copy-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $copy | Out-Null
        Move-Item -LiteralPath $r1.PackagePath -Destination $copy
        $r2 = Protect-FKPackage -PackageRoot $root -Password $password
        $r2.Sha256 | Should -Not -Be $r1.Sha256
    }

    It '沒有 -RemovePlaintext 時保留明文目錄' {
        Protect-FKPackage -PackageRoot $root -Password $password | Out-Null
        $root | Should -Exist
        (Join-Path $root 'manifest.json') | Should -Exist
    }

    It '-RemovePlaintext 時刪除明文目錄，但 .fkpkg 仍在' {
        $r = Protect-FKPackage -PackageRoot $root -Password $password -RemovePlaintext
        $r.PackagePath | Should -Exist
        $root | Should -Not -Exist
    }

    It 'PackageRoot 不存在時 throw' {
        { Protect-FKPackage -PackageRoot (Join-Path $TestDrive 'no-such') -Password $password } | Should -Throw
    }

    Context '待確認（等實作後再啟用）' {

        It 'PBKDF2 迭代次數 ≥ 100,000，檔頭格式與 ARCHITECTURE.md 一致' -Skip {
            # 檔頭格式要等 T08 的 [contract] PR 補進 ARCHITECTURE.md 後才能依格式解析驗證
        }
    }
}
