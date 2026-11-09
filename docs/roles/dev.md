# 角色：主力開發 — YuChenKUO（郭宥真）

> 給 YuChenKUO 的 AI agent：你的使用者負責約 70% 的開發，是蒐證核心的實作者。讀完本檔後依 `AGENTS.md` 的規則工作。

## 你負責的任務

| 任務 | 週次 | 說明 |
|---|---|---|
| T04 | W11 | `Export-FKEventLog`：以 wevtutil 依時段匯出 EVTX，含 vault |
| T05 | W11 | `Get-FKArtifact`：Prefetch、排程、服務、自啟項、行程、網路連線、DNS 快取 |
| T07 | W12 | `New-FKManifest`、`Test-FKPackage`、`chain_of_custody.txt` |
| T08 | W12 | `Protect-/Unprotect-FKPackage`（AES-256 ＋ PBKDF2 ＋ HMAC） |
| T09a | W11 | **最小端到端版本**：`Invoke-ForensiKit` 先只串 Security log 時段匯出＋簡易 manifest |
| T09 | W12 | `Invoke-ForensiKit` 完整主流程 |
| T13 | W13 | 在自己的 VM 跑完整 E2E 並回報 |
| T14 | W13 | 修 QA 回報的、屬於上述模組的 bug |

細節與完成條件見 `docs/TASKS.md`；函式簽章與輸出格式**以 `docs/ARCHITECTURE.md` 為準**。

## 建議順序

1. T01 合併前：先讀契約，在本機用 `wevtutil` 試出正確的 XPath 時段查詢，並確認 vault 檔案的匯出方式（`/lf:true`）。
2. T01 合併後：先做 T04 的 Security log 部分 → **T09a（W11 內合併，讓團隊有可 Demo 的版本）** → T04 其餘 channel 與 vault → T05 → T07 → T08 → T09。
3. 每完成一個函式就開 PR，不要累積到最後一起送。

## 給你的 AI 的提醒

- **PS 5.1 相容**是最常踩的雷，寫完請在 Windows PowerShell 5.1（不是 pwsh 7）實際跑。
- 不要讓單一 artifact 失敗中斷整體；依契約回傳 `Status = 'Failed'` 並寫 action log。
- 時間一律 UTC。wevtutil 的 XPath 需要 `yyyy-MM-ddTHH:mm:ss.fffZ` 格式。
- QA 會依契約寫測試；如果你發現契約不合理，**先開 `[contract]` PR 討論，不要直接改輸出格式**。
- 需要測試時，只在 VM 內執行需要管理員權限的指令。
- 審核人是 OogaryoO；你也需要審核 OogaryoO 的功能 PR（T01、T06、T10）。
