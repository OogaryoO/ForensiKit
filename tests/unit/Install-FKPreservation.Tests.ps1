<#
    T11：Install-FKPreservation（T06）單元測試，依契約第 5、6、7 節與 TASKS.md T06。

    安裝會改 log 上限、註冊 SYSTEM 排程、設定 ACL，絕不能在實體電腦上真的執行。
    行為測試要等 T06 合併、確認呼叫了哪些 cmdlet / 外部指令後全部 Mock 才能啟用；
    參數契約已由 Contract.Parameters.Tests.ps1 檢查。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Install-FKPreservation')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe 'Install-FKPreservation' -Tag 'T06' -Skip:$skip {

    Context '行為（待 T06 合併後依實作補 Mock 再啟用）' {

        It '回傳 LogSizesApplied、VaultRoot、TaskRegistered、Status' -Skip { }

        It '依設定以 wevtutil sl 〈channel〉 /ms:〈bytes〉 加大 log 上限（Security 512 MB、其他 128 MB）' -Skip { }

        It '註冊 SYSTEM 排程工作 \ForensiKit\VaultBackup，間隔為 vaultIntervalMinutes' -Skip { }

        It 'vault ACL：SYSTEM 完全控制、Administrators 唯讀、其他人無權限、不繼承' -Skip { }

        It '-ConfigPath 指定的設定會被採用' -Skip { }

        It '重複安裝不會 throw，也不會註冊第二個排程（冪等）' -Skip { }

        It '單一 channel 設定失敗時 Status = Partial，其他照常套用' -Skip { }

        It '每個變更動作都寫 action log' -Skip { }
    }
}
