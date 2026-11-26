<#
    T11：Unprotect-FKPackage（T08）單元測試。需要 Protect-FKPackage 先產生 .fkpkg。
    重點：密碼錯誤或檔案被竄改時必須明確報錯，且不得輸出損壞檔案（TASKS.md T08）。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Protect-FKPackage', 'Unprotect-FKPackage')
    $skipInterop = -not (Test-FKCommandAvailable -Name 'Test-FKPackage')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null

    function Get-RelativeHashMap {
        param([string]$Root)
        $base = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
        $map = @{}
        Get-ChildItem -LiteralPath $base -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($base.Length + 1) -replace '\\', '/'
            $map[$rel] = Get-FKTestSha256 -Path $_.FullName
        }
        return $map
    }

    function Get-FileCountUnder {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        return @(Get-ChildItem -LiteralPath $Path -Recurse -File).Count
    }
}

Describe 'Unprotect-FKPackage' -Tag 'T08' -Skip:$skip {

    BeforeEach {
        if (Get-Command Write-FKAction -Module ForensiKit -ErrorAction SilentlyContinue) { Mock Write-FKAction -ModuleName ForensiKit { } }
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $work 'src\FK_2026-001_UNIT-TEST_20261121T020304Z'
        New-FKTestPackage -Root $root -Files @{
            'evtx/live/Security.evtx'                              = 'fake-security'
            'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx' = 'fake-sysmon'
            'artifacts/說明.txt'                                    = '中文內容'
        } | Out-Null
        $expected = Get-RelativeHashMap -Root $root
        $password = New-FKTestSecureString
        $enc = Protect-FKPackage -PackageRoot $root -Password $password
        $dest = Join-Path $work 'restored'
    }

    It '用正確密碼解密後，回傳 PackageRoot 且所有檔案（含 manifest.json）雜湊完全一致' {
        $r = Unprotect-FKPackage -Path $enc.PackagePath -Password $password -Destination $dest
        $r.PSObject.Properties.Name | Should -Contain 'PackageRoot'
        $r.PackageRoot | Should -Exist
        $actual = Get-RelativeHashMap -Root $r.PackageRoot
        @($actual.Keys | Sort-Object) | Should -Be @($expected.Keys | Sort-Object)
        foreach ($k in $expected.Keys) { $actual[$k] | Should -Be $expected[$k] -Because $k }
    }

    It '解密後的證據包能通過 Test-FKPackage' -Skip:$skipInterop {
        $r = Unprotect-FKPackage -Path $enc.PackagePath -Password $password -Destination $dest
        (Test-FKPackage -PackageRoot $r.PackageRoot).IsValid | Should -BeTrue
    }

    It '密碼錯誤時 throw，且 Destination 沒有輸出任何檔案' {
        $wrong = New-FKTestSecureString
        { Unprotect-FKPackage -Path $enc.PackagePath -Password $wrong -Destination $dest } | Should -Throw
        Get-FileCountUnder -Path $dest | Should -Be 0
    }

    It '.fkpkg 中段被竄改 1 個位元組時 throw（HMAC 驗證），且不輸出檔案' {
        $len = (Get-Item -LiteralPath $enc.PackagePath).Length
        Invoke-FKFlipByte -Path $enc.PackagePath -Offset ([int]($len / 2))
        { Unprotect-FKPackage -Path $enc.PackagePath -Password $password -Destination $dest } | Should -Throw
        Get-FileCountUnder -Path $dest | Should -Be 0
    }

    It '.fkpkg 最後 1 個位元組被竄改時 throw，且不輸出檔案' {
        Invoke-FKFlipByte -Path $enc.PackagePath -Offset -1
        { Unprotect-FKPackage -Path $enc.PackagePath -Password $password -Destination $dest } | Should -Throw
        Get-FileCountUnder -Path $dest | Should -Be 0
    }

    It '.fkpkg 被截斷時 throw，且不輸出檔案' {
        $bytes = [System.IO.File]::ReadAllBytes($enc.PackagePath)
        [System.IO.File]::WriteAllBytes($enc.PackagePath, $bytes[0..([int]($bytes.Length / 2))])
        { Unprotect-FKPackage -Path $enc.PackagePath -Password $password -Destination $dest } | Should -Throw
        Get-FileCountUnder -Path $dest | Should -Be 0
    }

    It 'Path 不存在時 throw' {
        { Unprotect-FKPackage -Path (Join-Path $work 'no-such.fkpkg') -Password $password -Destination $dest } | Should -Throw
    }
}
