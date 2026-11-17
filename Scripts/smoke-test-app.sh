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
#         Scripts/smoke-test-app.sh --check-access [Bundle-ID]
#
# Zugriff auf den Container: macOS schützt die Container anderer Apps
# („Daten anderer Apps"). Das Terminal, aus dem dieses Skript läuft, braucht
# diese Erlaubnis, sonst kann es weder einen Fixture-Store ablegen noch das
# Ergebnis lesen. Der erste Zugriff löst die Abfrage des Systems aus und
# wird bis zur Antwort abgelehnt. `--check-access` prüft das vorab und
# wartet auf die Antwort; release.sh ruft es in der Vorprüfung auf, damit
# ein fehlender Zugriff nicht erst nach Build und Notarisierung auffällt.
# Jede Ergebniszeile enthält die Ladezeiten der Übersicht (overview*Ms,
# warm*Ms) und den höchsten Speicherbedarf (peakMemoryMB).
# Ohne Pfad: der zuletzt gebaute Release-Build unter build/release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="${FT_SMOKE_TIMEOUT:-90}"
ACCESS_TIMEOUT="${FT_SMOKE_ACCESS_TIMEOUT:-60}"

# Prüft, ob dieses Terminal im Ordner anlegen, lesen und löschen darf.
# Wartet bis ACCESS_TIMEOUT Sekunden, damit die Abfrage des Systems
# beantwortet werden kann. Ein noch fehlender Ordner (Container entsteht
# beim ersten Start der App) gilt als in Ordnung.
check_container_access() {
    local base="$1"
    [ -d "$base" ] || return 0
    local probe="$base/.ft-smoke-access-$$"
    local waited=0 hinted=0
    while :; do
        if ( : > "$probe" ) 2>/dev/null && cat "$probe" >/dev/null 2>&1 && rm -f "$probe" 2>/dev/null; then
            return 0
        fi
        if [ "$hinted" = 0 ]; then
            echo "Warte auf Zugriff auf den Container der App ($base)." >&2
            echo "Falls macOS fragt, ob dieses Programm auf Daten anderer Apps zugreifen darf: erlauben." >&2
            hinted=1
        fi
        [ "$waited" -ge "$ACCESS_TIMEOUT" ] && break
        sleep 2
        waited=$((waited + 2))
    done
    rm -f "$probe" 2>/dev/null || true
    echo "Kein Zugriff auf den Container der App: $base" >&2
    echo "macOS schützt die Daten anderer Apps. Die Abfrage erlauben oder dem Programm, in dem dieses" >&2
    echo "Terminal läuft, in den Systemeinstellungen unter Datenschutz & Sicherheit Festplattenvollzugriff geben." >&2
    return 1
}

if [ "${1:-}" = "--check-access" ]; then
    CHECK_BUNDLE_ID="${2:-de.klabautter.FinanceTracker}"
    check_container_access "${FT_SMOKE_TMP_BASE:-$HOME/Library/Containers/$CHECK_BUNDLE_ID/Data/tmp}"
    exit $?
fi

APP="${1:-$ROOT/build/release/Build/Products/Release/FinanceTracker.app}"

[ -d "$APP" ] || { echo "App nicht gefunden: $APP" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# Temporärer Ordner, den die App als NSTemporaryDirectory sieht.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    # Den Container legt das System beim ersten Start an; der Fall „leer“
    # läuft zuerst und braucht keinen vorbereiteten Ordner.
    TMP_BASE="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp"
    SANDBOXED=1
else
    TMP_BASE="$(getconf DARWIN_USER_TEMP_DIR)"
    SANDBOXED=0
fi
SMOKE_BASE="${TMP_BASE%/}/FinanceTrackerSmoke"

if [ "$SANDBOXED" = 1 ]; then
    check_container_access "$TMP_BASE" || exit 1
fi

FAILED=0

run_case() {
    local name="$1" fixture="$2" expect_data="$3"
    local dir="$SMOKE_BASE/$name"
    if ! rm -rf "$dir" 2>/dev/null; then
        echo "  ✗ $name: der Testordner eines früheren Laufs lässt sich nicht entfernen ($dir)" >&2
        FAILED=1
        return
    fi
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
    if [ -e "$dir/smoke-result.txt" ]; then
        # Die Datei sehen, aber nicht lesen dürfen, ist ein Rechteproblem
        # dieses Terminals und kein Fehler der App.
        result="$(cat "$dir/smoke-result.txt" 2>/dev/null)" \
            || result="Ergebnis liegt vor, ist aber nicht lesbar (kein Zugriff auf den Container der App)"
    else
        result="kein Ergebnis nach ${TIMEOUT}s"
    fi
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
    # Aufräumen darf das Ergebnis nicht kippen.
    rm -rf "$dir" 2>/dev/null || echo "  Hinweis: $dir konnte nicht entfernt werden." >&2
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
