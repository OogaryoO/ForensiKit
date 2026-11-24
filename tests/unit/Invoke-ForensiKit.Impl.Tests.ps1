<#
    T09a：Invoke-ForensiKit 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11 Invoke-ForensiKit.Tests.ps1）。
    只 Mock wevtutil（epl、gl、gli）與管理員檢查，Export-FKEventLog 與 New-FKManifest 用真的實作串起來。檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:start = New-Object datetime 2026, 11, 20, 0, 0, 0, ([DateTimeKind]::Utc)
    $script:end = New-Object datetime 2026, 11, 21, 0, 0, 0, ([DateTimeKind]::Utc)

    $script:fakeWevtutil = {
        $global:LASTEXITCODE = 0
        if ([string]$args[0] -eq 'epl') { [System.IO.File]::WriteAllText([string]$args[2], 'fake-evtx') }
        if ([string]$args[0] -eq 'gli') { return @('fileSize: 69632', 'numberOfLogRecords: 5') }
    }

    function Get-RefSha256([string]$Path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })) }
        finally { $sha.Dispose() }
    }

    function New-SecureText([string]$Text) {
        $s = New-Object System.Security.SecureString
        foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }
        $s.MakeReadOnly()
        return $s
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'Invoke-ForensiKit 實作細節（T09a）' -Tag 'T09a' {

    BeforeEach {
        Mock wevtutil -ModuleName ForensiKit $script:fakeWevtutil
        Mock Test-FKAdmin -ModuleName ForensiKit { $true }
        $script:out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:out | Out-Null
        $script:common = @{ CaseId = '2026-001'; Operator = '王小明'; StartUtc = $script:start; EndUtc = $script:end; OutputRoot = $script:out; NoEncrypt = $true }
    }

    Context '端到端（真的 Export-FKEventLog 與 New-FKManifest）' {

        It '產出 Security.evtx、manifest.json、chain_of_custody.txt，manifest 雜湊正確' {
            $r = Invoke-ForensiKit @script:common
            $r.Status | Should -Be 'OK'
            $r.PackagePath | Should -BeNullOrEmpty
            (Join-Path $r.PackageRoot 'evtx\live\Security.evtx') | Should -Exist
            (Join-Path $r.PackageRoot 'chain_of_custody.txt') | Should -Exist
            $r.ManifestSha256 | Should -Be (Get-RefSha256 -Path (Join-Path $r.PackageRoot 'manifest.json'))
            @($r.Results).Count | Should -Be 1
            $r.Results[0].EventCount | Should -Be 5
            $r.DurationSec | Should -BeGreaterOrEqual 0
        }

        It 'manifest 列出 evtx 與 action_log.jsonl，且每個雜湊都與最終檔案一致' {
            $r = Invoke-ForensiKit @script:common
            $m = Get-Content -LiteralPath (Join-Path $r.PackageRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            @($m.files | ForEach-Object { $_.path }) | Should -Be @('action_log.jsonl', 'evtx/live/Security.evtx')
            foreach ($f in $m.files) {
                $f.sha256 | Should -Be (Get-RefSha256 -Path (Join-Path $r.PackageRoot ($f.path -replace '/', '\'))) -Because $f.path
            }
        }

        It 'action log：StartCollection → ExportEventLog → CreateManifest，結束後關閉' {
            $r = Invoke-ForensiKit @script:common
            $actions = @([System.IO.File]::ReadAllLines((Join-Path $r.PackageRoot 'action_log.jsonl')) | ForEach-Object { ($_ | ConvertFrom-Json).action })
            $actions | Should -Be @('StartCollection', 'ExportEventLog', 'CreateManifest')
            InModuleScope ForensiKit { Get-FKActionLogPath } | Should -BeNullOrEmpty
        }

        It 'StartCollection 記錄案號、操作者與時段' {
            $r = Invoke-ForensiKit @script:common
            $first = [System.IO.File]::ReadAllLines((Join-Path $r.PackageRoot 'action_log.jsonl'), [System.Text.Encoding]::UTF8)[0] | ConvertFrom-Json
            $first.detail | Should -Match '2026-001'
            $first.detail | Should -Match '王小明'
            $first.detail | Should -Match ([regex]::Escape('2026-11-20T00:00:00Z'))
        }
    }

    Context '參數檢查（throw 且不建立證據包）' {

        It '沒有 -Password 也沒有 -NoEncrypt 時 throw' {
            $p = $script:common.Clone()
            $p.Remove('NoEncrypt')
            { Invoke-ForensiKit @p } | Should -Throw -ExpectedMessage '*-NoEncrypt*'
            @(Get-ChildItem -LiteralPath $script:out).Count | Should -Be 0
        }

        It 'OutputRoot 不存在時 throw' {
            $p = $script:common.Clone()
            $p.OutputRoot = Join-Path $TestDrive 'no-such-dir'
            { Invoke-ForensiKit @p } | Should -Throw
        }

        It '不是系統管理員時 throw，且不建立證據包' {
            Mock Test-FKAdmin -ModuleName ForensiKit { $false }
            { Invoke-ForensiKit @script:common } | Should -Throw -ExpectedMessage '*系統管理員*'
            @(Get-ChildItem -LiteralPath $script:out).Count | Should -Be 0
        }
    }

    Context '狀態與邊界情況' {

        It '案號含檔名不允許的字元時，目錄名稱換成 _，manifest 保留原始案號' {
            $p = $script:common.Clone()
            $p.CaseId = '2026/001:[A]'
            $r = Invoke-ForensiKit @p
            (Split-Path -Leaf $r.PackageRoot) | Should -Match ('^FK_2026_001__A__' + [regex]::Escape($env:COMPUTERNAME) + '_\d{8}T\d{6}Z$')
            (Get-Content -LiteralPath (Join-Path $r.PackageRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).case.caseId | Should -Be '2026/001:[A]'
        }

        It '有 -Password 但加密尚未實作時：Status = Partial，action log 記錄 EncryptPackage Skipped' {
            $p = $script:common.Clone()
            $p.Remove('NoEncrypt')
            $p.Password = New-SecureText 'P@ssw0rd-for-unit-test'
            $r = Invoke-ForensiKit @p
            $r.Status | Should -Be 'Partial'
            $r.PackagePath | Should -BeNullOrEmpty
            $lines = @([System.IO.File]::ReadAllLines((Join-Path $r.PackageRoot 'action_log.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json })
            ($lines | Where-Object { $_.action -eq 'EncryptPackage' }).status | Should -Be 'Skipped'
        }

        It 'Export-FKEventLog throw 時：記成 Failed、Status = Partial，仍產出 manifest' {
            Mock Export-FKEventLog -ModuleName ForensiKit { throw 'boom' }
            $r = Invoke-ForensiKit @script:common
            $r.Status | Should -Be 'Partial'
            $r.Results[0].Status | Should -Be 'Failed'
            $r.ManifestSha256 | Should -Not -BeNullOrEmpty
        }

        It 'New-FKManifest throw 時：Status = Failed、ManifestSha256 = $null，action log 仍會關閉' {
            Mock New-FKManifest -ModuleName ForensiKit { throw 'disk full' }
            $r = Invoke-ForensiKit @script:common -WarningAction SilentlyContinue
            $r.Status | Should -Be 'Failed'
            $r.ManifestSha256 | Should -BeNullOrEmpty
            InModuleScope ForensiKit { Get-FKActionLogPath } | Should -BeNullOrEmpty
        }

        It '呼叫前已開啟的 action log 會在結束後還原' {
            $outer = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $outer | Out-Null
            InModuleScope ForensiKit -Parameters @{ Root = $outer } { param($Root) Open-FKActionLog -PackageRoot $Root } | Out-Null
            try {
                Invoke-ForensiKit @script:common | Out-Null
                InModuleScope ForensiKit { Get-FKActionLogPath } | Should -Be (Join-Path $outer 'action_log.jsonl')
            }
            finally {
                InModuleScope ForensiKit { Close-FKActionLog }
            }
        }
    }
}
