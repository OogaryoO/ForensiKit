<#
    T11：Invoke-ForensiKit 單元測試，依契約第 3、7 節與 TASKS.md T09a / T09。
    所有蒐證步驟都以 Mock 取代，只驗證主流程的串接、狀態彙整與回傳格式。

    分兩組：
      - T09a（最小版本）：需要 Invoke-ForensiKit、Export-FKEventLog、New-FKManifest
      - T09（完整主流程）：另外需要 Get-FKArtifact、Protect-FKPackage
    管理員檢查假設由 Private 函式 Assert-FKAdmin 負責（TASKS.md T01），存在時才 Mock。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skipMin = -not (Test-FKCommandAvailable -Name 'Invoke-ForensiKit', 'Export-FKEventLog', 'New-FKManifest')
    $skipFull = $skipMin -or -not (Test-FKCommandAvailable -Name 'Get-FKArtifact', 'Protect-FKPackage')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null

    $script:start = New-FKUtcDate 2026 11 20 0 0 0
    $script:end = New-FKUtcDate 2026 11 21 0 0 0
    $script:fakeManifestSha = ('ab' * 32)
    $script:fakePkgSha = ('cd' * 32)

    function Set-FKFlowMock {
        <# 以 Mock 取代所有蒐證步驟；-FailExport / -FailArtifact 讓該步驟回傳 Failed #>
        param([switch]$FailExport, [switch]$FailArtifact)

        $global:FKTestFlowOrder = New-Object System.Collections.ArrayList
        if (Test-FKModuleCommand 'Write-FKAction') { Mock Write-FKAction -ModuleName ForensiKit { } }
        if (Test-FKModuleCommand 'Assert-FKAdmin') { Mock Assert-FKAdmin -ModuleName ForensiKit { } }

        # Mock 的本體不一定保留 closure，狀態用全域變數傳入
        $global:FKTestExportStatus = if ($FailExport) { 'Failed' } else { 'OK' }
        $global:FKTestArtifactStatus = if ($FailArtifact) { 'Failed' } else { 'OK' }
        Mock Export-FKEventLog -ModuleName ForensiKit {
            [void]$global:FKTestFlowOrder.Add('Export')
            [pscustomobject]@{ Channel = 'Security'; Source = 'Live'; Path = (Join-Path $Destination 'Security.evtx'); EventCount = 3; Status = $global:FKTestExportStatus }
        }

        Mock New-FKManifest -ModuleName ForensiKit {
            [void]$global:FKTestFlowOrder.Add('Manifest')
            [pscustomobject]@{ ManifestPath = (Join-Path $PackageRoot 'manifest.json'); ManifestSha256 = ('ab' * 32); FileCount = 1 }
        }

        if (Test-FKModuleCommand 'Get-FKArtifact') {
            Mock Get-FKArtifact -ModuleName ForensiKit {
                [void]$global:FKTestFlowOrder.Add('Artifact')
                [pscustomobject]@{ Name = 'Processes'; Path = (Join-Path $Destination 'processes.json'); ItemCount = 10; Status = $global:FKTestArtifactStatus }
            }
        }
        if (Test-FKModuleCommand 'Protect-FKPackage') {
            Mock Protect-FKPackage -ModuleName ForensiKit {
                [void]$global:FKTestFlowOrder.Add('Protect')
                [pscustomobject]@{ PackagePath = ($PackageRoot + '.fkpkg'); Sha256 = ('cd' * 32) }
            }
        }
    }

    function Test-IsUnder {
        <# Child 等於 Parent 或位於其下時回傳 $true #>
        param([string]$Child, [string]$Parent)
        $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
        $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
        return ($c -eq $p) -or $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
    }
}

AfterAll {
    Remove-Variable -Name FKTestFlowOrder, FKTestExportStatus, FKTestArtifactStatus -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-ForensiKit（T09a 最小版本）' -Tag 'T09a' -Skip:$skipMin {

    BeforeEach {
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $out | Out-Null
        $common = @{ CaseId = '2026-001'; Operator = '王小明'; StartUtc = $script:start; EndUtc = $script:end; OutputRoot = $out; NoEncrypt = $true }
    }

    It '回傳契約欄位 PackageRoot、PackagePath、ManifestSha256、Results、DurationSec、Status' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common
        $names = $r.PSObject.Properties.Name
        foreach ($p in 'PackageRoot', 'PackagePath', 'ManifestSha256', 'Results', 'DurationSec', 'Status') { $names | Should -Contain $p }
    }

    # 標題不可用 <...>，Pester 會當成樣板變數展開
    It '在 OutputRoot 下建立「FK_案號_電腦名稱_yyyyMMddTHHmmssZ」目錄（契約第 4 節）' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common
        $r.PackageRoot | Should -Exist
        (Split-Path -Parent ([System.IO.Path]::GetFullPath($r.PackageRoot))) | Should -Be ([System.IO.Path]::GetFullPath($out).TrimEnd('\'))
        $pattern = '^FK_' + [regex]::Escape('2026-001') + '_' + [regex]::Escape($env:COMPUTERNAME) + '_\d{8}T\d{6}Z$'
        (Split-Path -Leaf $r.PackageRoot) | Should -Match $pattern
    }

    It '以相同時段呼叫 Export-FKEventLog，輸出放在證據包內' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common
        Should -Invoke Export-FKEventLog -ModuleName ForensiKit -Times 1 -Exactly -Scope It -ParameterFilter {
            $StartUtc -eq $script:start -and $EndUtc -eq $script:end
        }
        Should -Invoke Export-FKEventLog -ModuleName ForensiKit -Scope It -ParameterFilter { Test-IsUnder -Child $Destination -Parent $r.PackageRoot }
    }

    It '以案號、操作者、時段與證據包路徑呼叫 New-FKManifest，並回傳其 ManifestSha256' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common
        Should -Invoke New-FKManifest -ModuleName ForensiKit -Times 1 -Exactly -Scope It -ParameterFilter {
            $CaseId -eq '2026-001' -and $Operator -eq '王小明' -and $StartUtc -eq $script:start -and $EndUtc -eq $script:end
        }
        $r.ManifestSha256 | Should -Be $script:fakeManifestSha
    }

    It '所有步驟 OK 時 Status = OK' {
        Set-FKFlowMock
        (Invoke-ForensiKit @common).Status | Should -Be 'OK'
    }

    It '匯出步驟 Failed 時 Status = Partial，且仍產出 manifest（TASKS.md T09）' {
        Set-FKFlowMock -FailExport
        $r = Invoke-ForensiKit @common
        $r.Status | Should -Be 'Partial'
        Should -Invoke New-FKManifest -ModuleName ForensiKit -Times 1 -Exactly -Scope It
    }

    It 'Results 含各步驟的回傳結果' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common
        @($r.Results | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Channel' -and $_.Channel -eq 'Security' }).Count | Should -BeGreaterThan 0
    }

    It 'manifest 在匯出之後才產生' {
        Set-FKFlowMock
        Invoke-ForensiKit @common | Out-Null
        $order = @($global:FKTestFlowOrder)
        $order.IndexOf('Manifest') | Should -BeGreaterThan $order.IndexOf('Export')
    }

    It '-NoEncrypt 時不呼叫 Protect-FKPackage' -Skip:$skipFull {
        Set-FKFlowMock
        Invoke-ForensiKit @common | Out-Null
        Should -Invoke Protect-FKPackage -ModuleName ForensiKit -Times 0 -Exactly -Scope It
    }

    It 'StartUtc 晚於 EndUtc 時 throw，且不開始蒐證' {
        Set-FKFlowMock
        $bad = $common.Clone()
        $bad.StartUtc = $script:end
        $bad.EndUtc = $script:start
        { Invoke-ForensiKit @bad } | Should -Throw
        Should -Invoke Export-FKEventLog -ModuleName ForensiKit -Times 0 -Exactly -Scope It
    }

    It '沒有管理員權限時 throw，且不開始蒐證（契約第 3 節）' {
        Set-FKFlowMock
        if (-not (Test-FKModuleCommand 'Assert-FKAdmin')) {
            Set-ItResult -Skipped -Because '模組內沒有 Assert-FKAdmin，需依實際的管理員檢查方式改寫此測試'
            return
        }
        Mock Assert-FKAdmin -ModuleName ForensiKit { throw '需要系統管理員權限' }
        { Invoke-ForensiKit @common } | Should -Throw
        Should -Invoke Export-FKEventLog -ModuleName ForensiKit -Times 0 -Exactly -Scope It
    }
}

Describe 'Invoke-ForensiKit（T09 完整主流程）' -Tag 'T09' -Skip:$skipFull {

    BeforeEach {
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $out | Out-Null
        $common = @{ CaseId = '2026-001'; Operator = '王小明'; StartUtc = $script:start; EndUtc = $script:end; OutputRoot = $out }
        $password = New-FKTestSecureString
    }

    It '以相同時段呼叫 Get-FKArtifact，輸出放在證據包內' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common -NoEncrypt
        Should -Invoke Get-FKArtifact -ModuleName ForensiKit -Scope It -ParameterFilter {
            $StartUtc -eq $script:start -and $EndUtc -eq $script:end -and (Test-IsUnder -Child $Destination -Parent $r.PackageRoot)
        }
    }

    It 'artifact 步驟 Failed 時 Status = Partial，且仍產出 manifest' {
        Set-FKFlowMock -FailArtifact
        $r = Invoke-ForensiKit @common -NoEncrypt
        $r.Status | Should -Be 'Partial'
        Should -Invoke New-FKManifest -ModuleName ForensiKit -Times 1 -Exactly -Scope It
    }

    It '有 -Password 且沒有 -NoEncrypt 時，在 manifest 之後呼叫 Protect-FKPackage 並回傳 PackagePath' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common -Password $password
        Should -Invoke Protect-FKPackage -ModuleName ForensiKit -Times 1 -Exactly -Scope It -ParameterFilter {
            ([System.IO.Path]::GetFullPath($PackageRoot)) -eq ([System.IO.Path]::GetFullPath($r.PackageRoot))
        }
        $r.PackagePath | Should -Be ($r.PackageRoot + '.fkpkg')
        $order = @($global:FKTestFlowOrder)
        $order.IndexOf('Protect') | Should -BeGreaterThan $order.IndexOf('Manifest')
    }

    It '步驟順序：匯出 → artifact → manifest（TASKS.md T09）' {
        Set-FKFlowMock
        Invoke-ForensiKit @common -NoEncrypt | Out-Null
        $order = @($global:FKTestFlowOrder)
        $order.IndexOf('Artifact') | Should -BeGreaterThan $order.IndexOf('Export')
        $order.IndexOf('Manifest') | Should -BeGreaterThan $order.IndexOf('Artifact')
    }

    It 'DurationSec 為非負數（AC1 量測用）' {
        Set-FKFlowMock
        $r = Invoke-ForensiKit @common -NoEncrypt
        $r.DurationSec | Should -Not -BeNullOrEmpty
        [double]$r.DurationSec | Should -BeGreaterOrEqual 0
    }

    It 'Status 只用契約允許的值' {
        Set-FKFlowMock -FailExport -FailArtifact
        $script:FKStatusValues | Should -Contain (Invoke-ForensiKit @common -NoEncrypt).Status
    }

    Context '待確認（等實作或 PM 回覆後再啟用）' {

        It '既沒有 -Password 也沒有 -NoEncrypt 時的行為（throw 或詢問）' -Skip { }

        It '所有步驟都 Failed 時 Status 是 Partial 還是 Failed' -Skip { }
    }
}
