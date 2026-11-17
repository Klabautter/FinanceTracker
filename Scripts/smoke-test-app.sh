#!/bin/bash
# Rauchtest der fertigen App (Roadmap 4.5).
#
# Startet die übergebene FinanceTracker.app (z. B. die notarisierte aus
# Scripts/release.sh) einmal mit leerem Store und einmal mit dem
# Fixture-Store jeder ausgelieferten Schema-Version
# (Tests/Fixtures/stores/FinanceTracker-vN.store). Die App öffnet den Store
# im Modus `-smoke-test <name>` in einem isolierten temporären Ordner
# (bei der gesandboxten App im Container), führt Migration und
# Start-Aufgaben aus, liest Konten/Buchungen/Kategorien, schreibt
# `smoke-result.txt` und beendet sich. Der echte Store wird nicht berührt,
# es gibt keinen Bankabruf.
#
# Aufruf: Scripts/smoke-test-app.sh [Pfad/zur/FinanceTracker.app]
# Jede Ergebniszeile enthält die Ladezeiten der Übersicht (overview*Ms,
# warm*Ms) und den höchsten Speicherbedarf (peakMemoryMB).
# Ohne Pfad: der zuletzt gebaute Release-Build unter build/release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/release/Build/Products/Release/FinanceTracker.app}"
TIMEOUT="${FT_SMOKE_TIMEOUT:-90}"

[ -d "$APP" ] || { echo "App nicht gefunden: $APP" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# Temporärer Ordner, den die App als NSTemporaryDirectory sieht.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    # Den Container legt das System beim ersten Start an; der Fall „leer“
    # läuft zuerst und braucht keinen vorbereiteten Ordner.
    TMP_BASE="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp"
else
    TMP_BASE="$(getconf DARWIN_USER_TEMP_DIR)"
fi
SMOKE_BASE="${TMP_BASE%/}/FinanceTrackerSmoke"

FAILED=0

run_case() {
    local name="$1" fixture="$2" expect_data="$3"
    local dir="$SMOKE_BASE/$name"
    rm -rf "$dir"
    if [ -n "$fixture" ]; then
        [ -d "$TMP_BASE" ] || { echo "  ✗ $name: Container fehlt ($TMP_BASE)" >&2; FAILED=1; return; }
        mkdir -p "$dir"
        cp "$fixture" "$dir/FinanceTracker.store"
        for suffix in -wal -shm; do
            [ -f "$fixture$suffix" ] && cp "$fixture$suffix" "$dir/FinanceTracker.store$suffix"
        done
    fi

    # Über LaunchServices starten: gesandboxte Apps zeigen bei direktem
    # Binary-Start auf macOS 26 kein Fenster (siehe AGENTS.md).
    open -n -W -a "$APP" --args -smoke-test "$name" &
    local opener=$!
    local waited=0
    while [ ! -f "$dir/smoke-result.txt" ] && [ "$waited" -lt "$TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    # Etwas Zeit zum Beenden lassen, danach hart beenden.
    for _ in 1 2 3 4 5; do kill -0 "$opener" 2>/dev/null || break; sleep 1; done
    if kill -0 "$opener" 2>/dev/null; then
        pkill -f "FinanceTracker.app/Contents/MacOS/FinanceTracker -smoke-test $name" 2>/dev/null || true
        kill "$opener" 2>/dev/null || true
    fi
    wait "$opener" 2>/dev/null || true

    local result
    result="$(cat "$dir/smoke-result.txt" 2>/dev/null || echo "kein Ergebnis nach ${TIMEOUT}s")"
    local ok=1
    case "$result" in
        ok*) ;;
        *) ok=0 ;;
    esac
    if [ "$ok" = 1 ] && [ "$expect_data" = 1 ] && echo "$result" | grep -q "transactions=0"; then
        result="$result (Fixture-Buchungen fehlen nach der Migration)"
        ok=0
    fi
    if [ "$ok" = 1 ]; then
        echo "  ✓ $name: $result"
    else
        echo "  ✗ $name: $result" >&2
        FAILED=1
    fi
    rm -rf "$dir"
}

echo "Rauchtest: $APP"
run_case "empty" "" 0
for fixture in "$ROOT"/Tests/Fixtures/stores/FinanceTracker-v*.store; do
    [ -f "$fixture" ] || continue
    version="$(basename "$fixture" .store)"
    version="${version#FinanceTracker-}"
    run_case "fixture-$version" "$fixture" 1
done
# Optional ein großer Store (z. B. 100.000 Buchungen aus PerformanceBudgetTests
# mit PERF_EXPORT_STORE), um die Ladezeit der Übersicht im fertigen Build zu
# sehen: FT_SMOKE_EXTRA_STORE=/pfad/budget.store
if [ -n "${FT_SMOKE_EXTRA_STORE:-}" ]; then
    run_case "extra" "$FT_SMOKE_EXTRA_STORE" 1
fi
rmdir "$SMOKE_BASE" 2>/dev/null || true

if [ "$FAILED" = 1 ]; then
    echo "Rauchtest fehlgeschlagen." >&2
    exit 1
fi
echo "Rauchtest bestanden."
