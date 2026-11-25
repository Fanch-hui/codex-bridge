# dsh-opencode-free

[English](README.md) | **繁體中文**

[![npm](https://img.shields.io/npm/v/dsh-opencode-free)](https://www.npmjs.com/package/dsh-opencode-free)
[![CI](https://github.com/x5427876/dsh-opencode-free/actions/workflows/ci.yml/badge.svg)](https://github.com/x5427876/dsh-opencode-free/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

在 DeepSeek Harness（DSH）中使用 [OpenCode Zen](https://opencode.ai/docs/providers)
免費模型，不必安裝 OpenCode，也不必另外架設伺服器。預設匿名使用，Zen API key 為選用設定。

- **匿名層可用：** Zen 免費層依請求內容判斷（工具宣告、`<env>` 區塊、TLS 密碼套件清單），
  不只看標頭。插件會調整匿名請求以符合這些條件；請見
  [免費層檢查什麼](docs/free-tier-gate.zh-TW.md)，內含標註日期的實測。
- **沒有內建模型清單：** 選單跟隨 Zen 官方模型清單：對話模型且所有已宣告價格皆為零。
  更新採惰性觸發，更新失敗時保留上一份可用清單。可在詳情頁隱藏個別模型。
- **DSH 原生整合：** 模型出現在 **OpenCode Zen Free** 下，支援串流、推理、工具呼叫、
  用量與取消請求。
- **可用性檢查：** 詳情頁提供探測結果與延遲；額度限制與准入拒絕不會移除模型。
- **一個版本對一個 DSH：** 每個插件版本只支援一個 DSH 版本。

> [!WARNING]
> 這是非官方插件，與 OpenCode 或 DeepSeek 官方無關。匿名請求由本插件送出 OpenCode CLI
> 格式的身份欄位，並非由官方 CLI 發出。上游不保證第三方存取，隨時可能因規則變動而失效。同一出口 IP 的呼叫者
> 共用匿名額度。
>
> 插件以 DSH 的權限執行，並針對 Zen inference 端點包裝行程層級的 HTTP 入口。
> 安裝前請閱讀〈[安全與限制](#安全與限制)〉及 DSH 的
> [安全說明](https://github.com/deepseek-ai/deepseek-harness/blob/master/SAFETY.md)。

## 快速開始

### 環境需求

| 項目 | 版本 |
|---|---|
| DeepSeek Harness | `0.2.2-rc.1`（必須完全相同） |
| Node.js | `^22.19.0` 或 `>=24.0.0` |

每個插件版本只支援一個 DSH 版本。四個執行期 peer 依賴都是必要的，請勿忽略
peer dependency 警告。舊版對應的 DSH 請看該版的
[GitHub Release](https://github.com/x5427876/dsh-opencode-free/releases)，或執行
`npm view dsh-opencode-free@<版本> peerDependencies`。

### 安裝

先確認 DSH 版本，再安裝固定版本的套件：

```sh
dsh --version
dsh plugin --profile web add dsh-opencode-free@0.6.0
```

請將 `web` 換成你的目標 profile。若已安裝，請改用下方的更新指令，不要重複新增。

檢查套件與合成後的設定：

```sh
dsh plugin --profile web list dsh-opencode-free --depth 0
dsh --profile web --dump-config
```

套件與 `opencode-free` 插件項目應各出現一次。重啟 DSH（或等待 HMR 重載），
再從 **OpenCode Zen Free** 選擇模型。

### 更新或移除

```sh
dsh plugin --profile web update dsh-opencode-free
dsh plugin --profile web remove dsh-opencode-free
```

## 使用方式

更新間隔、探測結果、快取復原與 key 驗證方式，請見[使用指南](docs/usage.zh-TW.md)。

模型選單顯示當前目錄，不採用固定模型清單。上下文大小、圖片支援與推理等級取自
各模型已發布的資料。更新失敗時保留快取；沒有快取時，退回 pi-ai 內建的模型集。

在插件詳情頁啟用或隱藏模型，並按「立即探測」檢查可用性。讀取模型清單時，
每天也會自動觸發一輪檢查。**檢查會送出真實推理請求並消耗額度**，逐一詢問已啟用
的模型。結果會保留至重啟之後。

只有目錄下架或上游明確表示模型不可用時，才會移除模型；准入拒絕、額度用完、key
無效與網路失敗都屬於無法判定。更新、移除與快取行為詳見
[模型目錄判定規則](docs/adr/0002-catalogue-source-of-truth.md)。

## 選用 API key

優先順序：插件 `config.apiKey` → 環境變數 `OPENCODE_API_KEY` → 匿名 `public`。
沒有登入流程，插件也不會自動切換付費模型。key 改變驗證身份與額度，不改變模型清單，
也不保證能存取已不可用的模型。

Desktop 請在目標 profile 的 `cordis.patch.yml` 設定 key，不要依賴 shell 環境：

```yaml
- id: opencode-free
  name: dsh-opencode-free
  config:
    apiKey: <your Zen key>
```

修改設定後請重載 DSH。妥善保管 key 與設定檔，不要附在問題回報中。

## 運作原理

實作依據來自維護者分析 OpenCode CLI 原始碼與驗證請求的結果。插件透過 DSH 的
`PiAiAdapter` 註冊 `opencode-zen-free` provider，再以 pi-ai 傳輸層直接呼叫
`https://opencode.ai/inference/v1`。工具仍由 DSH 執行。

匿名請求帶有 OpenCode CLI 身份標頭、時間編碼的 session ID、串流設定，以及具有
實質內容的 `read` 與 `bash` 工具宣告。上游最小准入規則尚未完整驗證，也可能改變。
來源與證據界限詳見[協定分析紀錄](docs/protocol-notes.md)。

### 模型請求有哪些改動

以下調整僅適用於匿名請求；帶 key 的請求保留原本的工具與提示。

| 調整 | 模型看到的差異 |
|---|---|
| Windows shell | DSH 的 `pwsh` 以 `bash` 呈現，回傳呼叫再還原為 `pwsh`。讀檔與 shell 參數名稱會轉換，但保留宿主限制。 |
| 缺少工具 | 缺少 `read`／`bash` 時，補上僅供准入的宣告，不增加執行能力；不存在的工具呼叫會在交給宿主前拒絕。保留呼叫端明確指定的工具選擇。 |
| 上下文壓縮 | 符合條件的無工具摘要請求改用 OpenCode 風格的摘要系統提示，承載對話的使用者訊息不變。 |

工具說明與准入宣告會增加 token；上下文壓縮則取代系統提示的 token。相同工具組合的
工具與歷史改寫維持穩定前綴，但切換匿名與帶 key 存取會改變前綴。上下文壓縮是獨立請求。

## 安全與限制

- **行程層級攔截：** 包裝 `globalThis.fetch` 與 `node:http(s)` 的 `request`／`get`，
  僅限 Zen inference 的 HTTPS origin 及 `/inference/v1` 路徑與子路徑。同一行程內
  其他插件呼叫該端點時，也會套用身份標頭。
- **Profile 依賴：** 詳情頁路由需要 `webServer` 服務，內建的 `headless` profile
  不提供這項服務。
- **除錯隱私：** `DSH_OPENCODE_FREE_DEBUG=1` 可啟用診斷。記錄只標示憑證種類
  （`anonymous` 或 `key`），不含任何片段；上游拒絕只記錄狀態、閘門標記與錯誤代碼，
  不記錄其文字。請求與 session 識別碼仍會出現，請不要公開原始記錄。
- **驗證範圍：** 相容性驗證結果不存放在儲存庫：結果取決於環境、版本、時間與共用的
  匿名額度。需要目前的證據時，請依[相容性驗證指南](docs/compat-run.md)自行執行。
  headless 驗證不涵蓋 Web、Desktop 與上下文壓縮。

## 疑難排解

| 狀況 | 建議處理方式 |
|---|---|
| 插件未載入 | 確認 DSH 精確版本、必要 peer 依賴、目標 profile 與 `webServer` 服務。 |
| `403 FreeTierError … only be used from within OpenCode` | 上游拒絕准入，單憑此訊息無法判定是 IP 限制、key 無效或模型下架。重裝不能修復准入規則。 |
| 灰色「未測到」 | 本輪無法判定，不代表模型已下架。先閱讀橫幅原因，再決定是否重試探測。 |
| HTTP `200` 但沒有回覆 | HTTP 成功不等於回覆完成。請嘗試其他模型，並保留模型 ID 與已去敏的錯誤供診斷。 |

請透過 [GitHub Issues](https://github.com/x5427876/dsh-opencode-free/issues)
回報問題，附上插件與 DSH 版本、作業系統、profile 及去敏後的錯誤。
不要張貼 key、原始記錄或對話內容。

## 開發

依任務尋找指南，請見[文件索引](docs/README.zh-TW.md)。
貢獻前請閱讀[工程標準](docs/standards.md)與[已知差距](docs/standards-gap.md)。
請修改 `src/`；`lib/` 是產生的檔案。

```sh
pnpm install
pnpm run check  # 本地連結、型別檢查、建置、離線測試與打包
```

預設測試使用 fixture 與暫存的 `DSH_HOME`，不連網，也不消耗推理額度。
實際連線檢查獨立執行，必須取得明確授權：

- `scripts/reverify.sh` 是請求假設已過時的歷史診斷工具，不能用來驗證目前准入或 key。
  它仍會送出真實請求，僅能從 clone 取得。詳見[使用指南](docs/usage.zh-TW.md#驗證設定的路徑)。
- 真實宿主驗證與退出碼定義，請見[相容性驗證指南](docs/compat-run.md)。
- 版本歷史與 Agent 安裝流程，請見 [GitHub Releases](https://github.com/x5427876/dsh-opencode-free/releases) 與 [AGENTS.md](AGENTS.md)。

## 授權

[MIT](LICENSE)。
