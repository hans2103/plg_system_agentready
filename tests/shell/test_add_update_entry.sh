#!/bin/bash
# Test voor bin/add-update-entry.php. Gebruik: bash tests/shell/test_add_update_entry.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

add() { php "$repo/bin/add-update-entry.php" "$@"; }
count() { grep -c '<update>' "$1"; }

cp "$repo/$UPDATES_XML" "$tmp/updates.xml"
firstVersion=$(grep -m1 '<version>' "$tmp/updates.xml" | sed -E 's#.*<version>([^<]+)</version>.*#\1#')
before=$(count "$tmp/updates.xml")

run add 99.1.0 "$tmp/updates.xml"; same "toevoegen geeft exit 0" 0 "$rc"
xmllint --noout "$tmp/updates.xml" && pass "updates.xml is na het toevoegen geldige XML" || bad "updates.xml is ongeldig na het toevoegen"
same "één entry extra" "$((before + 1))" "$(count "$tmp/updates.xml")"
# De downloadlink van de nieuwe entry: UPDATE_DOWNLOAD_BASE uit scripts.conf, leeg = de GitHub Release.
# Alleen de nieuwe entry telt; oudere entries in updates.xml kunnen nog een andere vorm hebben.
if [ -n "${UPDATE_DOWNLOAD_BASE:-}" ]; then
  wantUrl="${UPDATE_DOWNLOAD_BASE%/}/${PACKAGE_ELEMENT}-99.1.0.zip"
else
  wantUrl="https://github.com/${GITHUB_REPO}/releases/download/v99.1.0/${PACKAGE_ELEMENT}-99.1.0.zip"
fi
newUrl=$(sed -n '/<version>99.1.0<\/version>/,/<\/update>/p' "$tmp/updates.xml" | grep -m1 '<downloadurl' | sed -E 's#.*>([^<]+)</downloadurl>.*#\1#')
same "download-URL van de nieuwe entry (UPDATE_DOWNLOAD_BASE of GitHub Release)" "$wantUrl" "$newUrl"
# Een repo zonder release heeft nog geen entry om te bewaren of te ordenen.
if [ -n "$firstVersion" ]; then
  grep -q "<version>${firstVersion}</version>" "$tmp/updates.xml" && pass "bestaande entry blijft" || bad "bestaande entry is verdwenen"
fi
grep -q "<name>${UPDATE_NAME}</name>" "$tmp/updates.xml" && pass "naam uit UPDATE_NAME" || bad "UPDATE_NAME niet gebruikt"
grep -qF "version=\"${UPDATE_TARGETPLATFORM}\"" "$tmp/updates.xml" && pass "targetplatform uit UPDATE_TARGETPLATFORM" || bad "UPDATE_TARGETPLATFORM niet gebruikt"
# Nieuwste bovenaan: de nieuwe versie komt vóór de eerste bestaande.
new_line=$(grep -n '<version>99.1.0</version>' "$tmp/updates.xml" | head -1 | cut -d: -f1)
old_line=$(grep -n "<version>${firstVersion}</version>" "$tmp/updates.xml" | head -1 | cut -d: -f1)
if [ -n "$firstVersion" ]; then
  [ "$new_line" -lt "$old_line" ] && pass "nieuwste release staat bovenaan" || bad "nieuwe entry staat niet bovenaan"
fi

# Zonder pakket-zip (packages/99.1.0/ bestaat niet): wel een entry, geen <sha512> (issue #257).
sed -n '/<version>99.1.0<\/version>/,/<\/update>/p' "$tmp/updates.xml" | grep -q '<sha512>' && bad "zonder zip toch een <sha512>" || pass "zonder pakket-zip geen <sha512>"

sum1=$(cksum < "$tmp/updates.xml")
run add 99.1.0 "$tmp/updates.xml"; same "tweede run geeft exit 0" 0 "$rc"
[ "$(cksum < "$tmp/updates.xml")" = "$sum1" ] && pass "idempotent: tweede run laat het bestand ongemoeid" || bad "tweede run wijzigde het bestand"

# Optionele velden: een repo zonder UPDATE_MAINTAINER krijgt geen <maintainer>, en een instelling
# uit de omgeving wint van scripts.conf. Eigen minimale repo-indeling, zodat scripts.conf klein blijft.
mkdir -p "$tmp/min/bin"; cp "$repo/bin/add-update-entry.php" "$tmp/min/bin/"
cat > "$tmp/min/scripts.conf" <<'CONF'
PACKAGE_ELEMENT="pkg_minimaal"
GITHUB_REPO="acme/minimaal"
UPDATE_NAME="Minimaal"
UPDATE_MAINTAINER=""
CONF
printf '<?xml version="1.0"?>\n<updates>\n</updates>\n' > "$tmp/min/updates.xml"
run php "$tmp/min/bin/add-update-entry.php" 99.2.0; same "minimale configuratie geeft exit 0" 0 "$rc"
grep -q '<name>Minimaal</name>' "$tmp/min/updates.xml" && pass "naam uit scripts.conf" || bad "naam niet uit scripts.conf"
grep -q 'acme/minimaal/releases/download/v99.2.0/pkg_minimaal-99.2.0.zip' "$tmp/min/updates.xml" && pass "download-URL uit PACKAGE_ELEMENT en GITHUB_REPO" || bad "download-URL klopt niet"
grep -q '<maintainer>' "$tmp/min/updates.xml" && bad "lege UPDATE_MAINTAINER gaf toch <maintainer>" || pass "lege UPDATE_MAINTAINER geeft geen <maintainer>"
grep -q '<description>' "$tmp/min/updates.xml" && bad "zonder UPDATE_DESCRIPTION toch een <description>" || pass "zonder UPDATE_DESCRIPTION geen <description>"
UPDATE_NAME="Omgeving" run php "$tmp/min/bin/add-update-entry.php" 99.3.0
grep -A0 '<name>Omgeving</name>' "$tmp/min/updates.xml" > /dev/null && pass "omgeving wint van scripts.conf" || bad "omgevingsvariabele niet gebruikt"
# Eigen downloadserver: UPDATE_DOWNLOAD_BASE (een slash aan het eind wordt genegeerd) vervangt de GitHub-link.
UPDATE_DOWNLOAD_BASE="https://updates.example/minimaal/" run php "$tmp/min/bin/add-update-entry.php" 99.5.0
same "UPDATE_DOWNLOAD_BASE geeft exit 0" 0 "$rc"
grep -q '>https://updates.example/minimaal/pkg_minimaal-99.5.0.zip<' "$tmp/min/updates.xml" && pass "download-URL uit UPDATE_DOWNLOAD_BASE" || bad "UPDATE_DOWNLOAD_BASE niet gebruikt"
grep -q 'releases/download/v99.5.0/' "$tmp/min/updates.xml" && bad "met UPDATE_DOWNLOAD_BASE toch een GitHub-link" || pass "  en geen GitHub-link"
# Checksum (issue #257): --zip=pad geeft de sha512 van die zip; zonder --zip de uitvoer van package.sh.
printf 'pakketinhoud' > "$tmp/pakket.zip"
want=$(php -r 'echo hash_file("sha512", $argv[1]);' "$tmp/pakket.zip")
run php "$tmp/min/bin/add-update-entry.php" 99.6.0 --zip="$tmp/pakket.zip"
same "--zip geeft exit 0" 0 "$rc"
got=$(sed -n '/<version>99.6.0<\/version>/,/<\/update>/p' "$tmp/min/updates.xml" | grep -m1 '<sha512>' | sed -E 's#.*<sha512>([0-9a-f]+)</sha512>.*#\1#')
same "<sha512> is de hash van de --zip" "$want" "$got"
xmllint --noout "$tmp/min/updates.xml" && pass "met <sha512> geldige XML" || bad "met <sha512> ongeldige XML"
mkdir -p "$tmp/min/packages/99.7.0"; printf 'gebouwd' > "$tmp/min/packages/99.7.0/pkg_minimaal-99.7.0.zip"
want=$(php -r 'echo hash_file("sha512", $argv[1]);' "$tmp/min/packages/99.7.0/pkg_minimaal-99.7.0.zip")
run php "$tmp/min/bin/add-update-entry.php" 99.7.0
got=$(sed -n '/<version>99.7.0<\/version>/,/<\/update>/p' "$tmp/min/updates.xml" | grep -m1 '<sha512>' | sed -E 's#.*<sha512>([0-9a-f]+)</sha512>.*#\1#')
same "zonder --zip de zip uit packages/<versie>/" "$want" "$got"
expect "een --zip die niet bestaat wordt geweigerd" 1 php "$tmp/min/bin/add-update-entry.php" 99.8.0 --zip="$tmp/bestaat-niet.zip"
grep -q '<version>99.8.0</version>' "$tmp/min/updates.xml" && bad "met een ontbrekende --zip toch een entry" || pass "  en er komt geen entry"

printf 'GITHUB_REPO="x/y"\n' > "$tmp/min/scripts.conf"
expect "ontbrekende PACKAGE_ELEMENT" 2 php "$tmp/min/bin/add-update-entry.php" 99.4.0

expect "ongeldige versie wordt geweigerd" 1 add geen-versie "$tmp/updates.xml"
expect "ontbrekend bestand wordt geweigerd" 1 add 99.3.0 "$tmp/bestaat-niet.xml"
printf '<updates>' > "$tmp/kapot.xml"
expect "ongeldige XML wordt geweigerd" 1 add 99.3.0 "$tmp/kapot.xml"

finish
