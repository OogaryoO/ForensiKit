<#
    T01：模組骨架與共用輔助函式的測試（由 T01 開發者撰寫；各公開函式的契約測試見 QA 的 T11）。
    不碰觸真實系統，檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe '模組載入（T01）' -Tag 'T01' {

    It 'Test-ModuleManifest 通過，版本為 0.1.0' {
        $m = Test-ModuleManifest -Path $script:ModulePath -ErrorAction Stop
        $m.Version.ToString() | Should -Be '0.1.0'
    }

    It '只匯出 Public/ 下的函式' {
        $publicDir = Join-Path $PSScriptRoot '..\..\src\ForensiKit\Public'
        $expected = @(Get-ChildItem -Path $publicDir -Filter '*.ps1' -File | ForEach-Object { $_.BaseName } | Sort-Object)
        $exported = @((Get-Module ForensiKit).ExportedFunctions.Keys | Sort-Object)
        $exported | Should -Be $expected
    }

    It 'Private 函式不匯出' {
        foreach ($name in 'Assert-FKAdmin', 'Test-FKAdmin', 'Open-FKActionLog', 'Close-FKActionLog', 'ConvertTo-FKIsoUtc', 'ConvertTo-FKSafeChannelName') {
            Get-Command -Name $name -Module ForensiKit -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$name 是內部函式"
        }
    }
}

Describe 'Get-FKConfig（T01）' -Tag 'T01' {

    It '不帶參數時讀取內建 default-profile.json' {
        $cfg = Get-FKConfig
        @($cfg.channels) | Should -Contain 'Security'
        $cfg.defaultLookbackDays | Should -Be 7
        $cfg.preservation.logMaxSizeMB.Security | Should -Be 512
        $cfg.preservation.vaultRoot | Should -Be 'C:\ProgramData\ForensiKit\vault'
    }

    It '缺少必要欄位時 throw 並列出欄位' {
        $p = Join-Path $TestDrive 'partial.json'
        [System.IO.File]::WriteAllText($p, '{"channels":["Security"]}')
        { Get-FKConfig -Path $p } | Should -Throw -ExpectedMessage '*defaultLookbackDays*preservation*'
    }

    It '不存在的檔案 throw' {
        { Get-FKConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw
    }

    It '不合法的 JSON throw' {
        $p = Join-Path $TestDrive 'bad.json'
        [System.IO.File]::WriteAllText($p, '{ not json')
        { Get-FKConfig -Path $p } | Should -Throw
    }
}

Describe 'Write-FKAction 與 action log（T01）' -Tag 'T01' {

    BeforeEach {
        $script:Pkg = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Pkg | Out-Null
        $script:LogPath = InModuleScope ForensiKit -Parameters @{ Root = $script:Pkg } { param($Root) Open-FKActionLog -PackageRoot $Root }
    }

    AfterEach {
        InModuleScope ForensiKit { Close-FKActionLog }
    }

    It 'Open-FKActionLog 建立 <PackageRoot>\action_log.jsonl' {
        $script:LogPath | Should -Be (Join-Path $script:Pkg 'action_log.jsonl')
        $script:LogPath | Should -Exist
    }

    It '每次呼叫附加一行 JSON，欄位與順序符合契約' {
        Write-FKAction -Action 'ExportEventLog' -Target 'Security' -Detail 'wevtutil epl Security x.evtx' -Status 'OK'
        Write-FKAction -Action 'CopyPrefetch' -Target 'C:\Windows\Prefetch' -Detail '' -Status 'Skipped'

        $lines = @([System.IO.File]::ReadAllLines($script:LogPath))
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '^\{"timeUtc":"[^"]+","action":"ExportEventLog","target":"Security","detail":"[^"]*","status":"OK"\}$'

        $second = $lines[1] | ConvertFrom-Json
        $second.action | Should -Be 'CopyPrefetch'
        $second.status | Should -Be 'Skipped'
        $second.detail | Should -Be ''
    }

    It 'timeUtc 為 ISO 8601 UTC（結尾 Z）且接近現在' {
        Write-FKAction -Action 'A' -Target 'T' -Detail 'D' -Status 'OK'
        $line = [System.IO.File]::ReadAllLines($script:LogPath)[0]
        $raw = [regex]::Match($line, '"timeUtc":"([^"]+)"').Groups[1].Value
        $raw | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $t = [datetime]::ParseExact($raw, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
        ([datetime]::UtcNow - $t).TotalSeconds | Should -BeLessThan 60
    }

    It '中文、引號、反斜線與換行都能正確往返，檔案為無 BOM 的 UTF-8' {
        $detail = "操作者：王小明`r`n路徑 C:\Windows\System32 與 ""引號"""
        Write-FKAction -Action '測試' -Target '中文目標' -Detail $detail -Status 'Partial'

        $bytes = [System.IO.File]::ReadAllBytes($script:LogPath)
        ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should -Not -Be 'EFBBBF'

        $lines = @([System.IO.File]::ReadAllLines($script:LogPath, [System.Text.Encoding]::UTF8))
        $lines.Count | Should -Be 1
        $obj = $lines[0] | ConvertFrom-Json
        $obj.action | Should -Be '測試'
        $obj.target | Should -Be '中文目標'
        $obj.detail | Should -Be $detail
    }

    It '再次 Open 同一個證據包時附加而不清空' {
        Write-FKAction -Action 'A' -Target '' -Detail '' -Status 'OK'
        InModuleScope ForensiKit -Parameters @{ Root = $script:Pkg } { param($Root) Open-FKActionLog -PackageRoot $Root } | Out-Null
        Write-FKAction -Action 'B' -Target '' -Detail '' -Status 'OK'
        @([System.IO.File]::ReadAllLines($script:LogPath)).Count | Should -Be 2
    }

    It 'Status 不在允許值內時 throw' {
        { Write-FKAction -Action 'A' -Target 'T' -Detail 'D' -Status 'Bogus' } | Should -Throw
    }

    It 'Close-FKActionLog 之後不寫檔也不 throw' {
        InModuleScope ForensiKit { Close-FKActionLog }
        { Write-FKAction -Action 'A' -Target 'T' -Detail 'D' -Status 'OK' } | Should -Not -Throw
        @([System.IO.File]::ReadAllLines($script:LogPath)).Count | Should -Be 0
    }

    It 'Open-FKActionLog 遇到不存在的目錄時 throw' {
        { InModuleScope ForensiKit -Parameters @{ Root = (Join-Path $TestDrive 'missing') } { param($Root) Open-FKActionLog -PackageRoot $Root } } | Should -Throw
    }
}

Describe '內部輔助函式（T01）' -Tag 'T01' {

    It 'ConvertTo-FKIsoUtc：UTC 時間轉 ISO 8601' {
        InModuleScope ForensiKit {
            $d = New-Object datetime 2026, 11, 20, 3, 15, 0, ([DateTimeKind]::Utc)
            ConvertTo-FKIsoUtc -Date $d | Should -Be '2026-11-20T03:15:00Z'
        }
    }

    It 'ConvertTo-FKIsoUtc：Local 時間先轉成 UTC' {
        InModuleScope ForensiKit {
            $utc = New-Object datetime 2026, 11, 20, 3, 15, 0, ([DateTimeKind]::Utc)
            ConvertTo-FKIsoUtc -Date $utc.ToLocalTime() | Should -Be '2026-11-20T03:15:00Z'
        }
    }

    It 'ConvertTo-FKSafeChannelName：/ 改為 %4' {
        InModuleScope ForensiKit {
            ConvertTo-FKSafeChannelName -Channel 'Microsoft-Windows-Sysmon/Operational' | Should -Be 'Microsoft-Windows-Sysmon%4Operational'
            ConvertTo-FKSafeChannelName -Channel 'Security' | Should -Be 'Security'
        }
    }

    It 'Assert-FKAdmin：非管理員時 throw' {
        InModuleScope ForensiKit {
            Mock Test-FKAdmin { $false }
            { Assert-FKAdmin } | Should -Throw -ExpectedMessage '*系統管理員*'
        }
    }

    It 'Assert-FKAdmin：管理員時不 throw' {
        InModuleScope ForensiKit {
            Mock Test-FKAdmin { $true }
            { Assert-FKAdmin } | Should -Not -Throw
        }
    }
}
