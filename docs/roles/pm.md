# 角色：PM ＋ 開發 — OogaryoO（蔡冠毅）

> 給 OogaryoO 的 AI agent：你的使用者是 PM，同時負責約 30% 的開發。讀完本檔後依 `AGENTS.md` 的規則工作。

## 你負責的開發任務

| 任務 | 週次 | 說明 |
|---|---|---|
| T01 | W10 | repo 骨架、模組載入、`Write-FKAction`、`Get-FKConfig`、`Assert-FKAdmin`、CI。**其他人都依賴它，優先完成。** |
| T06 | W11 | 常駐保全：`Install-/Uninstall-FKPreservation`、`Get-FKPreservationStatus` |
| T10 | W12 | WinForms GUI `Start-ForensiKitGui` |
| T13 | W13 | 在自己的 VM 跑完整 E2E 並回報 |
| T16 | W14 | 操作 SOP、Demo 腳本與備援錄影、`v1.0.0` 發佈 |
| T18 | W11–W12 | 市場規模與商業模式定稿（`docs/MARKET.md`），含與 EDR 的定位差異 |
| T19 | W12–W13 | 把 VM 產生的範例證據包送講師審閱，整理回饋 |

細節與完成條件見 `docs/TASKS.md`。評分項目與證據的對應見 `docs/PROJECT_PLAN.md`「評分項目對應」。

## 你負責的 PM 工作

AI 可以協助起草，但送出前要讓使用者確認：

1. **W10 開工時**：依 `docs/TASKS.md` 為 T01–T19（含 T09a）各開一個 Issue，指派負責人、加里程碑 M0–M4 與 label。
   可請 AI 產生 `gh issue create` 指令清單，但由使用者確認後執行。
2. **每週**：檢查各 Issue 進度與 `blocked` label，更新 `docs/PROJECT_PLAN.md` 的時程（若有變動）。
3. **審 PR**：審 YuChenKUO 的功能 PR，以及所有 `[contract]` PR；確認後合併（Squash and merge）。
4. **守住範圍**：新需求一律先評估是否在 `PROJECT_PLAN.md` 的「做」欄位內；不在就列為延伸。
5. **介面契約的唯一修改者**：`docs/ARCHITECTURE.md` 的變更要確保開發與 QA 都知情。

## 給你的 AI 的提醒

- T01 完成前，YuChenKUO 和 wangLJ1015 只能用契約先行開發，所以 T01 要盡快、保持精簡，先讓 `Import-Module` 能動，再補 CI。
- GUI（T10）可先用假的 `Invoke-ForensiKit`（回傳契約格式的假物件）開發，不必等 T09。
- 審 PR 時檢查：是否符合契約、是否有 action log、是否 PS 5.1 相容、是否有測試。
- 時程衝突時依 `docs/TASKS.md`「評分導向的優先順序」取捨：PoC 佔 12 分，能 Demo 的端到端流程永遠第一。
- W11 結束時確認 T09a（最小端到端）已合併；沒有的話，這是本專案最大風險，優先處理。
