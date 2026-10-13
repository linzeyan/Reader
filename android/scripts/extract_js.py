#!/usr/bin/env python3
"""Generates the Android extractor scripts from the iOS source, which stays their only copy.

Every multi-line string literal in the Swift files below becomes
app/src/main/resources/extractor/<name>.js, named after the `static func` / `static let`
it belongs to. Swift escapes are undone, and each interpolation `\\(name)` becomes the
placeholder `__NAME__` that ExtractorScript.kt fills in (`\\(Type.name)` too: the type is
only where Swift finds it).

    python3 scripts/extract_js.py           # write the files
    python3 scripts/extract_js.py --check   # exit 1 if they are out of date
"""
import pathlib
import re
import sys

ANDROID = pathlib.Path(__file__).resolve().parent.parent
SOURCES = [
    ANDROID.parent / "NovelReader/SiteRules/ExtractorScript.swift",
    ANDROID.parent / "NovelReader/Services/RuleDeriver.swift",
    ANDROID.parent / "NovelReader/Services/SearchDeriver.swift",
]
OUT = ANDROID / "app/src/main/resources/extractor"


def unescape(body: str) -> str:
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        n = body[i + 1]
        if n == "(":
            end = body.index(")", i)
            out.append("__" + body[i + 2 : end].split(".")[-1].upper() + "__")
            i = end + 1
        elif n == "u":  # \u{XXXX}
            end = body.index("}", i)
            out.append(chr(int(body[i + 3 : end], 16)))
            i = end + 1
        elif n == "\n":  # line continuation
            i += 2
        else:
            out.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(n, n))
            i += 2
    return "".join(out)


def literals(swift: str, found: dict) -> dict:
    for m in re.finditer(r'"""\n(.*?)\n([ \t]*)"""', swift, re.S):
        indent = m.group(2)
        lines = [l[len(indent) :] if l.startswith(indent) else l for l in m.group(1).split("\n")]
        owner = re.findall(r"static (?:func|let) (\w+)", swift[: m.start()])[-1]
        if owner in found:
            sys.exit(f"two literals belong to {owner}; name them apart before generating")
        found[owner] = unescape("\n".join(lines)) + "\n"
    return found


def main() -> int:
    scripts = {}
    for source in SOURCES:
        literals(source.read_text(encoding="utf-8"), scripts)
    if "--check" in sys.argv:
        stale = [n for n, js in scripts.items() if not (OUT / f"{n}.js").is_file()
                 or (OUT / f"{n}.js").read_text(encoding="utf-8") != js]
        extra = [p.stem for p in OUT.glob("*.js") if p.stem not in scripts]
        if stale or extra:
            print(f"extractor scripts out of date: stale={stale} extra={extra}; run scripts/extract_js.py")
            return 1
        print(f"extractor scripts match {', '.join(s.name for s in SOURCES)} ({len(scripts)} scripts)")
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for p in OUT.glob("*.js"):
        p.unlink()
    for name, js in scripts.items():
        (OUT / f"{name}.js").write_text(js, encoding="utf-8")
    print(f"wrote {len(scripts)} scripts to {OUT.relative_to(ANDROID)}: {sorted(scripts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
