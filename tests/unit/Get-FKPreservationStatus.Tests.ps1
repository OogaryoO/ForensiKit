<#
    T11：Get-FKPreservationStatus（T06）單元測試，依契約第 7 節。
    會讀取排程與 vault 狀態，行為測試要等 T06 合併後 Mock 才能啟用。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Get-FKPreservationStatus')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe 'Get-FKPreservationStatus' -Tag 'T06' -Skip:$skip {

    Context '行為（待 T06 合併後依實作補 Mock 再啟用）' {

        It '回傳 TaskRegistered、LastRunUtc、VaultSizeMB、LogSizes' -Skip { }

        It '未安裝時 TaskRegistered = $false，且不 throw' -Skip { }

        It 'LastRunUtc 為 Kind = Utc 的 [datetime]（或從未執行時為 $null）' -Skip { }

        It 'VaultSizeMB 等於 vault 中所有 .evtx 的總大小（MB）' -Skip { }

        It 'LogSizes 列出設定中每個 channel 目前的上限' -Skip { }
    }
}
