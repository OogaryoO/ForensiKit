<#
    T07：Test-FKPackage 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11 Test-FKPackage.Tests.ps1）。
    證據包用真的 New-FKManifest 產生，驗證兩者互通。檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:start = New-Object datetime 2026, 11, 20, 0, 0, 0, ([DateTimeKind]::Utc)
    $script:end = New-Object datetime 2026, 11, 21, 0, 0, 0, ([DateTimeKind]::Utc)

    function New-RealPackage {
        # 用 New-FKManifest 產生含 action_log.jsonl 與 chain_of_custody.txt 的證據包
        $root = Join-Path $TestDrive ('FK_2026-001_UNIT_' + [guid]::NewGuid().ToString('N'))
        foreach ($rel in 'evtx/live/Security.evtx', 'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx', 'artifacts/processes.json', 'artifacts/說明.txt') {
            $full = Join-Path $root ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [System.IO.File]::WriteAllText($full, "content of $rel")
        }
        InModuleScope ForensiKit -Parameters @{ Root = $root } { param($Root) Open-FKActionLog -PackageRoot $Root } | Out-Null
        try {
            Write-FKAction -Action 'ExportEventLog' -Target 'Security' -Detail 'wevtutil epl ...' -Status 'OK'
            New-FKManifest -PackageRoot $root -CaseId '2026-001' -Operator '王小明' -StartUtc $script:start -EndUtc $script:end | Out-Null
        }
        finally {
            InModuleScope ForensiKit { Close-FKActionLog }
        }
        return $root
    }

    function Get-Sha([string]$Path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })) }
        finally { $sha.Dispose() }
    }

    function Edit-Manifest([string]$Root, [scriptblock]$Change) {
        $p = Join-Path $Root 'manifest.json'
        $m = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        & $Change $m
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $m -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'Test-FKPackage 實作細節（T07）' -Tag 'T07', 'AC6' {

    It 'New-FKManifest 產生的證據包（含 action_log.jsonl、chain_of_custody.txt、中文檔名）驗證通過' {
        $r = Test-FKPackage -PackageRoot (New-RealPackage)
        $r.IsValid | Should -BeTrue
        $r.Extra.Count | Should -Be 0
    }

    It '三個清單在沒有問題時是空的 string[]（不是 $null）' {
        $r = Test-FKPackage -PackageRoot (New-RealPackage)
        , $r.Mismatched | Should -BeOfType [string[]]
        , $r.Missing | Should -BeOfType [string[]]
        , $r.Extra | Should -BeOfType [string[]]
    }

    It '同時竄改檔案與 manifest（重算雜湊）時，chain_of_custody.txt 的 manifest 雜湊會抓到' {
        $root = New-RealPackage
        $target = Join-Path $root 'evtx\live\Security.evtx'
        [System.IO.File]::WriteAllText($target, 'forged')
        $newSha = Get-Sha $target
        $newSize = (Get-Item -LiteralPath $target).Length
        $change = {
            param($m)
            foreach ($f in $m.files) { if ($f.path -eq 'evtx/live/Security.evtx') { $f.sha256 = $newSha; $f.size = $newSize } }
        }.GetNewClosure()
        Edit-Manifest -Root $root -Change $change
        $r = Test-FKPackage -PackageRoot $root
        $r.IsValid | Should -BeFalse
        $r.Mismatched | Should -Contain 'manifest.json'
        $r.Mismatched | Should -Not -Contain 'evtx/live/Security.evtx'
    }

    It '竄改 action_log.jsonl 也會被抓到' {
        $root = New-RealPackage
        [System.IO.File]::AppendAllText((Join-Path $root 'action_log.jsonl'), '{"action":"forged"}' + "`n")
        (Test-FKPackage -PackageRoot $root).Mismatched | Should -Contain 'action_log.jsonl'
    }

    It 'manifest.json 不存在：Missing 含 manifest.json，所有檔案都算 Extra，不 throw' {
        $root = New-RealPackage
        Remove-Item -LiteralPath (Join-Path $root 'manifest.json')
        $r = Test-FKPackage -PackageRoot $root
        $r.IsValid | Should -BeFalse
        $r.Missing | Should -Contain 'manifest.json'
        $r.Extra | Should -Contain 'evtx/live/Security.evtx'
    }

    It 'manifest.json 不是合法 JSON：Mismatched 含 manifest.json，不 throw' {
        $root = New-RealPackage
        [System.IO.File]::WriteAllText((Join-Path $root 'manifest.json'), '{ broken')
        $r = Test-FKPackage -PackageRoot $root
        $r.IsValid | Should -BeFalse
        $r.Mismatched | Should -Contain 'manifest.json'
    }

    It 'manifest 中指向證據包外面的路徑（.. 或絕對路徑）列為 Mismatched，不會去讀那個檔案' {
        $root = New-RealPackage
        $outside = Join-Path $TestDrive 'outside.txt'
        [System.IO.File]::WriteAllText($outside, 'outside')
        $outsideSha = Get-Sha $outside
        $change = {
            param($m)
            $m.files += [pscustomobject]@{ path = '../outside.txt'; sha256 = $outsideSha; size = 7; source = $null; collector = $null; status = 'OK' }
            $m.files += [pscustomobject]@{ path = $outside; sha256 = $outsideSha; size = 7; source = $null; collector = $null; status = 'OK' }
        }.GetNewClosure()
        Edit-Manifest -Root $root -Change $change
        # 改了 manifest，chain_of_custody 的雜湊也會不符，這裡只檢查路徑本身
        $r = Test-FKPackage -PackageRoot $root
        $r.Mismatched | Should -Contain '../outside.txt'
        $r.Mismatched | Should -Contain $outside
    }

    It 'manifest 中 sha256 為 null（收集時無法讀取）的檔案列為 Mismatched' {
        $root = New-RealPackage
        Remove-Item -LiteralPath (Join-Path $root 'chain_of_custody.txt')
        Edit-Manifest -Root $root -Change { param($m) $m.files[0].sha256 = $null }
        $r = Test-FKPackage -PackageRoot $root
        $r.Mismatched.Count | Should -Be 1
    }

    It '目前開啟的 action log 在受驗證的證據包內時，不寫 action log（不會改到 action_log.jsonl）' {
        $root = New-RealPackage
        $before = Get-Sha (Join-Path $root 'action_log.jsonl')
        InModuleScope ForensiKit -Parameters @{ Root = $root } { param($Root) Open-FKActionLog -PackageRoot $Root } | Out-Null
        try { $r = Test-FKPackage -PackageRoot $root }
        finally { InModuleScope ForensiKit { Close-FKActionLog } }
        $r.IsValid | Should -BeTrue
        Get-Sha (Join-Path $root 'action_log.jsonl') | Should -Be $before
    }

    It 'action log 開在別處時，寫一筆 VerifyPackage' {
        $root = New-RealPackage
        $other = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other | Out-Null
        $log = InModuleScope ForensiKit -Parameters @{ Root = $other } { param($Root) Open-FKActionLog -PackageRoot $Root }
        try { Test-FKPackage -PackageRoot $root | Out-Null }
        finally { InModuleScope ForensiKit { Close-FKActionLog } }
        ([System.IO.File]::ReadAllLines($log)[-1] | ConvertFrom-Json).action | Should -Be 'VerifyPackage'
    }
}
