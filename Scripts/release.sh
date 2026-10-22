#!/bin/bash
# Veröffentlicht ein Release der macOS-App in einem Lauf: Release bauen, ZIP
# packen, Sparkle-Signatur, GitHub-Release mit ZIP, appcast.xml, in der
# Reihenfolge, in der der Update-Check der Nutzer nie auf eine fehlende ZIP
# zeigt. Aufbau wie in PDFdownsize.
#
# Aufruf:  Scripts/release.sh [--dry-run]
#
# Ablauf:
#   1. Vorprüfung: RELEASE_NOTES.md vorhanden, Arbeitsbaum sauber, gh
#      installiert und angemeldet, Tag v<Version> noch nicht auf GitHub.
#   2. Projekt erzeugen, bauen, packen, signieren, appcast.xml schreiben.
#   3. Rückfrage. Dann: Code nach main pushen, Tag v<Version> anlegen und
#      pushen, GitHub-Release mit ZIP und Notizen anlegen.
#   4. ERST JETZT appcast.xml committen und pushen, ab da sehen die
#      installierten Apps das Update und finden die ZIP.
#
# RELEASE_NOTES.md: erste Zeile = ein Satz für den Update-Dialog, danach eine
# Leerzeile, danach die Notizen für die GitHub-Release-Seite (Markdown).
#
# Version: MARKETING_VERSION und CURRENT_PROJECT_VERSION in project.yml. Vor
# jedem Release beide erhöhen: Sparkle vergleicht die Build-Nummer
# (CFBundleVersion), sie muss mit jedem Release steigen.
#
# Signaturschlüssel: privat im macOS-Schlüsselbund (Konto "financetracker",
# angelegt mit Sparkles generate_keys), öffentlich als SUPublicEDKey in
# Config/FinanceTracker.macOS.Info.plist. Er verlässt den Mac nie.
#
# Code-Signatur: standardmäßig das selbst signierte Zertifikat „FinanceTracker
# Release" aus dem Schlüsselbund, sonst FT_SIGNING_IDENTITY="Name". Ohne
# Developer-ID bekommt jeder Build sonst eine neue Ad-hoc-Signatur, und macOS
# fragt nach jedem Update erneut nach dem Schlüsselbund-Zugriff (Enable-
# Banking-Schlüssel). Ein selbst erstelltes Zertifikat (Schlüsselbund-
# verwaltung → Zertifikatsassistent → Code-Signierung) hält die Signatur
# über Updates gleich.
#
# --dry-run: Build, ZIP und Appcast laufen echt (im Arbeitsbaum), Push, Tag
# und Release werden nur angezeigt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Muss zu SUFeedURL in Config/FinanceTracker.macOS.Info.plist passen.
REPO="${FT_REPO:-Klabautter/FinanceTracker}"
SPARKLE_ACCOUNT="financetracker"
DERIVED="${FT_DERIVED_DATA:-$ROOT/build/release}"
NOTES_FILE="$ROOT/RELEASE_NOTES.md"
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unbekanntes Argument: $arg" >&2; echo "Aufruf: Scripts/release.sh [--dry-run]" >&2; exit 2 ;;
    esac
done

run() {
    # Führt einen Schritt aus, der nach außen wirkt, im Trockenlauf nur anzeigen.
    if [ "$DRY_RUN" = 1 ]; then
        printf '   (dry-run) %q' "$1"; shift
        for a in "$@"; do printf ' %q' "$a"; done
        echo
    else
        "$@"
    fi
}

# --- 1. Vorprüfung ----------------------------------------------------------

echo "→ Vorprüfung …"
[ -s "$NOTES_FILE" ] || {
    echo "RELEASE_NOTES.md fehlt oder ist leer. Erste Zeile: ein Satz für den" >&2
    echo "Update-Dialog, dann Leerzeile, dann die Notizen für GitHub (Markdown)." >&2
    exit 1
}
SUMMARY="$(head -n 1 "$NOTES_FILE")"
[ -n "$SUMMARY" ] || { echo "RELEASE_NOTES.md: erste Zeile ist leer." >&2; exit 1; }

FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Config/FinanceTracker.macOS.Info.plist)"
[ "$FEED" = "https://raw.githubusercontent.com/$REPO/main/appcast.xml" ] || {
    echo "SUFeedURL ($FEED) passt nicht zu REPO=$REPO." >&2; exit 1; }

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Arbeitsbaum ist nicht sauber, erst committen, das Release zeigt auf HEAD:" >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh fehlt: brew install gh, dann gh auth login" >&2; exit 1; }
if [ "$DRY_RUN" = 0 ]; then
    gh auth status -h github.com >/dev/null 2>&1 || { echo "gh ist nicht angemeldet: gh auth login" >&2; exit 1; }
fi

VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
[ -n "$VERSION" ] || { echo "MARKETING_VERSION in project.yml nicht lesbar" >&2; exit 1; }
TAG="v$VERSION"
if [ "$DRY_RUN" = 0 ]; then
    if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
        echo "Tag $TAG liegt schon auf GitHub: Version in project.yml erhöhen." >&2
        exit 1
    fi
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "Release $TAG existiert schon auf GitHub." >&2
        exit 1
    fi
fi
echo "   Version $VERSION, Tag $TAG, Notizen: $SUMMARY"

# --- 2. Bauen, packen, signieren -------------------------------------------

echo "→ Erzeuge Projekt und baue Release …"
xcodegen generate >/dev/null
SIGN_ARGS=()
# Standard: das selbst signierte Zertifikat aus dem Schlüsselbund, sofern vorhanden.
if [ -z "${FT_SIGNING_IDENTITY:-}" ] && security find-certificate -c "FinanceTracker Release" >/dev/null 2>&1; then
    FT_SIGNING_IDENTITY="FinanceTracker Release"
fi
if [ -n "${FT_SIGNING_IDENTITY:-}" ]; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$FT_SIGNING_IDENTITY" DEVELOPMENT_TEAM=)
    echo "   Code-Signatur: $FT_SIGNING_IDENTITY"
else
    echo "   Code-Signatur: ad hoc (FT_SIGNING_IDENTITY nicht gesetzt)"
fi
xcodebuild build -project FinanceTracker.xcodeproj -scheme FinanceTracker \
    -configuration Release -derivedDataPath "$DERIVED" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} 2>&1 \
    | grep -E " error: |BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/FinanceTracker.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen: $APP fehlt" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || {
    echo "Gebaute Version $BUILT_VERSION ≠ Projektversion $VERSION" >&2; exit 1; }
ZIP="$ROOT/build/FinanceTracker-$VERSION.zip"

mkdir -p "$ROOT/build"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SIGN="$(find "$DERIVED/SourcePackages/artifacts" -name sign_update -type f | head -1)"
[ -x "$SIGN" ] || { echo "sign_update nicht gefunden" >&2; exit 1; }
# Ausgabe: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN" --account "$SPARKLE_ACCOUNT" "$ZIP")"

cat > "$ROOT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FinanceTracker</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <description><![CDATA[$SUMMARY]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/FinanceTracker-$VERSION.zip"
                 $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

# Die gebaute App steckt in der ZIP; eine zweite FinanceTracker.app im
# Projektordner tauchte sonst in Spotlight neben der installierten auf.
rm -rf "$APP"

echo
echo "Version $VERSION (Build $BUILD)"
echo "ZIP:     $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo

# --- 3. Veröffentlichen ----------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
    echo "Trockenlauf, diese Schritte würden folgen:"
else
    printf 'main und Tag %s pushen, Release mit ZIP anlegen, dann Appcast pushen? [j/N] ' "$TAG"
    read -r answer
    case "$answer" in
        j|J|ja|Ja|y|Y) ;;
        *) echo "Abgebrochen. ZIP und appcast.xml liegen im Arbeitsbaum (nicht committet)."; exit 0 ;;
    esac
fi

echo "→ Code pushen (das Release zeigt auf diesen Stand) …"
run git push origin HEAD:main
echo "→ Tag $TAG anlegen und pushen …"
run git tag -a "$TAG" -m "FinanceTracker $VERSION"
run git push origin "$TAG"
echo "→ GitHub-Release $TAG mit ZIP anlegen …"
run gh release create "$TAG" "$ZIP" -R "$REPO" --title "FinanceTracker $VERSION" \
    --notes-file "$NOTES_FILE" --verify-tag

# --- 4. Appcast live schalten ----------------------------------------------

echo "→ appcast.xml committen und pushen, ab jetzt sehen Nutzer das Update …"
run git add appcast.xml
run git commit -m "Update appcast for $VERSION"
run git push origin HEAD:main

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "Trockenlauf beendet. Nichts gepusht, kein Tag, kein Release."
    echo "appcast.xml im Arbeitsbaum ist neu geschrieben: git checkout appcast.xml, falls unerwünscht."
else
    echo "Fertig: https://github.com/$REPO/releases/tag/$TAG"
fi
