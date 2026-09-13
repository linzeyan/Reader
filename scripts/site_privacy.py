#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["opencc>=1.1"]
# ///
"""Render site/privacy/ from PRIVACY.md.

PRIVACY.md is the policy: it is what App Store Connect links to and what gets
edited. The three site pages are derived from it — zh-Hant and en are its two
halves, zh-Hans is the zh-Hant half through OpenCC's tw2sp, the same tables
behind the app's own 字彙-level conversion — so none of them is a second copy
to keep in step by hand. Run after editing PRIVACY.md:

    uv run scripts/site_privacy.py

Needs pandoc on PATH; uv fetches opencc on the first run.
"""

import calendar
import re
import subprocess
import sys
import textwrap
from datetime import date
from pathlib import Path

import opencc

ROOT = Path(__file__).resolve().parent.parent
ORIGIN = "https://shufang-reader.pages.dev"
LANG_NAMES = {"zh-Hant": "繁體中文", "zh-Hans": "简体中文", "en": "English"}

# The chrome around the policy, which PRIVACY.md does not carry. The zh-Hans
# strings are written rather than converted: the body can say 隐私权政策 and
# still read fine, but a title should say what the platform's own settings
# screen says, 隐私政策.
PAGES = {
    "zh-Hant": {
        "path": "", "og_locale": "zh_TW",
        "title": "書房 隱私權政策", "h1": "書房 隱私權政策", "brand": "書房",
        "description": "書房不收集你的任何資料：沒有帳號、沒有分析追蹤、沒有廣告、沒有第三方 SDK，也沒有伺服器。這一頁說明 App 處理哪些資料、存在哪裡、會連到哪裡，以及你能怎麼清除。",
        "og_description": "書房不收集你的任何資料：沒有帳號、沒有分析追蹤、沒有廣告、沒有第三方 SDK，也沒有伺服器。",
        "nav_label": "語言", "updated": "最後更新：", "date": "{y} 年 {m} 月 {d} 日",
        "product": "書房產品頁", "source": "原始碼與問題回報",
    },
    "zh-Hans": {
        "path": "zh-Hans/", "og_locale": "zh_CN",
        "title": "书房 隐私政策", "h1": "书房 隐私政策", "brand": "书房",
        "description": "书房不收集你的任何数据：没有账号、没有分析追踪、没有广告、没有第三方 SDK，也没有服务器。这一页说明 App 处理哪些数据、存在哪里、会连到哪里，以及你能怎么清除。",
        "og_description": "书房不收集你的任何数据：没有账号、没有分析追踪、没有广告、没有第三方 SDK，也没有服务器。",
        "nav_label": "语言", "updated": "最后更新：", "date": "{y} 年 {m} 月 {d} 日",
        "product": "书房产品页", "source": "源代码与问题反馈",
    },
    "en": {
        "path": "en/", "og_locale": "en_US",
        "title": "書房 Shufang — Privacy Policy", "h1": "Privacy Policy", "brand": "書房",
        "description": "Shufang collects nothing about you: no account, no analytics, no ads, no third-party SDK, no server. What the app handles, where it lives, and how to clear it.",
        "og_description": "Shufang collects nothing about you: no account, no analytics, no ads, no third-party SDK and no server.",
        "nav_label": "Language", "updated": "Last updated: ", "date": "{d} {month} {y}",
        "product": "書房 product page", "source": "Source &amp; issues",
    },
}

TEMPLATE = """<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="canonical" href="{url}">
{alternates}
<meta name="theme-color" content="#6E4C3A">
<link rel="icon" href="/icon.png" type="image/png">
<link rel="apple-touch-icon" href="/icon.png">
<link rel="stylesheet" href="/style.css">
<meta property="og:type" content="article">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{og_description}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{origin}/icon.png">
<meta property="og:locale" content="{og_locale}">
<meta property="article:modified_time" content="{iso}T00:00:00+08:00">
</head>
<body>
<div class="page">
  <header class="top">
    <a class="brand" href="{home}"><img src="/icon.png" alt="" width="44" height="44">{brand}</a>
    <nav class="langs" aria-label="{nav_label}">{nav}</nav>
    <a class="btn btn-sm" href="https://apps.apple.com/app/id6798525550">App Store</a>
  </header>

  <main class="prose">
    <h1>{h1}</h1>
    <p class="updated">{updated}<time datetime="{iso}">{date}</time></p>

{body}
  </main>

  <footer class="foot">
    <span>© {year} Ze-Yan Lin</span>
    <a href="{home}">{product}</a>
    <a href="https://github.com/linzeyan/Reader">{source}</a>
    {footer_langs}
  </footer>
</div>
</body>
</html>
"""


def policy_date(text: str) -> date:
    found = re.search(r"Last updated: (\d{1,2}) ([A-Z][a-z]+) (\d{4})", text)
    if not found:
        sys.exit("PRIVACY.md: no 'Last updated: D Month YYYY' line to date the pages by")
    day, month, year = found.groups()
    return date(int(year), list(calendar.month_name).index(month), int(day))


def halves(text: str) -> tuple[str, str]:
    """The zh-Hant and en bodies: everything under `## 繁體中文` and `## English`."""
    parts = re.split(r"^## (.+)$", text, flags=re.MULTILINE)
    sections = dict(zip(parts[1::2], parts[2::2]))
    try:
        zh, en = sections["繁體中文"], sections["English"]
    except KeyError as missing:
        sys.exit(f"PRIVACY.md: no `## {missing.args[0]}` section")
    # The rule between the halves belongs to the file, not to either policy.
    return re.sub(r"\n---\s*$", "", zh), re.sub(r"\n---\s*$", "", en)


def render(markdown: str) -> str:
    # `east_asian_line_breaks`: the source wraps Chinese paragraphs at 40-odd
    # characters, and a soft break between two Han characters must vanish rather
    # than become a space. `--shift-heading-level-by=-1`: the file's `###` are the
    # page's `<h2>`, because the page has its own `<h1>`.
    out = subprocess.run(
        ["pandoc", "-f", "gfm+east_asian_line_breaks", "-t", "html5",
         "--wrap=none", "--shift-heading-level-by=-1"],
        input=markdown, capture_output=True, text=True, check=True,
    ).stdout
    # The extension keeps a soft break that lands between full-width punctuation
    # and a Latin word, as a space — 「資料）。 App」 — which nothing in the source
    # meant; a space is never wanted right after 。，；：）」.
    out = re.sub(r"(?<=[。，；：！？）」])\s+(?=[A-Za-z0-9])", "", out)
    return textwrap.indent(label_cells(out).rstrip("\n"), "    ")


def label_cells(html: str) -> str:
    """Give every `<td>` its column's heading as `data-l`, which is what the
    stylesheet shows in front of each cell once the table stacks on a phone."""
    def label(table: re.Match) -> str:
        heads = re.findall(r"<th>(.*?)</th>", table[0])
        thead, tbody = table[0].split("</thead>", 1)
        column = 0

        def cell(_: re.Match) -> str:
            nonlocal column
            head = heads[column % len(heads)]
            column += 1
            return f'<td data-l="{head}">'
        return thead + "</thead>" + re.sub(r"<td>", cell, tbody)
    return re.sub(r"<table>.*?</table>", label, html, flags=re.DOTALL)


def link(lang: str, path: str) -> str:
    return f'<a href="/{path}privacy/" lang="{lang}" hreflang="{lang}">{LANG_NAMES[lang]}</a>'


def page(lang: str, body: str, updated: date) -> str:
    spec = PAGES[lang]
    others = [(other, PAGES[other]["path"]) for other in PAGES if other != lang]
    alternates = [f'<link rel="alternate" hreflang="{other}" href="{ORIGIN}/{PAGES[other]["path"]}privacy/">'
                  for other in PAGES]
    alternates.append(f'<link rel="alternate" hreflang="x-default" href="{ORIGIN}/privacy/">')
    return TEMPLATE.format(
        lang=lang, origin=ORIGIN, url=f"{ORIGIN}/{spec['path']}privacy/", home=f"/{spec['path']}",
        alternates="\n".join(alternates),
        nav="".join(link(other, path) for other, path in others),
        footer_langs="\n    ".join(link(other, path) for other, path in others),
        iso=updated.isoformat(), year=updated.year,
        date=spec["date"].format(y=updated.year, m=updated.month, d=updated.day, month=updated.strftime("%B")),
        body=body, **{k: v for k, v in spec.items() if k not in ("path", "date")},
    )


def stamp_sitemap(iso: str) -> None:
    path = ROOT / "site" / "sitemap.xml"
    stamped = 0

    def stamp(entry: re.Match) -> str:
        nonlocal stamped
        stamped += 1
        return re.sub(r"<lastmod>[^<]*</lastmod>", f"<lastmod>{iso}</lastmod>", entry[0])
    xml = re.sub(r"<url>(?:(?!</url>).)*?privacy/</loc>.*?</url>", stamp, path.read_text(), flags=re.DOTALL)
    if stamped != len(PAGES):
        sys.exit(f"sitemap.xml: dated {stamped} privacy entries, expected {len(PAGES)}")
    path.write_text(xml)


def main() -> None:
    text = (ROOT / "PRIVACY.md").read_text()
    updated = policy_date(text)
    zh, en = halves(text)
    bodies = {"zh-Hant": render(zh), "en": render(en)}
    bodies["zh-Hans"] = opencc.OpenCC("tw2sp").convert(bodies["zh-Hant"])
    for lang, body in bodies.items():
        out = ROOT / "site" / PAGES[lang]["path"] / "privacy" / "index.html"
        out.write_text(page(lang, body, updated))
        print(out.relative_to(ROOT))
    stamp_sitemap(updated.isoformat())


if __name__ == "__main__":
    main()
