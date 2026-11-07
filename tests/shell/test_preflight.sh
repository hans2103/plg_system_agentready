#!/bin/bash
# Test voor bin/preflight.sh op een wegwerpkopie van de repo. Gebruik: bash tests/shell/test_preflight.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

pf() { bash "$tmp/copy/bin/preflight.sh" "$@"; }
# Begrensd met alarm: een lus die niet stopt geeft exit 142 en dus FAIL in plaats van een vastgelopen suite.
bounded() { perl -e 'alarm 20; exec @ARGV' "$@"; }

copy_repo "$tmp/copy"
mig="$tmp/copy/sql/migrations"
mkdir -p "$mig"
# Controles 1-4 en 6-11 zijn onafhankelijk van AIdocs en de hook (5, 12-14 hebben eigen tests).
BASE="1,2,3,4,6,7,8,9,10,11"

# ── Positief ──
expect "schone kopie" 0 bounded bash "$tmp/copy/bin/preflight.sh" --only "$BASE"
has "schone kopie: geen ERROR" '0 error\(s\)'

# ── Controle 2: SQL-migraties ──
good_name="99_20260101_120000_test_migratie.sql"
printf -- '-- Issue: #99\n-- Auteur: Test\n-- Omschrijving: test\n\nCREATE TABLE IF NOT EXISTS `#__%s_test` (id INT);\n' "$PROJECT_NAME" > "$mig/$good_name"
expect "geldige migratie" 0 pf --only 2
has "geldige migratie telt mee" '1 bestand\(en\) in orde'
rm -f "$mig/$good_name"

printf 'SELECT 1;\n' > "$mig/foutieve-naam.sql"
expect "migratie met foute naam" 1 pf --only 2
rm -f "$mig/foutieve-naam.sql"

printf -- '-- Auteur: T\n\nSELECT `#__%s_x`;\n' "$PROJECT_NAME" > "$mig/99_20260101_120000_zonder_issue.sql"
expect "migratie zonder Issue-header" 1 pf --only 2
has "  meldt de ontbrekende header" 'Issue: #123'
rm -f "$mig/99_20260101_120000_zonder_issue.sql"

printf -- '-- Issue: #99\n-- Auteur: T\n-- Omschrijving: t\n\nSELECT 1;\n' > "$mig/99_20260101_120000_zonder_prefix.sql"
expect "migratie zonder #__-prefix" 1 pf --only 2
rm -f "$mig/99_20260101_120000_zonder_prefix.sql"

printf -- '-- Issue: #99\n-- Auteur: T\n-- Omschrijving: t\n\nSELECT * FROM `jos_%s_x`;\n' "$PROJECT_NAME" > "$mig/99_20260101_120000_echte_prefix.sql"
expect "migratie met de echte tabelprefix" 1 pf --only 2
rm -f "$mig/99_20260101_120000_echte_prefix.sql"

printf -- '-- Issue: #99\n-- Auteur: T\n-- Omschrijving: t\n\nCREATE TABLE `#__%s_x` (id INT);\n' "$PROJECT_NAME" > "$mig/99_20260101_120000_niet_idempotent.sql"
expect "niet-idempotente migratie is alleen een WARNING" 0 pf --only 2
has "  met melding" 'niet idempotent'
rm -f "$mig/99_20260101_120000_niet_idempotent.sql"

# ── Controle 3: manifests ──
first_manifest="${EXTENSION_MANIFESTS[0]}"
touch "$tmp/copy/$(dirname "$first_manifest")/verdwaald.txt"
expect "bestand op schijf dat het manifest niet noemt" 1 pf --only 3
has "  benoemt het bestand" 'verdwaald.txt'
reset_copy "$tmp/copy"

printf '<broken' >> "$tmp/copy/package.xml"
expect "ongeldige XML" 1 pf --only 3
reset_copy "$tmp/copy"

# ── Controle 4: versies ──
sed -i.bak 's#<version>[^<]*</version>#<version>1.2.3</version>#' "$tmp/copy/${VERSIONED_MANIFESTS[0]}"; rm -f "$tmp/copy/${VERSIONED_MANIFESTS[0]}.bak"
expect "afwijkende manifest-versie" 1 pf --only 4
has "  benoemt het manifest" "${VERSIONED_MANIFESTS[0]}"
reset_copy "$tmp/copy"
if [ "${#VERSIONED_JSON[@]}" -gt 0 ]; then
  sed -i.bak -E 's#("version": *")[^"]*#\19.9.9#' "$tmp/copy/${VERSIONED_JSON[0]}"; rm -f "$tmp/copy/${VERSIONED_JSON[0]}.bak"
  expect "afwijkende JSON-versie" 1 pf --only 4
  reset_copy "$tmp/copy"
fi

# ── Hygiëne (6, 9, 10, 11): alleen de changeset, tenzij --all ──
printf '<?php\nvar_dump($x);\n' > "$tmp/copy/Src/debug.php"
expect "debug-rest is een WARNING, geen ERROR" 0 pf --only 6
has "  gemeld" 'WARNING +6\.'
rm -f "$tmp/copy/Src/debug.php"

printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> topic\n' > "$tmp/copy/conflict.txt"
expect "merge-conflictmarkers" 1 pf --only 9
rm -f "$tmp/copy/conflict.txt"

printf 'pad: /Use''rs/iemand/project\n' > "$tmp/copy/pad.txt"
expect "home-pad" 0 pf --only 10
has "  gemeld" 'WARNING +10\.'
rm -f "$tmp/copy/pad.txt"

printf 'wachtwoord: %s = "geheim-genoeg-1234"\n' password > "$tmp/copy/geheim.txt"   # (niet als letterlijke toekenning, anders meldt preflight dit testbestand zelf)
run pf --only 11; has "geheim gemeld" 'WARNING +11\.'
rm -f "$tmp/copy/geheim.txt"

# SCAN_EXCLUDE: een uitgesloten pad wordt niet gescand
if [ "${#SCAN_EXCLUDE[@]}" -gt 0 ]; then
  ex="${SCAN_EXCLUDE[0]}"
  case "$ex" in */) mkdir -p "$tmp/copy/$ex"; ex_file="${ex}x.md" ;; *) ex_file="$ex" ;; esac
  printf 'pad: /Use''rs/iemand/project\n' > "$tmp/copy/$ex_file"
  run pf --only 10; hasnt "SCAN_EXCLUDE ($ex) wordt overgeslagen" 'WARNING +10\.'
  reset_copy "$tmp/copy"
fi

# Een volledig nieuwe map (git status toont hem als één regel) wordt toch per bestand gescand
mkdir -p "$tmp/copy/Src/nieuwemap/diep"; printf '<?php\nvar_dump($x);\n' > "$tmp/copy/Src/nieuwemap/diep/x.php"
run pf --only 6; has "bestand in een nieuwe map wordt gescand" 'nieuwemap/diep/x\.php'
rm -rf "$tmp/copy/Src/nieuwemap"

# --all ziet ook wat al gecommit is; de changeset niet (er is geen develop om mee te vergelijken)
printf '<?php\nvar_dump($x);\n' > "$tmp/copy/Src/gecommit.php"
( cd "$tmp/copy" && git add -A && git commit -q -m debug )
run pf --only 6; hasnt "changeset: gecommit bestand valt buiten de scope" 'WARNING +6\.'
run pf --only 6 --all; has "--all: gecommit bestand wordt wel gescand" 'WARNING +6\.'
( cd "$tmp/copy" && git reset -q --hard HEAD~1 )

# ── Controle 15: strict_types in PHP-klassebestanden (WARNING, changeset tenzij --all) ──
expect "strict_types: schone changeset" 0 pf --only 15
has "  n.v.t. zonder PHP-bestand" 'OK +15\. .*n\.v\.t\.'
mkdir -p "$tmp/copy/Src/sttest/src" "$tmp/copy/Src/sttest/tmpl" "$tmp/copy/Src/sttest/layouts" "$tmp/copy/Src/sttest/html/x" "$tmp/copy/Src/templates/sttpl"
printf '<?php\nnamespace X;\nclass Zonder {}\n' > "$tmp/copy/Src/sttest/src/Zonder.php"
expect "strict_types: ontbrekend is een WARNING, geen ERROR" 0 pf --only 15
has "  gemeld met het bestand" 'Src/sttest/src/Zonder\.php'
has "  als WARNING" 'WARNING +15\. strict_types — 1 PHP-bestand'
printf '<?php\n\ndeclare(strict_types=1);\n\nnamespace X;\nclass Met {}\n' > "$tmp/copy/Src/sttest/src/Met.php"
printf '<?php\ndeclare( strict_types = 1 );\n' > "$tmp/copy/Src/sttest/src/Spaties.php"
rm -f "$tmp/copy/Src/sttest/src/Zonder.php"
expect "strict_types: aanwezig (ook met spaties)" 0 pf --only 15
has "  OK met aantal" 'OK +15\. strict_types — 2 PHP-bestand'
for f in tmpl/default.php layouts/tile.php html/x/default.php; do printf '<?php defined("_JEXEC") or die; ?>\n<p>x</p>\n' > "$tmp/copy/Src/sttest/$f"; done
printf '<?php defined("_JEXEC") or die; ?>\n<html></html>\n' > "$tmp/copy/Src/templates/sttpl/index.php"
printf '<p>geen php-tag</p>\n' > "$tmp/copy/Src/sttest/src/Markup.php"
run pf --only 15; hasnt "strict_types: view-templates, template-entry en bestanden zonder <?php overgeslagen" 'WARNING +15\.'
reset_copy "$tmp/copy"
mkdir -p "$tmp/copy/Src/sttest/src"; printf '<?php\nclass Zonder {}\n' > "$tmp/copy/Src/sttest/src/Zonder.php"
printf 'STRICT_TYPES_EXCLUDE=("Src/sttest/")\n' >> "$tmp/copy/scripts.conf"
run pf --only 15; hasnt "strict_types: STRICT_TYPES_EXCLUDE wordt overgeslagen" 'WARNING +15\.'
reset_copy "$tmp/copy"
mkdir -p "$tmp/copy/Src/sttest/src"; printf '<?php\nclass Zonder {}\n' > "$tmp/copy/Src/sttest/src/Zonder.php"
( cd "$tmp/copy" && git add -A && git commit -q -m zonder )
run pf --only 15; hasnt "strict_types: gecommit bestand valt buiten de changeset" 'WARNING +15\.'
run pf --only 15 --all; has "strict_types: --all scant de hele repo" 'Src/sttest/src/Zonder\.php'
( cd "$tmp/copy" && git reset -q --hard HEAD~1 )

# ── Controle 7: lengtegrenzen (CLAUDE.md, CLAUDE.md-verwijzingen onder Src/, AIdocs-pagina's) ──
printf 'LENGTH_LIMIT_SEVERITY="ERROR"\n' >> "$tmp/copy/scripts.conf"
expect "lengtegrenzen: kopie binnen de grens" 0 pf --only 7
has "  meldt de controle" 'OK +7\. Lengtegrenzen'
rm "$tmp/copy/CLAUDE.md"
expect "lengtegrenzen: ontbrekend CLAUDE.md" 0 pf --only 7
has "  benoemt het probleem" 'WARNING +7\. Lengtegrenzen — CLAUDE.md niet gevonden'
hasnt "  geen OK-regel erbij" 'OK +7\.'
reset_copy "$tmp/copy"
printf 'LENGTH_LIMIT_SEVERITY="ERROR"\n' >> "$tmp/copy/scripts.conf"
mkdir -p "$tmp/copy/$SRC_DIR/lengtetest" "$tmp/copy/AIdocs"
for target in "CLAUDE.md" "$SRC_DIR/lengtetest/CLAUDE.md" "AIdocs/lengtetest.md"; do
  yes x | head -n 200 > "$tmp/copy/$target"
  expect "lengtegrenzen: 200 regels in $target" 0 pf --only 7
  echo x >> "$tmp/copy/$target"
  expect "lengtegrenzen: 201 regels in $target is een ERROR" 1 pf --only 7
  has "  benoemt het bestand" "ERROR +7\. Lengtegrenzen — $target is 201 regels"
  rm -f "$tmp/copy/$SRC_DIR/lengtetest/CLAUDE.md" "$tmp/copy/AIdocs/lengtetest.md"; ( cd "$tmp/copy" && git checkout -q -- CLAUDE.md )
done
mkdir -p "$tmp/copy/$SRC_DIR/lengtetest/vendor/x"
yes x | head -n 201 > "$tmp/copy/$SRC_DIR/lengtetest/vendor/x/CLAUDE.md"
expect "lengtegrenzen: CLAUDE.md in vendor/ telt niet mee" 0 pf --only 7
reset_copy "$tmp/copy"
printf 'LENGTH_LIMIT_SEVERITY="WARNING"\n' >> "$tmp/copy/scripts.conf"
yes x | head -n 201 > "$tmp/copy/CLAUDE.md"
expect "lengtegrenzen: WARNING-modus geeft geen exit 1" 0 pf --only 7
has "  meldt het toch" 'WARNING +7\. Lengtegrenzen — CLAUDE.md is 201 regels'
reset_copy "$tmp/copy"
sed -i.bak '/^LENGTH_LIMIT_SEVERITY=/d' "$tmp/copy/scripts.conf"; rm -f "$tmp/copy/scripts.conf.bak"
yes x | head -n 201 > "$tmp/copy/CLAUDE.md"
expect "lengtegrenzen: zonder LENGTH_LIMIT_SEVERITY is het een WARNING" 0 pf --only 7
has "  meldt het toch" 'WARNING +7\. Lengtegrenzen'
reset_copy "$tmp/copy"; rm -rf "$tmp/copy/AIdocs"
expect "lengtegrenzen: repo zonder AIdocs-map" 0 pf --only 7
has "  meldt OK" 'OK +7\.'
hasnt "  geen find-fout" 'No such file'
reset_copy "$tmp/copy"
printf 'LENGTH_LIMIT_SEVERITY="ERROR"\n' >> "$tmp/copy/scripts.conf"
printf 'MODULE_GLOBS=()\nSCAN_IGNORE=()\n' > "$tmp/copy/ronny.conf"   # ronny.conf zonder AIDOCS_DIR
mkdir -p "$tmp/copy/AIdocs"; yes x | head -n 201 > "$tmp/copy/AIdocs/lengtetest.md"
expect "lengtegrenzen: ronny.conf zonder AIDOCS_DIR gebruikt AIdocs" 1 pf --only 7
has "  meldt de AIdocs-pagina" 'ERROR +7\. Lengtegrenzen — AIdocs/lengtetest\.md is 201 regels'
reset_copy "$tmp/copy"
printf 'LENGTH_LIMIT_SEVERITY="error"\n' >> "$tmp/copy/scripts.conf"
expect "lengtegrenzen: ongeldige zwaarte veroorzaakt exit 2" 2 pf --only 7
has "  meldt de fout" 'LENGTH_LIMIT_SEVERITY'
reset_copy "$tmp/copy"
printf 'LENGTH_LIMIT_SEVERITY="ERROR"\n' >> "$tmp/copy/scripts.conf"
mkdir -p "$tmp/copy/$SRC_DIR/lengtetest"
yes x | head -n 200 > "$tmp/copy/$SRC_DIR/lengtetest/CLAUDE.md"; printf x >> "$tmp/copy/$SRC_DIR/lengtetest/CLAUDE.md"
expect "lengtegrenzen: 201 regels zonder slotnewline" 1 pf --only 7
has "  telt het correct" "ERROR +7\. Lengtegrenzen — $SRC_DIR/lengtetest/CLAUDE.md is 201 regels"
reset_copy "$tmp/copy"

# ── Controles 12-14: horen bij een AIdocs-werkwijze (AIDOCS_FLAVOUR); elke repo toont dezelfde lijst 1-15 ──
reset_copy "$tmp/copy"
run pf
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do has "  volledige run toont een regel voor controle $n" "^(OK|WARNING|ERROR) +$n\. "; done
reset_copy "$tmp/copy"
printf 'AIDOCS_FLAVOUR=""\n' >> "$tmp/copy/scripts.conf"
expect "zonder AIDOCS_FLAVOUR zijn 12, 13 en 14 n.v.t." 0 pf --only 12,13,14
has "  12 is n.v.t." "OK +12\. .*n\.v\.t\. voor AIDOCS_FLAVOUR=''"
has "  13 is n.v.t." "OK +13\. .*n\.v\.t\. voor AIDOCS_FLAVOUR=''"
has "  14 is n.v.t." "OK +14\. .*n\.v\.t\. voor AIDOCS_FLAVOUR=''"
reset_copy "$tmp/copy"
printf 'AIDOCS_FLAVOUR="ronny"\n' >> "$tmp/copy/scripts.conf"
expect "flavour ronny: 14 is n.v.t." 0 pf --only 14
has "  14 noemt de flavour" "OK +14\. .*n\.v\.t\. voor AIDOCS_FLAVOUR='ronny' \(alleen bij structure\)"
reset_copy "$tmp/copy"
printf 'AIDOCS_FLAVOUR="structure"\n' >> "$tmp/copy/scripts.conf"
expect "flavour structure: 12 en 13 zijn n.v.t." 0 pf --only 12,13
has "  12 noemt de flavour" "OK +12\. .*n\.v\.t\. voor AIDOCS_FLAVOUR='structure' \(alleen bij ronny\)"
has "  13 noemt de flavour" "OK +13\. .*n\.v\.t\. voor AIDOCS_FLAVOUR='structure' \(alleen bij ronny\)"
run pf --only 12,13 --quiet
hasnt "  --quiet toont de n.v.t.-regels niet" 'n\.v\.t\.'
reset_copy "$tmp/copy"

# ── Controle 5: hook ──
run pf --only 5; has "hook niet gezet: WARNING" 'WARNING +5\.'
( cd "$tmp/copy" && git config core.hooksPath .githooks )
run pf --only 5; has "hook gezet: OK" 'OK +5\.'

# ── CLI ──
expect "--only beperkt de run" 0 bounded bash "$tmp/copy/bin/preflight.sh" --only 7
has "  alleen controle 7" 'OK +7\.'
hasnt "  niet controle 1" '1\. Lint'
expect "--only zonder waarde" 2 bounded bash "$tmp/copy/bin/preflight.sh" --only
expect "--only met ongeldige waarde" 2 bounded bash "$tmp/copy/bin/preflight.sh" --only abc
expect "onbekende optie" 2 pf --nope
expect "--help" 0 pf --help
has "  toont het gebruik" 'Gebruik:'
expect "--quiet toont geen OK-regels" 0 bounded bash "$tmp/copy/bin/preflight.sh" --only 7 --quiet
hasnt "  geen OK-regel" 'OK +7\.'

finish
