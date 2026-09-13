# 書房 — 小說、漫畫、RSS 離線閱讀器（iPhone／iPad）

[![在 App Store 下載](site/img/badge-zh-Hant.svg)](https://apps.apple.com/app/id6798525550)

免費，沒有廣告，沒有帳號。iOS 17 以上。產品頁：[shufang-reader.pages.dev](https://shufang-reader.pages.dev/)

書房是一個「來源由你決定」的閱讀器。它不內建、不推薦、也不連向任何內容網站——第一次打開時書櫃是空的。你貼上一本書的網址，它會自己看懂那個網站的結構，把書變成書櫃裡的一本；整本下載之後，離線也能讀。

## 功能

- **貼一個網址，自動建立來源**：從書籍頁網址推導出書籍頁／目錄／章節頁的規則，先把書名、章數與第一章抓給你確認，確認過才存檔。也可以匯入別人分享的規則檔（JSON）。
- **整本下載，離線讀**：整本或只挑幾十章；漫畫連圖片整話存在裝置上。刪除分四層：單章、單本、單一來源、全部。
- **為長時間閱讀調整過**：捲動或分頁，兩種模式都能劃線。裝置上任何中文字體、字級／行距／段距各自可調、背景可用自己的照片。簡繁整本互轉。進度記到段落。
- **漫畫**：同一套來源流程，直向連續捲動；ZIP 匯入與匯出。
- **訂閱**：RSS、Atom、JSON Feed；OPML 整批匯入。
- **你自己的檔案**：TXT（自動判斷 UTF-8／Big5／GB18030 編碼並分章）與 EPUB 匯入，可匯出成 TXT 或 EPUB。
- **不收集資料**：沒有帳號、分析追蹤、廣告或第三方 SDK。書籤與進度經你自己的 iCloud 同步；開發者沒有伺服器。詳見 [PRIVACY.md](PRIVACY.md)。

書房不提供、不代管、不索引任何內容。所有內容都來自你自己輸入的網址，就像瀏覽器一樣。請自行確認你所瀏覽的網站符合當地法規與該網站的使用條款。

## 問題回報

請開 [Issue](https://github.com/linzeyan/Reader/issues)。回報網站無法解析時，附上書籍頁網址與「自動建立來源」畫面顯示的結果。

## 開發

需要 Xcode 與 [xcodegen](https://github.com/yonaskolb/XcodeGen)。`project.yml` 是唯一的專案來源，`.xcodeproj` 不進版控。

```sh
make setup        # 安裝 xcodegen（若需要）並產生 Xcode 專案
make build        # 編譯到模擬器
make test         # 單元測試
make screenshots  # 產生三語 × 四尺寸的 App Store 截圖
make help         # 全部目標
```

`site/` 是產品頁；`scripts/site_images.sh` 從截圖重產頁面用的圖片；`scripts/site_privacy.py` 從 PRIVACY.md 重產 `site/privacy/`。

---

## English

**書房 (Shufang)** is an iPhone/iPad reader where you decide the sources: web novels, comics and feeds on one shelf, downloaded for offline reading. The app ships with no sites built in — paste the URL of a book page and it works out the site's structure itself. TXT (UTF-8/Big5/GB18030, auto-chaptered) and EPUB import and export; comics as ZIP; RSS, Atom and JSON Feed with OPML import. No account, no ads, no analytics, no server: bookmarks and progress sync through your own iCloud. See [PRIVACY.md](PRIVACY.md).

[![Download on the App Store](site/img/badge-en.svg)](https://apps.apple.com/app/id6798525550)

iOS 17 or later · free · [shufang-reader.pages.dev/en](https://shufang-reader.pages.dev/en/)
