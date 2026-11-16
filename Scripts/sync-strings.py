#!/usr/bin/env python3
"""Gleicht Localizable.xcstrings mit den vom Compiler extrahierten Texten ab.

xcodebuild schreibt neue UI-Texte nicht in den Katalog (das tut nur Xcode
bzw. -exportLocalizations, das hier an der Entwicklungsregion scheitert).
Dieses Skript liest die .stringsdata-Dateien des letzten macOS-Debug-Builds,
legt fehlende Schlüssel an (Deutsch = Schlüssel) und übernimmt englische
Übersetzungen aus einer optionalen JSON-Datei {"Schlüssel": "English"}.

Aufruf:  Scripts/sync-strings.py [--translations en.json] [--check]
--check: nichts schreiben, nur melden; Exit 1, wenn Texte fehlen oder ohne
Englisch sind (für release.sh).
"""
import argparse, glob, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "FinanceTracker/Resources/Localizable.xcstrings")


def build_dir():
    out = subprocess.run(
        ["xcodebuild", "-project", os.path.join(ROOT, "FinanceTracker.xcodeproj"), "-scheme", "FinanceTracker",
         "-destination", "platform=macOS", "-showBuildSettings"],
        capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.strip().startswith("OBJROOT ="):
            return line.split("=", 1)[1].strip()
    sys.exit("OBJROOT nicht gefunden")


def extracted_keys():
    pattern = os.path.join(build_dir(), "FinanceTracker.build/Debug/FinanceTracker_macOS.build/Objects-normal/*/*.stringsdata")
    keys = set()
    for path in glob.glob(pattern):
        data = json.load(open(path))
        if not os.path.exists(data.get("source", "")):
            continue
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    return keys


def sort_rec(value):
    if isinstance(value, dict):
        return {k: sort_rec(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return [sort_rec(v) for v in value]
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--translations")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    translations = json.load(open(args.translations)) if args.translations else {}

    catalog = json.load(open(CATALOG))
    strings = catalog["strings"]
    added = [k for k in sorted(extracted_keys()) if k and k not in strings]
    for key in added:
        strings[key] = {"localizations": {}}
    for key, value in translations.items():
        if key in strings:
            strings[key].setdefault("localizations", {})["en"] = {"stringUnit": {"state": "translated", "value": value}}
    without_en = [k for k, v in strings.items()
                  if k and v.get("shouldTranslate", True) and v.get("extractionState") != "stale"
                  and "en" not in v.get("localizations", {})]

    if args.check:
        for key in added:
            print("fehlt im Katalog:", key)
        for key in without_en:
            print("ohne Englisch:", key)
        sys.exit(1 if added or without_en else 0)

    text = json.dumps(sort_rec(catalog), ensure_ascii=False, indent=2, separators=(",", " : "))
    open(CATALOG, "w").write(text.replace('"" : {\n\n    }', '"" : {}') + "\n")
    print(f"{len(added)} Schlüssel ergänzt, {len(without_en)} noch ohne Englisch")
    for key in without_en:
        print("ohne Englisch:", key)


if __name__ == "__main__":
    main()
