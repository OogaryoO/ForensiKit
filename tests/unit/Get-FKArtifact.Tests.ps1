<#
    T11：Get-FKArtifact（T05）單元測試，依契約第 4、7 節與 TASKS.md T05。

    七種 artifact 都會讀取系統狀態（行程、網路、DNS、排程、服務、登錄檔、Prefetch）。
    單元測試不得在實體電腦上真的蒐證，所以行為測試要等 T05 合併、確認實作呼叫了哪些
    cmdlet 之後，把它們全部 Mock 掉才能啟用；目前先列為 -Skip 的待辦項目。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Get-FKArtifact')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe 'Get-FKArtifact' -Tag 'T05' -Skip:$skip {

    Context '參數驗證（不會觸發蒐證）' {

        It '-Name 不是契約列出的 7 種之一時 throw' {
            if (Test-FKModuleCommand 'Write-FKAction') { Mock Write-FKAction -ModuleName ForensiKit { } }
            $dest = Join-Path $TestDrive 'artifacts'
            { Get-FKArtifact -StartUtc (New-FKUtcDate 2026 11 20) -EndUtc (New-FKUtcDate 2026 11 21) -Destination $dest -Name 'NoSuchArtifact' } |
                Should -Throw
        }
    }

    Context '行為（待 T05 合併後依實作補 Mock 再啟用）' {

        It '未指定 -Name 時回傳 7 筆（Prefetch、ScheduledTasks、Services、Autoruns、Processes、NetworkConnections、DnsCache）' -Skip { }

        It '每筆回傳含 Name、Path、ItemCount、Status，Status 只用契約允許的值' -Skip { }

        It '-Name 指定子集合時只回傳那幾種' -Skip { }

        It '輸出檔名符合契約第 4 節（artifacts/processes.json 等，Prefetch 放 artifacts/prefetch/）' -Skip { }

        It 'Prefetch 只複製 LastWriteTimeUtc 落在 [StartUtc, EndUtc] 的 .pf（含邊界）' -Skip { }

        It '可執行檔附 SHA-256；檔案不存在或無權限時填 null，不中斷' -Skip { }

        It '自啟項涵蓋 HKLM/HKCU 的 Run、RunOnce 與兩個 Startup 資料夾' -Skip { }

        It '單一 artifact 收集失敗時該筆 Status = Failed，其他照常收集，且不 throw' -Skip { }

        It '每種 artifact 都寫 action log' -Skip { }

        It '輸出 JSON 為 UTF-8，中文路徑與名稱不亂碼' -Skip { }
    }
}
