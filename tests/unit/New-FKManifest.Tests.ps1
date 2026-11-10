<#
    T11：New-FKManifest（T07）單元測試，依契約第 4 節 manifest.json 格式與 TASKS.md T07。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'New-FKManifest')
    $skipInterop = -not (Test-FKCommandAvailable -Name 'Test-FKPackage')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null

    $script:start = New-FKUtcDate 2026 11 20 0 0 0
    $script:end = New-FKUtcDate 2026 11 21 0 0 0

    function New-ManifestUnderTest {
        param([string]$Root)
        New-FKManifest -PackageRoot $Root -CaseId '2026-001' -Operator '王小明' -StartUtc $script:start -EndUtc $script:end
    }

    function Read-Manifest {
        param([string]$Path)
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}

Describe 'New-FKManifest' -Tag 'T07' -Skip:$skip {

    BeforeEach {
        if (Get-Command Write-FKAction -Module ForensiKit -ErrorAction SilentlyContinue) { Mock Write-FKAction -ModuleName ForensiKit { } }
        $root = Join-Path $TestDrive ('FK_2026-001_UNIT-TEST_' + [guid]::NewGuid().ToString('N'))
        $content = @{
            'evtx/live/Security.evtx'                              = 'fake-security'
            'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx' = 'fake-sysmon'
            'evtx/vault/Security/20261120T050000Z.evtx'            = 'fake-vault'
            'artifacts/processes.json'                             = '[]'
        }
        foreach ($k in $content.Keys) { Write-FKTestFile -Root $root -RelativePath $k -Content $content[$k] | Out-Null }
    }

    Context '回傳值' {

        It '回傳 ManifestPath、ManifestSha256、FileCount' {
            $r = New-ManifestUnderTest -Root $root
            $names = $r.PSObject.Properties.Name
            foreach ($p in 'ManifestPath', 'ManifestSha256', 'FileCount') { $names | Should -Contain $p }
        }

        It 'ManifestPath 是證據包根目錄下的 manifest.json' {
            $r = New-ManifestUnderTest -Root $root
            $r.ManifestPath | Should -Exist
            (Split-Path -Leaf $r.ManifestPath) | Should -Be 'manifest.json'
            (Resolve-Path (Split-Path -Parent $r.ManifestPath)).Path | Should -Be (Resolve-Path $root).Path
        }

        It 'ManifestSha256 等於 manifest.json 檔案本身的 SHA-256' {
            $r = New-ManifestUnderTest -Root $root
            $r.ManifestSha256 | Should -Match '^[0-9a-fA-F]{64}$'
            $r.ManifestSha256.ToLowerInvariant() | Should -Be (Get-FKTestSha256 -Path $r.ManifestPath)
        }

        It 'FileCount 等於 manifest 的 files 筆數' {
            $r = New-ManifestUnderTest -Root $root
            $m = Read-Manifest -Path $r.ManifestPath
            $r.FileCount | Should -Be @($m.files).Count
        }
    }

    Context 'manifest.json 內容（契約第 4 節）' {

        BeforeEach {
            $r = New-ManifestUnderTest -Root $root
            $m = Read-Manifest -Path $r.ManifestPath
        }

        It 'schemaVersion 為 "1.0"，tool.name 為 ForensiKit，且有 tool.version' {
            $m.schemaVersion | Should -Be '1.0'
            $m.tool.name | Should -Be 'ForensiKit'
            [string]$m.tool.version | Should -Not -BeNullOrEmpty
        }

        It 'case 記錄案號與操作者（中文不亂碼）' {
            $m.case.caseId | Should -Be '2026-001'
            $m.case.operator | Should -Be '王小明'
        }

        It 'host 含 computerName、osVersion、timeZone' {
            $m.host.computerName | Should -Be $env:COMPUTERNAME
            [string]$m.host.osVersion | Should -Not -BeNullOrEmpty
            [string]$m.host.timeZone | Should -Not -BeNullOrEmpty
        }

        It 'timeRange 為 ISO 8601 UTC 字串，與參數一致' {
            # ConvertFrom-Json 在 PS 5.1 不會自動轉 datetime，這裡直接比字串
            $raw = Get-Content -LiteralPath $r.ManifestPath -Raw -Encoding UTF8
            $raw | Should -Match ('"startUtc"\s*:\s*"' + [regex]::Escape((ConvertTo-FKIsoUtc $script:start)) + '"')
            $raw | Should -Match ('"endUtc"\s*:\s*"' + [regex]::Escape((ConvertTo-FKIsoUtc $script:end)) + '"')
        }

        It 'collectedAtUtc 為 ISO 8601 UTC 字串（結尾 Z）' {
            [string]$m.collectedAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
        }

        It '每個證據檔都列在 files，路徑用 / 分隔且相對於根目錄' {
            $paths = @($m.files | ForEach-Object { $_.path })
            foreach ($p in 'evtx/live/Security.evtx', 'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx',
                'evtx/vault/Security/20261120T050000Z.evtx', 'artifacts/processes.json') {
                $paths | Should -Contain $p
            }
            $paths | Where-Object { $_ -match '\\' -or $_ -match '^[A-Za-z]:' -or $_ -match '^/' } | Should -BeNullOrEmpty
        }

        It 'files 的 sha256 與 size 和實際檔案一致' {
            foreach ($f in $m.files) {
                $full = Join-Path $root ($f.path -replace '/', '\')
                $f.sha256.ToLowerInvariant() | Should -Be (Get-FKTestSha256 -Path $full) -Because $f.path
                [long]$f.size | Should -Be (Get-Item -LiteralPath $full).Length -Because $f.path
            }
        }

        It 'manifest.json 本身不列入 files' {
            @($m.files | ForEach-Object { $_.path }) | Should -Not -Contain 'manifest.json'
        }

        It 'files 的 status 只用契約允許的值' {
            foreach ($f in $m.files) {
                if ($f.PSObject.Properties.Name -contains 'status' -and $null -ne $f.status) {
                    $script:FKStatusValues | Should -Contain $f.status
                }
            }
        }
    }

    Context '監管鏈表單（TASKS.md T07）' {

        It 'chain_of_custody.txt 存在且寫有 manifest 的 SHA-256' {
            $r = New-ManifestUnderTest -Root $root
            $coc = Join-Path $root 'chain_of_custody.txt'
            $coc | Should -Exist
            (Get-Content -LiteralPath $coc -Raw -Encoding UTF8) | Should -Match ([regex]::Escape($r.ManifestSha256))
        }

        It 'chain_of_custody.txt 含案號、操作者與 UTC 時段' {
            New-ManifestUnderTest -Root $root | Out-Null
            $text = Get-Content -LiteralPath (Join-Path $root 'chain_of_custody.txt') -Raw -Encoding UTF8
            $text | Should -Match '2026-001'
            $text | Should -Match '王小明'
            $text | Should -Match ([regex]::Escape((ConvertTo-FKIsoUtc $script:start)))
            $text | Should -Match ([regex]::Escape((ConvertTo-FKIsoUtc $script:end)))
        }
    }

    Context '與 Test-FKPackage 的互通（AC6 前置條件）' {

        It 'New-FKManifest 產生的證據包能通過 Test-FKPackage' -Skip:$skipInterop {
            New-ManifestUnderTest -Root $root | Out-Null
            (Test-FKPackage -PackageRoot $root).IsValid | Should -BeTrue
        }
    }

    Context '待確認（等實作或 PM 回覆後再啟用）' {

        It 'files 的 source、collector、status 從哪裡取得（New-FKManifest 參數中沒有收集結果）' -Skip { }

        It 'chain_of_custody.txt 同時列出 UTC 與 +08:00 時間' -Skip {
            # TASKS.md T07 有要求，但顯示格式未定，待實作後依實際格式補上
        }
    }
}
