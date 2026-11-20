<#
    T11：Uninstall-FKPreservation（T06）單元測試，依契約第 7 節與 TASKS.md T06。
    會刪除排程與 vault，行為測試要等 T06 合併後全部 Mock 才能啟用。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Uninstall-FKPreservation')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe 'Uninstall-FKPreservation' -Tag 'T06' -Skip:$skip {

    Context '行為（待 T06 合併後依實作補 Mock 再啟用）' {

        It '回傳 { Status }，Status 只用契約允許的值' -Skip { }

        It '刪除排程工作 \ForensiKit\VaultBackup' -Skip { }

        It '沒有 -KeepVault 時刪除 vault 目錄' -Skip { }

        It '-KeepVault 時保留 vault 目錄與其中的備份檔' -Skip { }

        It '尚未安裝時執行不 throw' -Skip { }

        It '刪除 vault 前有確認機制（SupportsShouldProcess / -Confirm）' -Skip { }
    }
}
