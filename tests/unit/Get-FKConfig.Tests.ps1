<#
    T11：Get-FKConfig（T01）單元測試，依契約第 6 節設定檔結構。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Get-FKConfig')
    $defaultProfile = Join-Path $script:FKRepoRoot 'src\ForensiKit\config\default-profile.json'
    $skipProfile = -not (Test-Path -LiteralPath $defaultProfile)
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
    $script:defaultProfile = Join-Path $script:FKRepoRoot 'src\ForensiKit\config\default-profile.json'

    function Assert-ConfigShape {
        param($Config)
        $Config | Should -Not -BeNullOrEmpty
        @($Config.channels).Count | Should -BeGreaterThan 0
        [int]$Config.defaultLookbackDays | Should -BeGreaterThan 0
        $Config.preservation | Should -Not -BeNullOrEmpty
        $Config.preservation.logMaxSizeMB | Should -Not -BeNullOrEmpty
        [string]$Config.preservation.vaultRoot | Should -Not -BeNullOrEmpty
        [int]$Config.preservation.vaultIntervalMinutes | Should -BeGreaterThan 0
        [int]$Config.preservation.vaultMaxTotalMB | Should -BeGreaterThan 0
    }
}

Describe 'config/default-profile.json（契約第 6 節）' -Tag 'T01' -Skip:$skipProfile {

    It '是合法 JSON，且含契約要求的欄位' {
        $cfg = Get-Content -LiteralPath $script:defaultProfile -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-ConfigShape -Config $cfg
    }

    It 'channels 至少包含 Security' {
        $cfg = Get-Content -LiteralPath $script:defaultProfile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($cfg.channels) | Should -Contain 'Security'
    }

    It 'logMaxSizeMB 有 Security 與 default 兩個鍵' {
        $cfg = Get-Content -LiteralPath $script:defaultProfile -Raw -Encoding UTF8 | ConvertFrom-Json
        $keys = $cfg.preservation.logMaxSizeMB.PSObject.Properties.Name
        $keys | Should -Contain 'Security'
        $keys | Should -Contain 'default'
    }
}

Describe 'Get-FKConfig' -Tag 'T01' -Skip:$skip {

    It '不帶參數時回傳預設設定，結構符合契約第 6 節' {
        Assert-ConfigShape -Config (Get-FKConfig)
    }

    It '-Path 指定的設定檔內容會被讀出' {
        $custom = Join-Path $TestDrive 'custom-profile.json'
        $obj = New-FKTestConfig -Channels 'Security', 'System' -VaultRoot 'D:\FK-UNIT-TEST\vault'
        [System.IO.File]::WriteAllText($custom, ($obj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
        $cfg = Get-FKConfig -Path $custom
        Assert-ConfigShape -Config $cfg
        @($cfg.channels) | Should -Be @('Security', 'System')
        $cfg.preservation.vaultRoot | Should -Be 'D:\FK-UNIT-TEST\vault'
    }

    It '有 BOM 與無 BOM 的 UTF-8 設定檔都能讀' {
        $obj = New-FKTestConfig
        $noBom = Join-Path $TestDrive 'nobom.json'
        [System.IO.File]::WriteAllText($noBom, ($obj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Assert-ConfigShape -Config (Get-FKConfig -Path $noBom)
    }

    It '-Path 指向不存在的檔案時 throw（參數錯誤）' {
        { Get-FKConfig -Path (Join-Path $TestDrive 'no-such.json') } | Should -Throw
    }

    It '-Path 指向不是合法 JSON 的檔案時 throw' {
        $bad = Join-Path $TestDrive 'bad.json'
        [System.IO.File]::WriteAllText($bad, '{ not json')
        { Get-FKConfig -Path $bad } | Should -Throw
    }
}
