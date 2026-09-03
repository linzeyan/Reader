# 書房 隱私權政策 / Shufang Privacy Policy

最後更新：2026 年 9 月 4 日　|　Last updated: 4 September 2026

---

## 繁體中文

### 簡短版

書房不收集你的任何資料。沒有帳號、沒有註冊、沒有分析追蹤、沒有廣告、沒有第三方
SDK。開發者看不到你讀什麼、讀到哪裡，也沒有任何伺服器可以看。

### App 會處理哪些資料，存在哪裡

| 資料                          | 存在哪裡                                                         | 誰看得到                       |
| ----------------------------- | ---------------------------------------------------------------- | ------------------------------ |
| 書籤、自訂書名、閱讀進度      | 裝置本機資料庫；若你開啟 iCloud 同步，另存於你自己的 iCloud 帳號 | 只有你                         |
| 已下載的章節內文              | 裝置本機檔案                                                     | 只有你。**不會**上傳 iCloud    |
| 你的訂閱清單與已抓下的文章    | 裝置本機資料庫與檔案                                             | 只有你。**不會**上傳 iCloud    |
| 你新增的來源設定（規則 JSON） | 裝置本機檔案                                                     | 只有你，除非你自己選擇分享出去 |
| 網站 Cookie 與快取            | 系統的 WebKit 資料區，與 App 一同刪除                            | 只有你                         |
| 閱讀偏好（字級、主題等）      | 裝置本機                                                         | 只有你                         |

以上所有資料都**不會**傳送給開發者。書房沒有後端伺服器。

### App 會連到哪裡

書房只會連向兩種地方：

1. **你自己輸入的網址。** 你貼上哪個網站的連結、訂閱哪個網址，App 就去讀那個
   位址——小說與漫畫頁面用內建的網頁引擎（WKWebView），行為與你用 Safari 打開它
   相同；訂閱源文件、封面圖與來源規則則是一般的網路請求。兩者該網站都會看到一般
   瀏覽器會送出的資訊（IP 位址、User-Agent、Cookie 等）。訂閱會在你每次開啟 App
   時各送出一次檢查更新的請求，沒有背景排程。這些網站有各自的隱私權政策，不在本
   政策涵蓋範圍內。
2. **Apple 的 iCloud**（僅在你開啟同步時）。同步經由 Apple 的
   `NSUbiquitousKeyValueStore`，資料存在你自己的 iCloud 帳號中，開發者無法存取。
   同步內容僅限書籤、自訂書名與閱讀進度；章節內文與下載清單不同步。

書房**不會**連向開發者的伺服器，因為並不存在這樣的伺服器。

### 兒童

書房不針對 13 歲以下兒童設計，也不會刻意收集兒童資料（事實上不收集任何人的資料）。
App 可以載入使用者自行輸入的任意網址，因此年齡分級問卷中已誠實聲明「不受限制的
網頁存取」。

### 你的控制權

- 刪除已下載內容：App 內提供四個層級——單章、單本、單一來源、全部。
- 移除來源：在「設定 → 來源」中刪除。
- 停止同步：在系統設定中關閉本 App 的 iCloud。
- 全部清除：刪除 App。所有本機資料、Cookie 與快取會一併移除。

### 政策變更

本政策若有變更，會更新頁首日期並隨新版本發布。

### 聯絡

zeyanlin@outlook.com

---

## English

### Short version

Shufang collects nothing about you. There is no account, no sign-up, no analytics,
no advertising and no third-party SDK. The developer cannot see what you read or
where you stopped, and has no server that could.

### What the app handles, and where it lives

| Data                                       | Where it lives                                                  | Who can see it                           |
| ------------------------------------------ | --------------------------------------------------------------- | ---------------------------------------- |
| Bookmarks, custom titles, reading progress | Local database; also your own iCloud account if you enable sync | You only                                 |
| Downloaded chapter text                    | Local files                                                     | You only. **Never** uploaded to iCloud   |
| Your subscriptions and the articles fetched | Local database and files                                       | You only. **Never** uploaded to iCloud   |
| Sources you add (rule JSON)                | Local files                                                     | You only, unless you choose to share one |
| Site cookies and cache                     | The system WebKit data store, removed with the app              | You only                                 |
| Reading preferences (text size, theme, …)  | On device                                                       | You only                                 |

None of it is ever sent to the developer. Shufang has no backend.

### What the app connects to

Only two kinds of destination:

1. **URLs you enter yourself** — a site you paste, or a feed you subscribe to.
   Novel and comic pages are loaded with the system web engine (WKWebView),
   exactly as Safari would; feed documents, cover images and source rules are
   ordinary network requests. Either way the host sees what any browser sends —
   IP address, user agent, cookies. Subscriptions are checked once each when you
   open the app, and on no background schedule. Those sites have their own privacy
   policies, which this policy does not cover.
2. **Apple's iCloud**, and only if you turn sync on. Sync uses Apple's
   `NSUbiquitousKeyValueStore`; the data sits in your own iCloud account and the
   developer cannot reach it. Only bookmarks, custom titles and reading progress
   are synced — never chapter text, never the list of downloads.

Shufang does not connect to any developer-operated server, because none exists.

### Children

Shufang is not directed at children under 13 and does not knowingly collect data
from children — it collects data from no one. Because users can enter arbitrary
URLs, "unrestricted web access" is declared truthfully in the age-rating
questionnaire.

### Your controls

- Delete downloads at four levels: one chapter, one book, one source, everything.
- Remove a source under Settings → Sources.
- Stop syncing by turning off iCloud for the app in system settings.
- Delete everything by deleting the app — local data, cookies and cache go with it.

### Changes

If this policy changes, the date at the top is updated and the new version ships
with a release.

### Contact

zeyanlin@outlook.com
