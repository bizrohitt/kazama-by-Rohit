#!/usr/bin/env python3
"""Structural sanity check for the Dart tree — no Flutter/Dart SDK needed.

Why this exists: this repo is written in a sandbox with no `dart` binary, so
"does it at least parse structurally" cannot be answered by the compiler. A naive
`count('{') - count('}')` check LIES (it counts braces inside comments, string
literals, and `${interpolation}`), which is worse than no check at all — it once
flagged 16 healthy files. This scanner skips comments and strings properly.

What it does NOT do: it proves balanced delimiters and nothing else. Types,
names, nullability and drift codegen still need `dart analyze` / `flutter test`.
Run it as a pre-flight, never as a pass/fail gate for a task.

Usage:  python3 tools/dart_balance.py [dir ...]     (default: lib test tools)
"""
import sys
from pathlib import Path


def scan(src: str):
    i, n, depth, unclosed = 0, len(src), 0, []
    while i < n:
        c = src[i]
        if src[i : i + 2] == "//":
            j = src.find("\n", i)
            i = n if j == -1 else j
            continue
        if src[i : i + 2] == "/*":
            j = src.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        # raw strings first: r'...' / r"..."  (no interpolation inside)
        if c == "r" and i + 1 < n and src[i + 1] in "'\"":
            i += 1
            c = src[i]
        if c in "'\"":
            q = c
            triple = src[i : i + 3] == q * 3
            delim = q * 3 if triple else q
            raw = i > 0 and src[i - 1] == "r"
            i += len(delim)
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i : i + len(delim)] == delim:
                    i += len(delim)
                    break
                if not raw and not triple and src[i] == "$" and src[i + 1 : i + 2] == "{":
                    # interpolated expression: skip its braces, they are balanced
                    j, b = i + 2, 1
                    while j < n and b:
                        if src[j] == "{":
                            b += 1
                        elif src[j] == "}":
                            b -= 1
                        j += 1
                    i = j
                    continue
                i += 1
            continue
        if c == "{":
            depth += 1
            unclosed.append(i)
        elif c == "}":
            if depth == 0:
                print(f"  extra '}}' at line {src[:i].count(chr(10)) + 1}")
            else:
                depth -= 1
                if unclosed:
                    unclosed.pop()
        i += 1
    for off in unclosed:
        print(f"  unclosed '{{' at line {src[:off].count(chr(10)) + 1}")
    return depth


def eq_chain_problems(src: str) -> list[str]:
    """Flag a broken `operator ==` chain — the defect this repo actually shipped.

    Every model file compares with a chain whose links are joined by `&&`. A
    formatter once dropped those operators and left `a == b c == d`, which is not
    invalid-looking to a brace counter but is a hard parse error. The rule below
    is the shape the codebase converged on, so it is checkable by eye:

      bool operator ==(Object other) =>
          link &&
          link &&
          last_link;

    Any link line that ends with neither `&&` nor `;` is a defect. Doc comments
    are skipped because the T2 gate note quotes `m.toJson() == m` in prose.
    """
    out = []
    lines = src.split("\n")
    for i, raw in enumerate(lines):
        if raw.strip() != "bool operator ==(Object other) =>":
            continue
        k = i + 1
        while k < len(lines):
            t = lines[k].strip()
            if t.startswith("///") or not t:
                k += 1
                continue
            if t.endswith("&&"):
                k += 1
                continue
            if t.endswith(";"):
                break
            out.append(f"line {k + 1}: chain link not terminated: {t[:64]}")
            break
        else:
            out.append(f"line {i + 1}: unterminated == chain")
    return out


def main() -> int:
    roots = [Path(a) for a in (sys.argv[1:] or ["lib", "test", "tools"])]
    files = sorted(
        f for r in roots if r.exists() for f in r.rglob("*.dart") if not f.name.endswith(".g.dart")
    )
    bad = 0
    for f in files:
        src = f.read_text()
        over = len(src.splitlines()) > 600
        import io as _io, contextlib as _cl
        _msg = _io.StringIO()
        with _cl.redirect_stdout(_msg):
            depth = scan(src)
        stray = _msg.getvalue().strip()
        if stray:
            print(f"{f}:\n  " + stray.replace("\n", "\n  "))
        chains = eq_chain_problems(src)
        if depth or over or chains:
            bad += 1
            note = "  OVER-600-LINES" if over else ""
            note += "".join(f"\n  {f}: {c}" for c in chains)
            print(f"{f}: depth={depth}{note}")
        if stray:
            bad += 1
    lines = sum(len(f.read_text().splitlines()) for f in files)
    biggest = max(((len(f.read_text().splitlines()), f) for f in files), default=(0, None))
    print(
        f"{len(files)} files, {lines} Dart lines, largest {biggest[0]} ({biggest[1]}) "
        f"— limit 600: {'OK' if biggest[0] <= 600 else 'VIOLATED'}"
    )
    print("BALANCED: all files" if bad == 0 else f"{bad} FILE(S) NEED ATTENTION")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
