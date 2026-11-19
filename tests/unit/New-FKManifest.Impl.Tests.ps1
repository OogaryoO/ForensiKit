<#
    T07：New-FKManifest 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11 New-FKManifest.Tests.ps1）。
    檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:start = New-Object datetime 2026, 11, 20, 0, 0, 0, ([DateTimeKind]::Utc)
    $script:end = New-Object datetime 2026, 11, 20, 16, 30, 0, ([DateTimeKind]::Utc)

    function Get-RefSha256([string]$Path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })) }
        finally { $sha.Dispose() }
    }

    function New-Pkg {
        $root = Join-Path $TestDrive ('FK_2026-001_UNIT_' + [guid]::NewGuid().ToString('N'))
        foreach ($rel in 'evtx/live/Security.evtx', 'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx',
            'evtx/vault/Microsoft-Windows-Sysmon%4Operational/20261120T050000Z.evtx', 'artifacts/processes.json',
            'artifacts/prefetch/CMD.EXE-0BD30981.pf') {
            $full = Join-Path $root ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [System.IO.File]::WriteAllText($full, "content of $rel")
        }
        return $root
    }

    function Invoke-Manifest([string]$Root) {
        New-FKManifest -PackageRoot $Root -CaseId '2026-001' -Operator '王小明' -StartUtc $script:start -EndUtc $script:end
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'New-FKManifest 實作細節（T07）' -Tag 'T07' {

    It 'manifest.json 為無 BOM 的 UTF-8，中文不亂碼' {
        $root = New-Pkg
        $r = Invoke-Manifest -Root $root
        $bytes = [System.IO.File]::ReadAllBytes($r.ManifestPath)
        ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should -Not -Be 'EFBBBF'
        ([System.IO.File]::ReadAllText($r.ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).case.operator | Should -Be '王小明'
    }

    It 'sha256 為小寫十六進位，files 依路徑排序' {
        $root = New-Pkg
        $m = Get-Content -LiteralPath (Invoke-Manifest -Root $root).ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($f in $m.files) { $f.sha256 | Should -MatchExactly '^[0-9a-f]{64}$' }
        $paths = @($m.files | ForEach-Object { $_.path })
        $sorted = @($paths | Sort-Object -CaseSensitive)
        $paths | Should -Be $sorted
    }

    It 'source 與 collector 依路徑推得（%4 還原成 /）' {
        $root = New-Pkg
        $m = Get-Content -LiteralPath (Invoke-Manifest -Root $root).ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $byPath = @{}
        foreach ($f in $m.files) { $byPath[$f.path] = $f }
        $byPath['evtx/live/Security.evtx'].source | Should -Be 'Security'
        $byPath['evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx'].source | Should -Be 'Microsoft-Windows-Sysmon/Operational'
        $byPath['evtx/live/Security.evtx'].collector | Should -Be 'Export-FKEventLog'
        $byPath['evtx/vault/Microsoft-Windows-Sysmon%4Operational/20261120T050000Z.evtx'].source | Should -Be 'Microsoft-Windows-Sysmon/Operational'
        $byPath['artifacts/processes.json'].collector | Should -Be 'Get-FKArtifact'
        $byPath['artifacts/processes.json'].source | Should -Be 'processes'
        $byPath['artifacts/prefetch/CMD.EXE-0BD30981.pf'].source | Should -Be 'prefetch'
        foreach ($f in $m.files) { $f.status | Should -Be 'OK' }
    }

    It '重跑時不會把 manifest.json 與 chain_of_custody.txt 列進 files' {
        $root = New-Pkg
        Invoke-Manifest -Root $root | Out-Null
        $r2 = Invoke-Manifest -Root $root
        $m = Get-Content -LiteralPath $r2.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $paths = @($m.files | ForEach-Object { $_.path })
        $paths | Should -Not -Contain 'manifest.json'
        $paths | Should -Not -Contain 'chain_of_custody.txt'
        $r2.FileCount | Should -Be 5
    }

    It 'action log 在雜湊之前寫入：manifest 中 action_log.jsonl 的雜湊與最終檔案一致' {
        $root = New-Pkg
        InModuleScope ForensiKit -Parameters @{ Root = $root } { param($Root) Open-FKActionLog -PackageRoot $Root } | Out-Null
        try {
            Write-FKAction -Action 'ExportEventLog' -Target 'Security' -Detail 'wevtutil epl ...' -Status 'OK'
            $r = Invoke-Manifest -Root $root
        }
        finally {
            InModuleScope ForensiKit { Close-FKActionLog }
        }
        $m = Get-Content -LiteralPath $r.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $log = $m.files | Where-Object { $_.path -eq 'action_log.jsonl' }
        $log.sha256 | Should -Be (Get-RefSha256 -Path (Join-Path $root 'action_log.jsonl'))
        $log.collector | Should -Be 'Write-FKAction'
        $lines = @([System.IO.File]::ReadAllLines((Join-Path $root 'action_log.jsonl')))
        ($lines[-1] | ConvertFrom-Json).action | Should -Be 'CreateManifest'
    }

    It 'chain_of_custody.txt 並列 UTC 與台灣時間，含 manifest 雜湊與移交紀錄欄' {
        $root = New-Pkg
        $r = Invoke-Manifest -Root $root
        $text = [System.IO.File]::ReadAllText((Join-Path $root 'chain_of_custody.txt'), [System.Text.Encoding]::UTF8)
        $text | Should -Match ([regex]::Escape('2026-11-20T00:00:00Z ～ 2026-11-20T16:30:00Z'))
        $text | Should -Match ([regex]::Escape('2026-11-20 08:00:00 (+08:00) ～ 2026-11-21 00:30:00 (+08:00)'))
        $text | Should -Match ([regex]::Escape($r.ManifestSha256))
        $text | Should -Match '交付人'
        $text | Should -Match '接收人'
        $text | Should -Match '簽名'
    }

    It 'Kind = Local 的時段先轉成 UTC' {
        $root = New-Pkg
        $r = New-FKManifest -PackageRoot $root -CaseId 'X' -Operator 'Y' -StartUtc $script:start.ToLocalTime() -EndUtc $script:end.ToLocalTime()
        $raw = Get-Content -LiteralPath $r.ManifestPath -Raw -Encoding UTF8
        $raw | Should -Match '"startUtc":\s*"2026-11-20T00:00:00Z"'
    }

    It '-WhatIf 時不寫任何檔案' {
        $root = New-Pkg
        New-FKManifest -PackageRoot $root -CaseId 'X' -Operator 'Y' -StartUtc $script:start -EndUtc $script:end -WhatIf | Should -BeNullOrEmpty
        (Join-Path $root 'manifest.json') | Should -Not -Exist
        (Join-Path $root 'chain_of_custody.txt') | Should -Not -Exist
    }

    It '證據包目錄不存在時 throw' {
        { New-FKManifest -PackageRoot (Join-Path $TestDrive 'missing') -CaseId 'X' -Operator 'Y' -StartUtc $script:start -EndUtc $script:end } | Should -Throw
    }

    It '空的證據包：files 為空陣列、FileCount = 0' {
        $root = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $r = Invoke-Manifest -Root $root
        $r.FileCount | Should -Be 0
        (Get-Content -LiteralPath $r.ManifestPath -Raw -Encoding UTF8) | Should -Match '"files":\s*\[\s*\]'
    }
}
