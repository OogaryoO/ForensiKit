<#
    T09a／T09：Invoke-ForensiKit 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11 Invoke-ForensiKit.Tests.ps1）。
    Mock wevtutil、Get-WinEvent、Get-FKConfig、Get-FKArtifact 與管理員檢查，不會在實體電腦上蒐證；
    Export-FKEventLog 與 New-FKManifest 用真的實作串起來。檔案只寫在 TestDrive。
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

    # 假的 vault：只有 Security 有一份時段內的備份
    $script:vaultRoot = Join-Path $TestDrive 'vault'
    New-Item -ItemType Directory -Path (Join-Path $script:vaultRoot 'Security') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $script:vaultRoot 'Security\20261120T050000Z.evtx'), 'fake-backup')

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

    function Read-Actions([string]$PackageRoot) {
        @([System.IO.File]::ReadAllLines((Join-Path $PackageRoot 'action_log.jsonl'), [System.Text.Encoding]::UTF8) | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

AfterAll {
    Remove-Variable -Name FKTestArtifactStatus -Scope Global -ErrorAction SilentlyContinue
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'Invoke-ForensiKit 實作細節（T09）' -Tag 'T09a', 'T09' {

    BeforeEach {
        Mock wevtutil -ModuleName ForensiKit $script:fakeWevtutil
        Mock Get-WinEvent -ModuleName ForensiKit -ParameterFilter { $null -ne $Path } { 1..5 | ForEach-Object { [pscustomobject]@{ Id = 4624 } } }
        Mock Test-FKAdmin -ModuleName ForensiKit { $true }
        Mock Get-FKConfig -ModuleName ForensiKit {
            [pscustomobject]@{
                channels            = @('Security', 'Microsoft-Windows-Sysmon/Operational')
                defaultLookbackDays = 7
                preservation        = [pscustomobject]@{ logMaxSizeMB = [pscustomobject]@{ default = 128 }; vaultRoot = $script:vaultRoot; vaultIntervalMinutes = 60; vaultMaxTotalMB = 2048 }
            }
        }
        $global:FKTestArtifactStatus = 'OK'
        Mock Get-FKArtifact -ModuleName ForensiKit {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            $p = Join-Path $Destination 'processes.json'
            [System.IO.File]::WriteAllText($p, '[]')
            [pscustomobject]@{ Name = 'Processes'; Path = $p; ItemCount = 0; Status = $global:FKTestArtifactStatus }
        }
        $script:out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:out | Out-Null
        $script:common = @{ CaseId = '2026-001'; Operator = '王小明'; StartUtc = $script:start; EndUtc = $script:end; OutputRoot = $script:out; NoEncrypt = $true }
    }

    Context '端到端（真的 Export-FKEventLog 與 New-FKManifest）' {

        It '設定中的每個 channel、vault 與 artifact 都進證據包；Skipped 的 vault 不影響 Status' {
            $r = Invoke-ForensiKit @script:common
            $r.Status | Should -Be 'OK'
            $r.PackagePath | Should -BeNullOrEmpty
            @($r.Results | Where-Object { $_.Source -eq 'Live' } | ForEach-Object Channel) | Should -Be @('Security', 'Microsoft-Windows-Sysmon/Operational')
            ($r.Results | Where-Object { $_.Source -eq 'Vault' -and $_.Channel -eq 'Security' }).Status | Should -Be 'OK'
            ($r.Results | Where-Object { $_.Source -eq 'Vault' -and $_.Channel -like '*Sysmon*' }).Status | Should -Be 'Skipped'
            ($r.Results | Where-Object { $_.Name -eq 'Processes' }).Status | Should -Be 'OK'
            $r.ManifestSha256 | Should -Be (Get-RefSha256 -Path (Join-Path $r.PackageRoot 'manifest.json'))
            $r.DurationSec | Should -BeGreaterOrEqual 0
        }

        It 'manifest 列出所有檔案，且每個雜湊都與最終檔案一致；Test-FKPackage 通過' {
            $r = Invoke-ForensiKit @script:common
            $m = Get-Content -LiteralPath (Join-Path $r.PackageRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            @($m.files | ForEach-Object { $_.path }) | Should -Be @(
                'action_log.jsonl'
                'artifacts/processes.json'
                'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx'
                'evtx/live/Security.evtx'
                'evtx/vault/Security/20261120T050000Z.evtx'
            )
            foreach ($f in $m.files) {
                $f.sha256 | Should -Be (Get-RefSha256 -Path (Join-Path $r.PackageRoot ($f.path -replace '/', '\'))) -Because $f.path
            }
            (Test-FKPackage -PackageRoot $r.PackageRoot).IsValid | Should -BeTrue
        }

        It '呼叫參數：Export-FKEventLog 用設定中的 channel 並含 vault；Get-FKArtifact 輸出到證據包的 artifacts' {
            $r = Invoke-ForensiKit @script:common
            Should -Invoke Get-FKArtifact -ModuleName ForensiKit -Times 1 -Exactly -Scope It -ParameterFilter {
                $Destination -eq (Join-Path $r.PackageRoot 'artifacts') -and $StartUtc -eq $script:start -and $EndUtc -eq $script:end
            }
            Should -Invoke wevtutil -ModuleName ForensiKit -Scope It -ParameterFilter { ($args -join ' ') -match '/lf:true' }
        }

        It 'action log：StartCollection 開頭、CreateManifest 結尾，中間有 live 與 vault 匯出；結束後關閉' {
            $r = Invoke-ForensiKit @script:common
            $actions = @(Read-Actions $r.PackageRoot | ForEach-Object action)
            $actions[0] | Should -Be 'StartCollection'
            $actions[-1] | Should -Be 'CreateManifest'
            $actions | Should -Contain 'ExportEventLog'
            $actions | Should -Contain 'ExportVaultEventLog'
            InModuleScope ForensiKit { Get-FKActionLogPath } | Should -BeNullOrEmpty
        }

        It 'StartCollection 記錄案號、操作者與時段' {
            $r = Invoke-ForensiKit @script:common
            $first = (Read-Actions $r.PackageRoot)[0]
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

        It '有 -Password：manifest 之後加密成 .fkpkg，解密後與明文證據包一致且通過 Test-FKPackage' {
            $p = $script:common.Clone()
            $p.Remove('NoEncrypt')
            $p.Password = New-SecureText 'P@ssw0rd-for-unit-test'
            $r = Invoke-ForensiKit @p
            $r.Status | Should -Be 'OK'
            $r.PackagePath | Should -Be ($r.PackageRoot + '.fkpkg')
            $r.PackagePath | Should -Exist
            ($r.Results | Where-Object { $_.Name -eq 'EncryptPackage' }).Status | Should -Be 'OK'
            (Test-FKPackage -PackageRoot $r.PackageRoot).IsValid | Should -BeTrue -Because '加密不得改動明文證據包（manifest 之後不寫 action log）'
            $restored = Unprotect-FKPackage -Path $r.PackagePath -Password $p.Password -Destination (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            (Test-FKPackage -PackageRoot $restored.PackageRoot).IsValid | Should -BeTrue
        }

        It '加密時 action log：EncryptPackage 寫在 CreateManifest 之前，之後沒有任何紀錄' {
            $p = $script:common.Clone()
            $p.Remove('NoEncrypt')
            $p.Password = New-SecureText 'P@ssw0rd-for-unit-test'
            $r = Invoke-ForensiKit @p
            $actions = @(Read-Actions $r.PackageRoot | ForEach-Object action)
            $actions.IndexOf('EncryptPackage') | Should -BeLessThan $actions.IndexOf('CreateManifest')
            $actions[-1] | Should -Be 'CreateManifest'
            ((Read-Actions $r.PackageRoot) | Where-Object { $_.action -eq 'EncryptPackage' }).detail | Should -Match 'manifest 之後'
        }

        It '-NoEncrypt 時不呼叫 Protect-FKPackage，也不寫 EncryptPackage' {
            Mock Protect-FKPackage -ModuleName ForensiKit { throw 'should not be called' }
            $r = Invoke-ForensiKit @script:common
            Should -Invoke Protect-FKPackage -ModuleName ForensiKit -Times 0 -Exactly -Scope It
            @(Read-Actions $r.PackageRoot | ForEach-Object action) | Should -Not -Contain 'EncryptPackage'
        }

        It '加密失敗時：PackagePath = $null、Status = Partial、明文證據包保留' {
            Mock Protect-FKPackage -ModuleName ForensiKit { throw 'disk full' }
            $p = $script:common.Clone()
            $p.Remove('NoEncrypt')
            $p.Password = New-SecureText 'P@ssw0rd-for-unit-test'
            $r = Invoke-ForensiKit @p -WarningAction SilentlyContinue
            $r.Status | Should -Be 'Partial'
            $r.PackagePath | Should -BeNullOrEmpty
            ($r.Results | Where-Object { $_.Name -eq 'EncryptPackage' }).Status | Should -Be 'Failed'
            (Test-FKPackage -PackageRoot $r.PackageRoot).IsValid | Should -BeTrue
        }

        It 'artifact 步驟 Failed 時 Status = Partial，仍產出 manifest' {
            $global:FKTestArtifactStatus = 'Failed'
            $r = Invoke-ForensiKit @script:common
            $r.Status | Should -Be 'Partial'
            $r.ManifestSha256 | Should -Not -BeNullOrEmpty
        }

        It 'Export-FKEventLog throw 時：記成 Failed、Status = Partial，artifact 照常收集，仍產出 manifest' {
            Mock Export-FKEventLog -ModuleName ForensiKit { throw 'boom' }
            $r = Invoke-ForensiKit @script:common
            $r.Status | Should -Be 'Partial'
            $r.Results[0].Status | Should -Be 'Failed'
            Should -Invoke Get-FKArtifact -ModuleName ForensiKit -Times 1 -Exactly -Scope It
            $r.ManifestSha256 | Should -Not -BeNullOrEmpty
        }

        It 'Get-FKArtifact throw 時：記成 Failed、Status = Partial，仍產出 manifest' {
            Mock Get-FKArtifact -ModuleName ForensiKit { throw 'artifact boom' }
            $r = Invoke-ForensiKit @script:common
            $r.Status | Should -Be 'Partial'
            @($r.Results | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 1
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
