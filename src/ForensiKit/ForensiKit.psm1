# ForensiKit 模組載入器（T01）
# - 先 dot-source Private/ 再 Public/ 下所有 .ps1
# - 只匯出 Public/ 的函式（檔名＝函式名，見 docs/ARCHITECTURE.md 第 2 節）

$script:FKModuleRoot = $PSScriptRoot

# 目前證據包的 action log 路徑；由 Open-FKActionLog 設定、Close-FKActionLog 清除（見 Private/）
$script:FKActionLogPath = $null

$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$publicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

foreach ($file in ($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "ForensiKit 無法載入 $($file.FullName)：$($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @($publicFiles | ForEach-Object { $_.BaseName })
