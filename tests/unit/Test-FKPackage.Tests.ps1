<#
    T11：Test-FKPackage（T07）單元測試。對應 AC6（竄改前全部一致、竄改後正確指出該檔）。
    證據包由 New-FKTestPackage 依契約第 4 節格式自行產生，不依賴 New-FKManifest。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Test-FKPackage')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe 'Test-FKPackage' -Tag 'T07', 'AC6' -Skip:$skip {

    BeforeEach {
        # 避免實作寫 action log 時找不到證據包，也避免寫到 TestDrive 以外
        if (Get-Command Write-FKAction -Module ForensiKit -ErrorAction SilentlyContinue) { Mock Write-FKAction -ModuleName ForensiKit { } }
        $root = Join-Path $TestDrive ('FK_TEST-001_UNIT-TEST_' + [guid]::NewGuid().ToString('N'))
        $pkg = New-FKTestPackage -Root $root
    }

    Context '未竄改的證據包' {

        It '回傳契約欄位 IsValid、Mismatched、Missing、Extra' {
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $names = $r.PSObject.Properties.Name
            foreach ($p in 'IsValid', 'Mismatched', 'Missing', 'Extra') { $names | Should -Contain $p }
        }

        It 'IsValid 為 $true，且三個清單都是空的' {
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $r.IsValid | Should -BeOfType [bool]
            $r.IsValid | Should -BeTrue
            @($r.Mismatched) | Where-Object { $_ } | Should -BeNullOrEmpty
            @($r.Missing) | Where-Object { $_ } | Should -BeNullOrEmpty
            @($r.Extra) | Where-Object { $_ } | Should -BeNullOrEmpty
        }

        It 'manifest.json 本身不被列為 Extra（契約：manifest 不列入 files）' {
            $r = Test-FKPackage -PackageRoot $pkg.Root
            @($r.Extra) | Should -Not -Contain 'manifest.json'
        }

        It '路徑含中文與 %4 的檔案也能驗證通過' {
            $files = @{
                'evtx/live/Microsoft-Windows-PowerShell%4Operational.evtx' = 'x'
                'artifacts/說明.txt'                                          = '中文內容'
            }
            $root2 = Join-Path $TestDrive 'FK_中文_UNIT-TEST_20261121T020304Z'
            $pkg2 = New-FKTestPackage -Root $root2 -Files $files
            (Test-FKPackage -PackageRoot $pkg2.Root).IsValid | Should -BeTrue
        }
    }

    Context '竄改偵測（AC6）' {

        It '改動 1 個位元組後 IsValid 為 $false，且 Mismatched 正確指出該檔' {
            $target = 'evtx/live/Security.evtx'
            Invoke-FKFlipByte -Path (Join-Path $pkg.Root ($target -replace '/', '\')) -Offset 3
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $r.IsValid | Should -BeFalse
            @($r.Mismatched) | Should -Contain $target -Because 'Mismatched 應使用 manifest 中的相對路徑（/ 分隔）'
            @($r.Mismatched).Count | Should -Be 1
            @($r.Missing) | Where-Object { $_ } | Should -BeNullOrEmpty
        }

        It '內容不變但長度改變（附加 1 個位元組）也要列為 Mismatched' {
            $target = 'artifacts/processes.json'
            $full = Join-Path $pkg.Root ($target -replace '/', '\')
            [System.IO.File]::AppendAllText($full, ' ')
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $r.IsValid | Should -BeFalse
            @($r.Mismatched) | Should -Contain $target
        }

        It '刪除檔案後列在 Missing' {
            $target = 'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx'
            Remove-Item -LiteralPath (Join-Path $pkg.Root ($target -replace '/', '\'))
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $r.IsValid | Should -BeFalse
            @($r.Missing) | Should -Contain $target
            @($r.Mismatched) | Should -Not -Contain $target
        }

        It '多出 manifest 沒列的檔案時列在 Extra' {
            Write-FKTestFile -Root $pkg.Root -RelativePath 'artifacts/planted.txt' -Content 'planted' | Out-Null
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $r.IsValid | Should -BeFalse
            @($r.Extra) | Should -Contain 'artifacts/planted.txt'
        }

        It '竄改 manifest.json 中的雜湊值時列為 Mismatched' {
            $m = Get-Content -LiteralPath $pkg.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $m.files[0].sha256 = ('0' * 64)
            [System.IO.File]::WriteAllText($pkg.ManifestPath, ($m | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            $r = Test-FKPackage -PackageRoot $pkg.Root
            $r.IsValid | Should -BeFalse
            @($r.Mismatched) | Should -Contain $m.files[0].path
        }

        It '雜湊比對不分大小寫（manifest 寫大寫十六進位也算一致）' {
            $m = Get-Content -LiteralPath $pkg.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($f in $m.files) { $f.sha256 = $f.sha256.ToUpperInvariant() }
            [System.IO.File]::WriteAllText($pkg.ManifestPath, ($m | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            (Test-FKPackage -PackageRoot $pkg.Root).IsValid | Should -BeTrue
        }
    }

    Context '參數錯誤' {

        It 'PackageRoot 不存在時 throw（契約第 3 節：參數錯誤才 throw）' {
            { Test-FKPackage -PackageRoot (Join-Path $TestDrive 'no-such-package') } | Should -Throw
        }
    }

    Context '待確認（等實作或 PM 回覆後再啟用）' {

        It 'chain_of_custody.txt 不應被列為 Extra（它在 manifest 產生後才寫入）' -Skip {
            # 契約只說 manifest.json 不列入 files；chain_of_custody.txt 是否列入待 PM / T07 確認
        }

        It 'manifest.json 遺失或不是合法 JSON 時的行為（throw 或 IsValid = $false）' -Skip {
            # 契約未定義，待 T07 決定後補上
        }
    }
}
