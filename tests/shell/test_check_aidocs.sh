#!/bin/bash
# Test voor bin/check-aidocs.php (modi structure en coverage) met wegwerp-git-repo's.
# Gebruik: bash tests/shell/test_check_aidocs.sh
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tpl="$tmp/tpl"
fx="$tmp/fx"
failed=0
rc=0

git_quiet() { git -C "$1" -c commit.gpgsign=false "${@:2}" > /dev/null 2>&1; }

write_page() { # bestand titel sha cover...
  local file="$1" title="$2" sha="$3"; shift 3
  { printf '# %s\n\n### History\n- 2026-09-19: aangemaakt\n\nLast updated: 2026-09-19\nVerified against: %s\nCovers:\n' "$title" "$sha"
    for c in "$@"; do printf -- '- %s\n' "$c"; done
    printf '\n## Doel\n\nTekst.\n'
  } > "$file"
}

# Sjabloon: main heeft twee commits (README; daarna alles), develop staat op de eerste, topic op main.
mkdir -p "$tpl/bin" "$tpl/AIdocs/sub" "$tpl/Src/ext/a/deep" "$tpl/Src/ext/ab" "$tpl/Src/ext/b" "$tpl/Src/ext/c"
cp "$repo/bin/check-aidocs.php" "$tpl/bin/"
( cd "$tpl" && git init -q -b main && git config user.email t@t && git config user.name t && echo r > README.md && git add -A ) > /dev/null 2>&1
git_quiet "$tpl" commit -q -m een
first="$(git -C "$tpl" rev-parse HEAD)"
git -C "$tpl" branch develop "$first"

for f in Src/ext/a/x.php Src/ext/a/deep/f.php Src/ext/ab/f.php Src/ext/b/z.php Src/ext/c/old.php package.xml package.sh package_script.php; do
  printf '<?php // %s\n' "$f" > "$tpl/$f"
done
printf 'Pointer naar AIdocs/alpha.md\n' > "$tpl/Src/ext/CLAUDE.md"
write_page "$tpl/AIdocs/alpha.md" Alpha "$first" Src/ext/a/ Src/ext/b/z.php
write_page "$tpl/AIdocs/sub/beta.md" Beta "$first" package.xml package.sh
printf '# Index\n\n- [Alpha](alpha.md)\n- [Sub](sub/_index.md)\n' > "$tpl/AIdocs/_index.md"
printf '# Sub\n\n- [Beta](beta.md)\n' > "$tpl/AIdocs/sub/_index.md"
( cd "$tpl" && git add -A ) > /dev/null 2>&1
git_quiet "$tpl" commit -q -m twee
git_quiet "$tpl" checkout -q -b topic

fresh() { rm -rf "$fx"; cp -R "$tpl" "$fx"; }
sub() { perl -pi -e "$2" "$fx/$1"; } # bestand perl-expressie
commit_all() { git_quiet "$fx" add -A; git_quiet "$fx" commit -q -m wijziging; }
in="" # submap van $fx waarin run() het script start (leeg = de root)
run() { ( cd "$fx/$in" && php "$fx/bin/check-aidocs.php" "$@" ) > "$tmp/out.txt" 2>&1; rc=$?; }
report() { # label slechte-reden
  if [ -z "$2" ]; then echo "ok:   $1"; else echo "FAIL: $1 ($2)"; sed 's/^/      /' "$tmp/out.txt" | tail -6; failed=1; fi
}
t() { # label verwachte-exitcode patroon(- = geen eis) args...
  local label="$1" want="$2" pat="$3" bad=""; shift 3
  run "$@"
  [ "$rc" -eq "$want" ] || bad="exit $rc, verwachtte $want"
  if [ -z "$bad" ] && [ "$pat" != "-" ] && ! grep -q -- "$pat" "$tmp/out.txt"; then bad="uitvoer mist '$pat'"; fi
  report "$label" "$bad"
}
also() { # label patroon: de uitvoer van de vorige run bevat ook dit patroon
  if grep -q -- "$2" "$tmp/out.txt"; then report "$1" ""; else report "$1" "uitvoer mist '$2'"; fi
}
nophpwarn() { # geen PHP-melding (Warning/Notice/Deprecated/Fatal/Uncaught) in de uitvoer van de vorige run
  if grep -Eq 'Warning:|Notice:|Deprecated:|Fatal error|Uncaught|Uninitialized' "$tmp/out.txt"; then report "$1" "PHP-melding in de uitvoer"; else report "$1" ""; fi
}
silent() { if [ -s "$tmp/out.txt" ]; then report "$1" "uitvoer niet leeg"; else report "$1" ""; fi; }

echo "== structure"
fresh; t "schoon sjabloon" 0 - structure; silent "schoon sjabloon geeft geen uitvoer"
fresh; sub AIdocs/alpha.md 's/^Last updated:.*\n//'; t "Last updated ontbreekt" 1 "Last updated" structure
fresh; sub AIdocs/alpha.md 's/^Last updated:.*/Last updated: 2026-02-30/'; t "onmogelijke datum" 1 "Last updated" structure
fresh; sub AIdocs/alpha.md 's/^Last updated:.*/Last updated: gisteren/'; t "datum in verkeerd formaat" 1 "Last updated" structure
fresh; sub AIdocs/alpha.md 's/^Verified against:.*\n//'; t "Verified against ontbreekt" 1 "Verified against" structure
fresh; sub AIdocs/alpha.md 's/^Verified against:.*/Verified against: zzz/'; t "Verified against is geen sha" 1 "Verified against" structure
fresh; sub AIdocs/alpha.md 's/^Verified against:.*/Verified against: abcdef1/'; t "onbekende sha is alleen een waarschuwing" 0 "WARNING: AIdocs/alpha.md" structure
fresh; sub AIdocs/alpha.md 's/^Covers:.*\n//; s/^- Src.*\n//'; t "Covers ontbreekt" 1 "Covers" structure
fresh; sub AIdocs/alpha.md 's/^- Src.*\n//'; t "Covers is leeg" 1 "Covers" structure
fresh; sub AIdocs/alpha.md 's#^- Src/ext/a/#- Src/ext/nope/#'; t "Covers-pad bestaat niet" 1 "Src/ext/nope/" structure
fresh; sub AIdocs/alpha.md 's#^- Src/ext/a/$#- Src/ext/a#'; t "Covers-map zonder slash" 1 "moet op /" structure
fresh; sub AIdocs/alpha.md 's#^- Src/ext/a/$#- /etc/passwd#'; t "Covers-pad absoluut" 1 "relatief" structure
fresh; sub AIdocs/alpha.md 's#^- Src/ext/a/$#- Src/../Src/ext/a/#'; t "Covers-pad met .." 1 "relatief" structure
fresh; printf '<?php\n' > "$fx/Src/ext/a/foo..bar.php"; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n- Src/ext/a/foo..bar.php#'; t "Covers-pad met .. in een bestandsnaam is toegestaan" 0 - structure
fresh; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n- Src/ext/a/..#'; t "Covers-pad eindigend op een .. segment" 1 "relatief" structure
fresh; sub AIdocs/alpha.md 's#^- (Src/ext/a/)$#- `$1`#'; t "Covers-pad tussen backticks" 0 - structure
fresh; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n- ``#'; t "leeg Covers-item (alleen backticks)" 1 "Covers-pad is leeg" structure; nophpwarn "leeg Covers-item geeft geen PHP-melding"
fresh; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n-   #'; t "Covers-item met alleen spaties" 1 "Covers-pad is leeg" structure; nophpwarn "Covers-item met alleen spaties geeft geen PHP-melding"
fresh; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n-#; s#^- Src/ext/b/z.php$#- Src/ext/nope.php#'; t "kaal streepje in de Covers-lijst" 1 "Covers-pad is leeg" structure; also "kaal streepje beëindigt de lijst niet" "Src/ext/nope.php"
fresh; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n- #; s#^- Src/ext/b/z.php$#- Src/ext/nope.php#'; t "streepje met spatie in de Covers-lijst" 1 "Covers-pad is leeg" structure; also "streepje met spatie beëindigt de lijst niet" "Src/ext/nope.php"
fresh; sub AIdocs/alpha.md 's#^(- Src/ext/a/)$#$1\n-foo#; s#^- Src/ext/b/z.php$#- Src/ext/nope.php#'; t "-foo zonder spatie is geen lijstitem en beëindigt de lijst" 0 - structure
fresh; sub AIdocs/alpha.md 's/^## Doel/## Doel\nCovers:\n- Src\/nope\//'; t "Covers na de eerste ## telt niet mee" 0 - structure
fresh; printf 'Verified against: deadbee\n' >> "$fx/AIdocs/alpha.md"; t "velden na de header worden genegeerd" 0 - structure
fresh; printf '\n- [Extra](extra.md)\n' >> "$fx/AIdocs/_index.md"; t "dode verwijzing in de index" 1 "extra.md" structure
fresh; printf '\n- [Site](https://example.com/x) en [anker](#top)\n' >> "$fx/AIdocs/_index.md"; t "externe links en ankers zijn geen dode verwijzing" 0 - structure
fresh; write_page "$fx/AIdocs/gamma.md" Gamma "$first" package.xml; t "pagina niet in de index" 1 "niet vermeld in AIdocs/_index.md" structure
fresh; printf '# Index\n\n- [Alpha](alpha.md)\n' > "$fx/AIdocs/_index.md"; t "submap-index niet in de bovenliggende index" 1 "AIdocs/sub/_index.md: niet vermeld in AIdocs/_index.md" structure
fresh; rm "$fx/AIdocs/sub/_index.md"; t "submap zonder _index.md" 1 "AIdocs/sub: _index.md ontbreekt" structure
fresh; mkdir -p "$fx/AIdocs/x/y"; write_page "$fx/AIdocs/x/y/p.md" P "$first" package.xml; printf '# Y\n\n- [P](p.md)\n' > "$fx/AIdocs/x/y/_index.md"
t "geneste map zonder _index.md in de tussenliggende map" 1 "AIdocs/x: _index.md ontbreekt" structure
fresh; mkdir -p "$fx/AIdocs/x/y"; write_page "$fx/AIdocs/x/y/p.md" P "$first" package.xml; printf '# Y\n\n- [P](p.md)\n' > "$fx/AIdocs/x/y/_index.md"
printf '# X\n\n- [Y](y/_index.md)\n' > "$fx/AIdocs/x/_index.md"; printf '\n- [X](x/_index.md)\n' >> "$fx/AIdocs/_index.md"
t "geneste mappen met complete indexen" 0 - structure; silent "geneste mappen met complete indexen geven geen uitvoer"
fresh; mkdir -p "$fx/AIdocs/x/y"; write_page "$fx/AIdocs/x/y/p.md" P "$first" package.xml; printf '# Y\n\n- [P](p.md)\n' > "$fx/AIdocs/x/y/_index.md"
printf '# X\n' > "$fx/AIdocs/x/_index.md"; printf '\n- [X](x/_index.md)\n' >> "$fx/AIdocs/_index.md"
t "geneste map-index niet in de index van de tussenliggende map" 1 "AIdocs/x/y/_index.md: niet vermeld in AIdocs/x/_index.md" structure
fresh; printf '# Sub\n' > "$fx/AIdocs/sub/_index.md"; t "pagina niet in de submap-index" 1 "AIdocs/sub/beta.md: niet vermeld" structure
fresh; rm "$fx/AIdocs/_index.md"; t "root-index ontbreekt" 1 "_index.md ontbreekt" structure
fresh; rm -rf "$fx/AIdocs"; t "AIdocs ontbreekt" 1 "_index.md ontbreekt" structure
fresh; printf 'Geen verwijzing\n' > "$fx/Src/ext/CLAUDE.md"; t "pointer zonder verwijzing" 1 "Src/ext/CLAUDE.md: verwijst niet" structure
fresh; printf 'Zie AIdocs/nope.md\n' > "$fx/Src/ext/CLAUDE.md"; t "pointer naar ontbrekende pagina" 1 "AIdocs/nope.md" structure
fresh; mkdir -p "$fx/Src/ext/vendor/x"; printf 'niets\n' > "$fx/Src/ext/vendor/x/CLAUDE.md"; t "CLAUDE.md in vendor telt niet" 0 - structure
fresh; sub AIdocs/sub/beta.md 's/^Last updated:.*\n//'; t "paginanaam als argument: kapotte pagina" 1 "beta.md" structure AIdocs/sub/beta.md
fresh; sub AIdocs/sub/beta.md 's/^Last updated:.*\n//'; in=Src/ext; t "relatief argument vanuit een submap: kapotte pagina" 1 "ERROR: AIdocs/sub/beta.md: 'Last updated'" structure ../../AIdocs/sub/beta.md; in=""
fresh; sub AIdocs/sub/beta.md 's/^Last updated:.*\n//'; in=Src/ext; t "relatief argument vanuit een submap: andere pagina" 0 - structure ../../AIdocs/alpha.md; silent "relatief argument vanuit een submap geeft geen uitvoer"; in=""
fresh; sub AIdocs/sub/beta.md 's/^Last updated:.*\n//'; in=AIdocs/sub; t "relatief argument vanuit de map van de pagina" 1 "ERROR: AIdocs/sub/beta.md: 'Last updated'" structure beta.md; in=""
fresh; sub AIdocs/sub/beta.md 's/^Last updated:.*\n//'; in=Src/ext; t "absoluut argument wordt repo-relatief" 1 "ERROR: AIdocs/sub/beta.md: 'Last updated'" structure "$fx/AIdocs/sub/beta.md"; in=""
fresh; in=Src/ext; t "relatief argument naar een ontbrekend bestand" 1 "ERROR: AIdocs/nope.md: bestand bestaat niet" structure ../../AIdocs/nope.md; in=""
fresh; sub AIdocs/sub/beta.md 's/^Last updated:.*\n//'; t "paginanaam als argument: andere pagina" 0 - structure AIdocs/alpha.md
fresh; rm "$fx/AIdocs/_index.md"; t "paginanaam als argument slaat index en pointers over" 0 - structure AIdocs/alpha.md
fresh; t "paginanaam als argument: bestand bestaat niet" 1 "bestaat niet" structure AIdocs/nope.md
fresh; t "leeg paginapad als argument" 1 "leeg paginapad" structure ''; if grep -q "$fx" "$tmp/out.txt"; then report "leeg paginapad toont geen absoluut pad" "absoluut pad in de uitvoer"; else report "leeg paginapad toont geen absoluut pad" ""; fi
fresh; in=Src/ext; t "leeg paginapad vanuit een submap" 1 "leeg paginapad" structure ''; in=""
fresh; write_page "$tmp/buiten.md" Buiten "$first" package.xml; t "pagina buiten de repo: geldige header" 0 - structure "$tmp/buiten.md"; silent "pagina buiten de repo: geldige header geeft geen uitvoer"
fresh; write_page "$tmp/buiten.md" Buiten "$first" package.xml; perl -pi -e 's/^Last updated:.*\n//' "$tmp/buiten.md"; t "pagina buiten de repo: kapotte header" 1 "buiten.md: 'Last updated'" structure "$tmp/buiten.md"
fresh; rm -f "$tmp/bestaatniet.md"; t "pagina buiten de repo die niet bestaat" 1 "bestaatniet.md: bestand bestaat niet" structure "$tmp/bestaatniet.md"
nolek() { # label: de uitvoer bevat het absolute pad van de fixture niet
  if grep -q "$(basename "$tmp")" "$tmp/out.txt"; then report "$1" "absoluut pad in de uitvoer"; else report "$1" ""; fi
}
fresh; t "mapargument: de repo-root" 1 "ERROR: \.: is een map, geen pagina" structure .; nolek "mapargument: de repo-root toont geen absoluut pad"
fresh; t "mapargument: AIdocs" 1 "ERROR: AIdocs: is een map, geen pagina" structure AIdocs; nolek "mapargument: AIdocs toont geen absoluut pad"
fresh; t "mapargument: AIdocs/" 1 "ERROR: AIdocs: is een map, geen pagina" structure AIdocs/
fresh; in=Src/ext; t "mapargument vanuit een submap: de repo-root" 1 "ERROR: \.: is een map, geen pagina" structure ../..; nolek "mapargument vanuit een submap toont geen absoluut pad"; in=""
fresh; t "mapargument buiten de repo" 1 "is een map, geen pagina" structure "$tmp"
fresh; t "_index.md als argument wordt overgeslagen" 0 - structure AIdocs/_index.md
fresh; printf '# Index\n\n- [Alpha](alpha.md#doel)\n- [Sub](./sub/_index.md)\n' > "$fx/AIdocs/_index.md"; t "link met anker en ./ wijst naar een bestaand bestand" 0 - structure
fresh; printf '# Sub\n\n- [Beta](../sub/beta.md)\n' > "$fx/AIdocs/sub/_index.md"; t "link met ../ wordt herleid" 0 - structure
fresh; write_page "$fx/AIdocs/sub/my page.md" Spatie "$first" package.xml; printf '# Sub\n\n- [Beta](beta.md)\n- [My](my%%20page.md)\n' > "$fx/AIdocs/sub/_index.md"
t "link met %20 wijst naar een bestand met een spatie" 0 - structure; silent "link met %20 geeft geen uitvoer"
fresh; write_page "$fx/AIdocs/sub/my page.md" Spatie "$first" package.xml; printf '# Sub\n\n- [Beta](beta.md)\n- [My](<my page.md>)\n' > "$fx/AIdocs/sub/_index.md"
t "link met <...> wijst naar een bestand met een spatie" 0 - structure; silent "link met <...> geeft geen uitvoer"
fresh; write_page "$fx/AIdocs/sub/my page.md" Spatie "$first" package.xml; printf '# Sub\n\n- [Beta](beta.md)\n- [My](<my page.md#doel>)\n' > "$fx/AIdocs/sub/_index.md"
t "link met <...> en anker" 0 - structure
fresh; write_page "$fx/AIdocs/sub/my page.md" Spatie "$first" package.xml; printf '# Index\n\n- [a](alpha.md "Alpha")\n- [Sub](sub/_index.md)\n' > "$fx/AIdocs/_index.md"; printf '# Sub\n\n- [Beta](beta.md '"'"'B'"'"')\n- [b](<my page.md> '"'"'B'"'"')\n' > "$fx/AIdocs/sub/_index.md"
t "links met een titel tussen aanhalingstekens" 0 - structure; silent "links met een titel geven geen uitvoer"
fresh; printf '# Index\n\n- [a](alpha.md "Alpha (test)")\n- [Sub](<sub/_index.md> "Sub")\n' > "$fx/AIdocs/_index.md"
t "titel met haakjes en <...>-doel met titel" 0 - structure
fresh; printf '\n- [x](nope.md "Titel")\n' >> "$fx/AIdocs/_index.md"; t "dode link met titel" 1 "nope.md" structure
fresh; printf '\n- [x](<my nope.md> '"'"'T'"'"')\n' >> "$fx/AIdocs/_index.md"; t "dode <...>-link met titel" 1 "my nope.md" structure
fresh; write_page "$fx/AIdocs/sub/a%20b.md" Procent "$first" package.xml; printf '# Sub\n\n- [Beta](beta.md)\n- [AB](a%%20b.md)\n' > "$fx/AIdocs/sub/_index.md"
t "link naar een bestand met een letterlijke %20 in de naam" 0 - structure
fresh; write_page "$fx/AIdocs/sub/my page.md" Spatie "$first" package.xml; printf '# Sub\n\n- [Beta](beta.md)\n' > "$fx/AIdocs/sub/_index.md"
t "pagina met een spatie die de index niet noemt" 1 "AIdocs/sub/my page.md: niet vermeld" structure
fresh; printf '# Sub\n\n- [Beta](beta.md)\n- [Nee](my%%20nope.md)\n' > "$fx/AIdocs/sub/_index.md"
t "dode link met %20" 1 "my%20nope.md" structure
fresh; printf '# Sub\n\n- [Beta](beta.md)\n- [Nee](<my nope.md>)\n' > "$fx/AIdocs/sub/_index.md"
t "dode link met <...>" 1 "my nope.md" structure

echo "== coverage"
# Alle gevallen hieronder vergelijken met main; develop staat bewust vóór alle pagina's (zie "basisbranch").
fresh; t "geen wijzigingen" 0 - coverage --base main; silent "geen wijzigingen geeft geen uitvoer"
fresh; printf '// meer\n' >> "$fx/Src/ext/a/x.php"; printf '\nMeer.\n' >> "$fx/AIdocs/alpha.md"; commit_all
t "gedekt bestand met meegewijzigde pagina" 0 - coverage --base main; silent "gedekt bestand met meegewijzigde pagina geeft geen uitvoer"
fresh; printf '// meer\n' >> "$fx/Src/ext/a/x.php"; commit_all
t "gedekt bestand met ongewijzigde pagina" 0 "WARNING: Src/ext/a/x.php: gedekt door AIdocs/alpha.md" coverage --base main
fresh; printf '<?php\n' > "$fx/Src/ext/c/nieuw.php"; commit_all
t "nieuw bestand zonder dekking" 1 "ERROR: Src/ext/c/nieuw.php: geen AIdocs-pagina" coverage --base main
fresh; printf '<?php\n' > "$fx/Src/ext/c/ongecommit.php"
t "nieuw bestand dat nog niet gevolgd wordt" 1 "Src/ext/c/ongecommit.php" coverage --base main
fresh; printf '// wijziging\n' >> "$fx/Src/ext/c/old.php"
t "niet gecommitte wijziging van een ongedekt bestand" 1 "Src/ext/c/old.php" coverage --base main
fresh; printf '// wijziging\n' >> "$fx/Src/ext/a/x.php"; printf '\nMeer.\n' >> "$fx/AIdocs/alpha.md"
t "niet gecommitte wijziging met niet gecommitte paginawijziging" 0 - coverage --base main; silent "niet gecommitte wijziging met paginawijziging geeft geen uitvoer"
fresh; git_quiet "$fx" rm -q Src/ext/a/x.php; commit_all
t "verwijderd gedekt bestand, pagina ongewijzigd" 0 "WARNING: Src/ext/a/x.php" coverage --base main
fresh; git_quiet "$fx" rm -q Src/ext/c/old.php; commit_all
t "verwijderd ongedekt bestand" 0 - coverage --base main; silent "verwijderd ongedekt bestand geeft geen uitvoer"
fresh; mkdir -p "$fx/Src/ext/vendor/lib" "$fx/Src/ext/language/en-GB" "$fx/Src/ext/media" "$fx/tests" "$fx/docs"
printf 'x' > "$fx/Src/ext/vendor/lib/a.php"; printf 'x' > "$fx/Src/ext/language/en-GB/x.ini"; printf 'x' > "$fx/Src/ext/media/logo.png"
printf 'x' > "$fx/Src/ext/media/ICON.SVG"; printf 'x' > "$fx/Src/ext/CLAUDE.md"; printf 'x' > "$fx/bin/foo.php"; printf 'x' > "$fx/tests/x.sh"
printf 'x' > "$fx/README.md"; printf 'x' > "$fx/docs/a.md"; commit_all
t "bestanden buiten de scope" 0 - coverage --base main; silent "bestanden buiten de scope geven geen uitvoer"
fresh; printf '# nieuw\n' >> "$fx/package.sh"; commit_all
t "pakketbestand met ongewijzigde pagina" 0 "WARNING: package.sh: gedekt door AIdocs/sub/beta.md" coverage --base main
fresh; printf '# nieuw\n' >> "$fx/package.sh"; printf '\nMeer.\n' >> "$fx/AIdocs/sub/beta.md"; commit_all
t "pakketbestand met meegewijzigde pagina" 0 - coverage --base main; silent "pakketbestand met meegewijzigde pagina geeft geen uitvoer"
fresh; printf '# nieuw\n' >> "$fx/package_script.php"; commit_all
t "pakketbestand dat niemand dekt" 1 "package_script.php: geen AIdocs-pagina" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/ab/g.php"; commit_all
t "Covers met slash dekt een mapnaam met dezelfde beginletters niet" 1 "Src/ext/ab/g.php" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/a/deep/g.php"; commit_all
t "Covers met slash dekt onderliggende mappen" 0 "WARNING: Src/ext/a/deep/g.php" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/b/z.php.bak"; commit_all
t "Covers zonder slash dekt precies één bestand" 1 "Src/ext/b/z.php.bak" coverage --base main
fresh; printf 'x' > "$fx/123"; commit_all
t "numeriek bestand in de root valt buiten de scope" 0 - coverage --base main; silent "numeriek bestand in de root geeft geen uitvoer"
fresh; printf 'x' > "$fx/123"
t "niet gevolgd numeriek bestand in de root valt buiten de scope" 0 - coverage --base main; nophpwarn "niet gevolgd numeriek bestand geeft geen PHP-melding"
fresh; git_quiet "$fx" checkout -q main; printf '// main loopt door\n' >> "$fx/Src/ext/c/old.php"; commit_all; git_quiet "$fx" checkout -q topic
t "wijzigingen op de basisbranch na het aftakken tellen niet mee" 0 - coverage --base main; silent "wijzigingen op de basisbranch geven geen uitvoer"

fresh; git_quiet "$fx" mv Src/ext/a/x.php Src/ext/a/y.php; commit_all
t "verplaatst gedekt bestand, pagina ongewijzigd" 0 "WARNING: Src/ext/a/y.php" coverage --base main
fresh; git_quiet "$fx" mv Src/ext/a/x.php Src/ext/c/x.php; commit_all
t "bestand verplaatst naar een ongedekte map" 1 "ERROR: Src/ext/c/x.php" coverage --base main

# Namen met een spatie of een niet-ASCII teken, en twee pagina's die hetzelfde bestand dekken.
fresh; printf 'x' > "$fx/Src/ext/a/mijn bestand.php"; commit_all
t "gedekt bestand met een spatie in de naam" 0 "WARNING: Src/ext/a/mijn bestand.php: gedekt door" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/c/mijn bestand.php"; commit_all
t "ongedekt bestand met een spatie in de naam" 1 "ERROR: Src/ext/c/mijn bestand.php: geen AIdocs-pagina" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/c/één-bestand.php"; commit_all
t "ongedekt bestand met een niet-ASCII teken in de naam" 1 "ERROR: Src/ext/c/één-bestand.php: geen AIdocs-pagina" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/c/één bestand.php"
t "niet gevolgd bestand met spatie en niet-ASCII teken" 1 "ERROR: Src/ext/c/één bestand.php: geen AIdocs-pagina" coverage --base main
fresh; printf 'x' > "$fx/Src/ext/c/één bestand.php"; sub AIdocs/alpha.md 's#^(- Src/ext/b/z.php)$#$1\n- Src/ext/c/één bestand.php#'; printf '\nMeer.\n' >> "$fx/AIdocs/alpha.md"; commit_all
t "Covers-pad met spatie en niet-ASCII teken dekt het bestand" 0 - coverage --base main; silent "Covers-pad met spatie en niet-ASCII teken geeft geen uitvoer"
fresh; write_page "$fx/AIdocs/gamma.md" Gamma "$first" Src/ext/a/x.php; commit_all; git_quiet "$fx" branch basis2
printf '// meer\n' >> "$fx/Src/ext/a/x.php"; commit_all
t "twee pagina's dekken één bestand, geen van beide gewijzigd" 0 "WARNING: Src/ext/a/x.php: gedekt door AIdocs/alpha.md, AIdocs/gamma.md, maar" coverage --base basis2
fresh; write_page "$fx/AIdocs/gamma.md" Gamma "$first" Src/ext/a/x.php; commit_all; git_quiet "$fx" branch basis2
printf '// meer\n' >> "$fx/Src/ext/a/x.php"; printf '\nMeer.\n' >> "$fx/AIdocs/gamma.md"; commit_all
t "twee pagina's dekken één bestand, één van beide gewijzigd" 0 - coverage --base basis2; silent "twee pagina's, één gewijzigd: geen waarschuwing"
fresh; write_page "$fx/AIdocs/gamma.md" Gamma "$first" Src/ext/a/x.php; commit_all; git_quiet "$fx" branch basis2
printf '// meer\n' >> "$fx/Src/ext/a/x.php"; printf '\nMeer.\n' >> "$fx/AIdocs/alpha.md"; commit_all
t "twee pagina's dekken één bestand, de andere pagina gewijzigd" 0 - coverage --base basis2; silent "twee pagina's, de andere gewijzigd: geen waarschuwing"

echo "== basisbranch"
fresh; t "develop gaat voor main (develop staat vóór alle pagina's)" 1 "Src/ext/c/old.php" coverage
fresh; t "--base main" 0 - coverage --base main
fresh; git_quiet "$fx" update-ref refs/remotes/origin/develop main; t "origin/develop gaat voor develop" 0 - coverage
fresh; git_quiet "$fx" branch -D develop; t "zonder develop valt terug op main" 0 - coverage
fresh; git_quiet "$fx" branch -D develop main; t "zonder basisbranch: overgeslagen met waarschuwing" 0 "WARNING: geen basisbranch" coverage
fresh; t "--base met onbekende ref" 1 "basis 'nope' bestaat niet" coverage --base nope
fresh; lone="$(git -C "$fx" commit-tree "$(git -C "$fx" hash-object -t tree /dev/null)" -m los)"; git_quiet "$fx" update-ref refs/heads/lone "$lone"
t "basis zonder gedeelde historie: overgeslagen met waarschuwing" 0 "WARNING: geen merge-base tussen HEAD en lone" coverage --base lone; nophpwarn "basis zonder gedeelde historie geeft geen PHP-melding"
fresh; t "--base zonder waarde" 2 "Gebruik" coverage --base
fresh; t "onbekend argument bij coverage" 2 "Gebruik" coverage --nope

echo "== aanroep"
fresh; t "geen modus" 2 "Gebruik"
fresh; t "onbekende modus" 2 "Gebruik" nope
mkdir -p "$tmp/nogit"; ( cd "$tmp/nogit" && php "$tpl/bin/check-aidocs.php" structure ) > "$tmp/out.txt" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'Geen git-repo' "$tmp/out.txt"; then report "buiten een git-repo" ""; else report "buiten een git-repo" "exit $rc"; fi
fresh; ( cd "$fx/Src/ext" && php ../../bin/check-aidocs.php structure ) > "$tmp/out.txt" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then report "vanuit een submap" ""; else report "vanuit een submap" "exit $rc"; fi

[ "$failed" -eq 0 ] && echo "Alle controles geslaagd." || exit 1
