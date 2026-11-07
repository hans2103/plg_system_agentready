#!/bin/bash
# Test voor bin/run-release.sh (--print-version, --dry-run, opties). Gebruik: bash tests/shell/test_run_release.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Wegwerp-repo met de scripts, de configuratie en tags in beide stijlen (met en zonder v).
r="$tmp/r"
mkdir -p "$r"; git_init "$r"
cp -R "$repo/bin" "$r/bin"; cp "$repo/scripts.conf" "$r/"
printf '<extension><version>26.1.0</version></extension>\n' > "$r/package.xml"; echo '#!/bin/bash' > "$r/package.sh"
( cd "$r" && git add -A && git commit -q -m init && for t in 26.38.0 v26.38.1 26.37.5 25.38.9; do git tag "$t"; done )
rel() { ( cd "$r" && bash bin/run-release.sh "$@" ); }

same "volgend patchnummer in dezelfde week" 26.38.2 "$(RELEASE_YY=26 RELEASE_WW=38 rel --print-version)"
same "nieuwe week begint bij 0"               26.39.0 "$(RELEASE_YY=26 RELEASE_WW=39 rel --print-version)"
same "weeknummer zonder voorloopnul"          26.3.0  "$(RELEASE_YY=26 RELEASE_WW=3  rel --print-version)"
( cd "$r" && git tag 26.38.9 && git tag v26.38.10 )
same "patchnummers sorteren numeriek"         26.38.11 "$(RELEASE_YY=26 RELEASE_WW=38 rel --print-version)"

# Jaarwisseling: jaar en week komen uit het ISO-weekjaar (%G), niet uit het kalenderjaar.
same "29 dec 2025 is ISO-week 1 van 2026"      26.1.0  "$(RELEASE_DATE=2025-12-29 rel --print-version)"
same "1 jan 2027 is ISO-week 53 van 2026"      26.53.0 "$(RELEASE_DATE=2027-01-01 rel --print-version)"
same "gewone datum geeft jaar en week"         26.39.0 "$(RELEASE_DATE=2026-09-21 rel --print-version)"

# --dry-run wijzigt niets, ook niet met een vuile werkmap, en gaat niet naar het netwerk.
echo vuil > "$r/vuil.txt"
before="$( cd "$r" && git status --porcelain; git rev-parse HEAD; git tag | wc -l )"
run rel 99.1.0 --dry-run
same "--dry-run eindigt met exit 0" 0 "$rc"
has "--dry-run meldt dat niets is gewijzigd" 'Dry run — er is niets gewijzigd'
has "--dry-run toont de nieuwe versie" 'Nieuwe versie: +99\.1\.0'
has "--dry-run toont de huidige versie" 'Huidige versie: +26\.1\.0'
has "--dry-run noemt de GitHub-repo" "$GITHUB_REPO"
after="$( cd "$r" && git status --porcelain; git rev-parse HEAD; git tag | wc -l )"
[ "$before" = "$after" ] && pass "--dry-run laat de repo ongemoeid" || bad "--dry-run wijzigde de repo"
rm -f "$r/vuil.txt"

# Een echte run weigert een vuile werkmap voordat er iets gebeurt.
echo vuil > "$r/vuil.txt"
run rel 99.1.0 --yes; same "vuile werkmap wordt geweigerd" 1 "$rc"; has "  met uitleg" 'werkmap is niet schoon'
rm -f "$r/vuil.txt"

expect "ongeldige versie wordt geweigerd" 1 rel geen-versie --dry-run
expect "bestaande tag wordt geweigerd" 1 rel 26.38.1 --dry-run   # tag v26.38.1 bestaat
expect "onbekende optie geeft exit 2" 2 rel --nope
expect "--help" 0 rel --help
has "  toont het gebruik" 'Gebruik: bash bin/run-release.sh'

# --install schrijft een wrapper die het script van de huidige repo start (HOME omgeleid).
mkdir -p "$tmp/home"
HOME="$tmp/home" rel --install > /dev/null 2>&1
[ -x "$tmp/home/bin/release" ] && pass "--install maakt ~/bin/release aan" || bad "--install maakte geen wrapper"
same "wrapper start het script van de huidige repo" "$(RELEASE_YY=26 RELEASE_WW=39 rel --print-version)" "$( cd "$r" && RELEASE_YY=26 RELEASE_WW=39 bash "$tmp/home/bin/release" --print-version )"

# Overgang: in een repo die nog Scripts/ heeft, start de wrapper het script daar.
old="$tmp/oud"; git clone -q "$r" "$old"; mv "$old/bin" "$old/Scripts"
same "wrapper valt terug op Scripts/" "$(RELEASE_YY=26 RELEASE_WW=39 rel --print-version)" "$( cd "$old" && RELEASE_YY=26 RELEASE_WW=39 bash "$tmp/home/bin/release" --print-version )"
rm -rf "$old/Scripts"
expect "wrapper zonder bin/ en Scripts/ geeft exit 1" 1 bash -c "cd '$old' && bash '$tmp/home/bin/release' --print-version"

finish
