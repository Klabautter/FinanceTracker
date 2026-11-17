#!/bin/bash
# Rauchtest der fertigen App (Roadmap 4.5).
#
# Startet die übergebene FinanceTracker.app (z. B. die notarisierte aus
# Scripts/release.sh) einmal mit leerem Store und einmal mit dem
# Fixture-Store jeder ausgelieferten Schema-Version
# (Tests/Fixtures/stores/FinanceTracker-vN.store). Die App öffnet den Store
# im Modus `-smoke-test <name>` in einem isolierten temporären Ordner
# (bei der gesandboxten App im Container), führt Migration und
# Start-Aufgaben aus, liest Konten/Buchungen/Kategorien, gibt das Ergebnis
# aus und beendet sich. Der echte Store wird nicht berührt, es gibt keinen
# Bankabruf.
#
# Dieses Skript fasst den Container der App nicht an: macOS schützt die
# Daten anderer Apps, und je nach Programm, in dem das Terminal läuft, gibt
# es dafür weder Zugriff noch eine Abfrage. Der Fixture-Store geht deshalb
# über die Standardeingabe in die App (`open --stdin`,
# `-smoke-fixture-stdin`), das Ergebnis kommt über ihre Standardausgabe
# zurück (`open --stdout`, Zeile „smoke-result: …").
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
# `open -a` braucht einen absoluten Pfad.
APP="$(cd "$APP" && pwd)"

# Eigener Arbeitsordner außerhalb jedes App-Containers.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ft-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILED=0

run_case() {
    local name="$1" fixture="$2" expect_data="$3"
    local out="$WORK/$name.out"
    : > "$out"
    local open_args=(-n -W --stdout "$out" --stderr "$WORK/$name.err")
    local app_args=(-smoke-test "$name")

    if [ -n "$fixture" ]; then
        # Kopie im Arbeitsordner: Die App bekommt genau eine Datei. Liegt
        # neben dem Store ein Journal (-wal), wird es vorher in die Kopie
        # eingearbeitet, sonst fehlten die jüngsten Änderungen.
        local copy="$WORK/$name.store"
        cp "$fixture" "$copy"
        if [ -s "$fixture-wal" ]; then
            cp "$fixture-wal" "$copy-wal"
            [ -f "$fixture-shm" ] && cp "$fixture-shm" "$copy-shm"
            if ! /usr/bin/sqlite3 "$copy" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
                echo "  ✗ $name: das Journal des Fixture-Stores ließ sich nicht einarbeiten" >&2
                FAILED=1
                return
            fi
            rm -f "$copy-wal" "$copy-shm"
        fi
        open_args+=(--stdin "$copy")
        app_args+=(-smoke-fixture-stdin)
    fi

    # Über LaunchServices starten: gesandboxte Apps zeigen bei direktem
    # Binary-Start auf macOS 26 kein Fenster (siehe AGENTS.md).
    open "${open_args[@]}" -a "$APP" --args "${app_args[@]}" &
    local opener=$!
    local waited=0
    while ! grep -q '^smoke-result: ' "$out" 2>/dev/null && [ "$waited" -lt "$TIMEOUT" ]; do
        # Endet `open` ohne Ergebnis (Start fehlgeschlagen), nicht weiter warten.
        kill -0 "$opener" 2>/dev/null || break
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
    result="$(sed -n 's/^smoke-result: //p' "$out" 2>/dev/null | tail -n 1)"
    if [ -z "$result" ]; then
        if [ "$waited" -ge "$TIMEOUT" ]; then
            result="kein Ergebnis nach ${TIMEOUT}s"
        else
            result="die App hat sich ohne Ergebnis beendet"
        fi
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

if [ "$FAILED" = 1 ]; then
    echo "Rauchtest fehlgeschlagen." >&2
    exit 1
fi
echo "Rauchtest bestanden."
