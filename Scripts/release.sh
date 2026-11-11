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
# Code-Signatur: „Developer ID Application" aus dem Schlüsselbund (die erste
# gefundene, oder FT_SIGNING_IDENTITY="Developer ID Application: … (TEAM)").
# Der Build wird mit Hardened Runtime und sicherem Zeitstempel signiert, bei
# Apple notarisiert (notarytool, Schlüsselbund-Profil FT_NOTARY_PROFILE,
# Standard "financetracker-notary") und gestapelt. Erst danach wird die
# ZIP gepackt und mit Sparkle signiert. Ohne Developer ID bricht das Script
# ab: Die Release-Entitlements erlauben keine fremden Bibliotheken mehr,
# eine selbst signierte App lüde Sparkle nicht.
#
# Notary-Profil einmalig anlegen (Passwort = App-spezifisches Passwort von
# appleid.apple.com, wird nur im Schlüsselbund gespeichert):
#   xcrun notarytool store-credentials financetracker-notary \
#       --apple-id <Apple-ID> --team-id <Team-ID>
#
# --dry-run: Build, Notarisierung, ZIP und Appcast laufen echt (im
# Arbeitsbaum), Push, Tag und Release werden nur angezeigt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Muss zu SUFeedURL in Config/FinanceTracker.macOS.Info.plist passen.
REPO="${FT_REPO:-Klabautter/FinanceTracker}"
SPARKLE_ACCOUNT="financetracker"
NOTARY_PROFILE="${FT_NOTARY_PROFILE:-financetracker-notary}"
# Developer-ID-Provisioning-Profil (Name im Developer-Portal). Es gibt der App
# ihre Kennung und die Schlüsselbund-Gruppe, ohne die macOS bei jedem Zugriff
# auf den Enable-Banking-Schlüssel fragt.
PROVISIONING_PROFILE="${FT_PROVISIONING_PROFILE:-FinanceTracker Developer ID}"
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

IDENTITY="${FT_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
fi
case "$IDENTITY" in
    "Developer ID Application: "*"("*")") ;;
    *)
        echo "Keine Developer-ID-Signatur gefunden (FT_SIGNING_IDENTITY=\"$IDENTITY\")." >&2
        echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
        exit 1 ;;
esac
TEAM_ID="${IDENTITY##*(}"; TEAM_ID="${TEAM_ID%)}"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "Notary-Profil \"$NOTARY_PROFILE\" fehlt oder ist ungültig. Einmalig anlegen:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple-ID> --team-id $TEAM_ID" >&2
    exit 1
}
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE_FOUND=0
for profile in "$PROFILE_DIR"/*.provisionprofile; do
    [ -f "$profile" ] || continue
    name="$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)"
    if [ "$name" = "$PROVISIONING_PROFILE" ]; then PROFILE_FOUND=1; break; fi
done
[ "$PROFILE_FOUND" = 1 ] || {
    echo "Provisioning-Profil \"$PROVISIONING_PROFILE\" fehlt in $PROFILE_DIR." >&2
    echo "developer.apple.com → Profiles → + → Developer ID → App-ID de.klabautter.FinanceTracker," >&2
    echo "herunterladen und als <UUID>.provisionprofile in diesen Ordner kopieren." >&2
    exit 1
}
echo "   Signatur: $IDENTITY, Profil: $PROVISIONING_PROFILE, Notary-Profil: $NOTARY_PROFILE"

# --- 2. Bauen, signieren, notarisieren, packen ------------------------------

echo "→ Erzeuge Projekt und baue Release …"
xcodegen generate >/dev/null
xcodebuild build -project FinanceTracker.xcodeproj -scheme FinanceTracker \
    -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID" \
    "PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE" \
    "OTHER_CODE_SIGN_FLAGS=--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO 2>&1 \
    | grep -E " error: |BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/FinanceTracker.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen: $APP fehlt" >&2; exit 1; }

# Sparkles Hilfsprogramme von innen nach außen mit der Developer ID neu
# signieren, sonst lehnt die Notarisierung sie ab
# (sparkle-project.org/documentation/sandboxing/#code-signing).
echo "→ Signiere Sparkle-Komponenten und App …"
FW="$APP/Contents/Frameworks/Sparkle.framework"
CS=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
"${CS[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${CS[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${CS[@]}" "$FW/Versions/B/Autoupdate"
"${CS[@]}" "$FW/Versions/B/Updater.app"
"${CS[@]}" "$FW"
# App zuletzt; Entitlements (Sandbox usw.) bleiben wie von Xcode gesetzt.
"${CS[@]}" --preserve-metadata=entitlements,requirements,flags "$APP"
codesign --verify --deep --strict "$APP"
# Ausgaben erst einsammeln: grep -q in einer Pipe beendet sie vorzeitig,
# und mit pipefail gälte die Prüfung dann als fehlgeschlagen.
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGN_INFO" == *"TeamIdentifier=$TEAM_ID"* ]] || {
    echo "App trägt nicht die Team-ID $TEAM_ID." >&2; exit 1; }
# Debug-Berechtigung: die Notarisierung lehnt sie ab.
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
if [[ "$APP_ENTITLEMENTS" == *"get-task-allow"* ]]; then
    echo "App enthält com.apple.security.get-task-allow, Notarisierung würde scheitern." >&2
    exit 1
fi
# Ohne eingebettetes Profil startet eine App mit Schlüsselbund-Gruppe nicht.
[ -f "$APP/Contents/embedded.provisionprofile" ] \
    && [[ "$APP_ENTITLEMENTS" == *"$TEAM_ID.de.klabautter.FinanceTracker"* ]] || {
    echo "Provisioning-Profil oder App-Kennung fehlt in der App." >&2; exit 1; }

echo "→ Notarisiere bei Apple (dauert meist wenige Minuten) …"
NOTARY_ZIP="$ROOT/build/FinanceTracker-notarize.zip"
mkdir -p "$ROOT/build"
rm -f "$NOTARY_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
NOTARY_OUT="$(xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
rm -f "$NOTARY_ZIP"
# notarytool meldet die ID bei jedem Zwischenstand erneut: nur einmal zeigen.
grep -E "^\s*(id|status):" <<<"$NOTARY_OUT" | sed 's/^ *//' | awk '!seen[$0]++' | sed 's/^/   /' || true
if ! grep -qE "^\s*status: Accepted" <<<"$NOTARY_OUT"; then
    SUBMISSION_ID="$(echo "$NOTARY_OUT" | sed -n 's/^ *id: //p' | head -1)"
    echo "Notarisierung nicht akzeptiert." >&2
    [ -n "$SUBMISSION_ID" ] && echo "Details: xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
    echo "$NOTARY_OUT" >&2
    exit 1
fi
xcrun stapler staple "$APP" >/dev/null
xcrun stapler validate "$APP" >/dev/null
spctl --assess --type execute "$APP" || { echo "Gatekeeper lehnt die App ab." >&2; exit 1; }
echo "   Notarisiert, gestapelt, von Gatekeeper akzeptiert."

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
