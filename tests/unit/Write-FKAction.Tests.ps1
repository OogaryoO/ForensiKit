<#
    T11：Write-FKAction（T01）單元測試，依契約第 4 節 action_log.jsonl 格式。

    契約只說「寫入目前證據包的 action_log.jsonl」，沒有定義「目前證據包」怎麼指定
    （模組變數？Start 函式？參數？）。因此實際寫檔的測試先標 -Skip，
    等 T01 合併、確認機制後再把 Set-CurrentPackage 補上並啟用。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Write-FKAction')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe 'Write-FKAction' -Tag 'T01' -Skip:$skip {

    Context '參數驗證' {

        It 'Status 不是 OK / Partial / Failed / Skipped 時 throw（契約第 3 節）' {
            { Write-FKAction -Action 'Test' -Target 'x' -Detail 'y' -Status 'Bogus' } | Should -Throw
        }
    }

    Context '寫入 action_log.jsonl（待 T01 確認「目前證據包」的指定方式）' {

        It '每次呼叫附加一行 JSON，含 timeUtc、action、target、detail、status' -Skip { }

        It 'timeUtc 為 ISO 8601 UTC 字串（結尾 Z）' -Skip { }

        It '連續呼叫是附加而不是覆寫（行數遞增）' -Skip { }

        It 'detail 含中文、引號、反斜線與換行時，每行仍是合法 JSON 且內容不變' -Skip { }

        It '檔案為 UTF-8，中文不亂碼' -Skip { }

        It '尚未指定證據包時的行為（throw 或寫到暫存位置）' -Skip { }
    }
}
