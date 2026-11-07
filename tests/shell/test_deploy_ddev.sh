#!/bin/bash
# Test voor bin/deploy-ddev.sh met een wegwerp-Joomla en omgeleide HOME. Gebruik: bash tests/shell/test_deploy_ddev.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[ "${#DEV_LINKS[@]}" -gt 0 ] || { echo "DEV_LINKS is leeg; niets te testen."; exit 0; }
command -v rsync >/dev/null || { echo "rsync ontbreekt; test overgeslagen."; exit 0; }

joomla="$tmp/joomla"; mkdir -p "$joomla" "$tmp/home"; echo '<?php' > "$joomla/configuration.php"
envvar="${ENV_PREFIX}_JOOMLA_DIR"
export HOME="$tmp/home" "$envvar=$joomla"
dd() { ( cd "$repo" && printf 'ja\n' | bash bin/deploy-ddev.sh "$@" ); }

first="${DEV_LINKS[0]%%|*}"
firstSrc="${DEV_LINKS[0]##*|}"

# Dry run: schrijft niets
run dd --dry-run; same "dry run geeft exit 0" 0 "$rc"
[ ! -e "$joomla/$first" ] && pass "  dry run schrijft niets" || bad "  dry run heeft $first aangemaakt"

# Echte run: elke map staat er als echte map (geen symlink) met dezelfde bestanden
run dd; same "eerste run geeft exit 0" 0 "$rc"
all_ok=1
for pair in "${DEV_LINKS[@]}"; do
  dest="$joomla/${pair%%|*}" src="$repo/${pair##*|}"
  if [ -L "$dest" ] || [ ! -d "$dest" ]; then all_ok=0; echo "      ${pair%%|*} is geen echte map"; continue; fi
  diff -rq -x CLAUDE.md -x .DS_Store "$src" "$dest" >/dev/null || { all_ok=0; echo "      ${pair%%|*} wijkt af van de bron"; }
done
[ "$all_ok" -eq 1 ] && pass "elke map uit DEV_LINKS is een echte kopie van de bron" || bad "een map ontbreekt, is een symlink of wijkt af"

# .deployignore: CLAUDE.md-verwijzingen gaan niet mee
if find "$repo/$SRC_DIR" -name CLAUDE.md | grep -q .; then
  find "$joomla" -name CLAUDE.md | grep -q . && bad "CLAUDE.md is meegekopieerd" || pass "CLAUDE.md wordt uitgesloten (.deployignore)"
fi

# --delete: een bestand dat niet in de bron staat verdwijnt; tweede run is idempotent
echo oud > "$joomla/$first/verouderd.txt"
run dd; same "tweede run geeft exit 0" 0 "$rc"
[ ! -e "$joomla/$first/verouderd.txt" ] && pass "  verouderd bestand is verwijderd" || bad "  verouderd bestand staat er nog"
diff -rq -x CLAUDE.md -x .DS_Store "$repo/$firstSrc" "$joomla/$first" >/dev/null && pass "  $first nog gelijk aan de bron" || bad "  $first wijkt af na tweede run"

# Nee bij de bevestiging: niets gewijzigd
echo oud > "$joomla/$first/verouderd.txt"
run bash -c "cd '$repo' && printf 'nee\n' | bash bin/deploy-ddev.sh"; same "'nee' breekt af zonder fout" 0 "$rc"
[ -e "$joomla/$first/verouderd.txt" ] && pass "  en schrijft niets" || bad "  heeft toch gesynct"
has "  meldt het afbreken" 'Afgebroken'

# --yes: geen bevestigingsvraag, dus ook zonder invoer (zoals vanuit pnpm start)
run bash -c "cd '$repo' && bash bin/deploy-ddev.sh --yes < /dev/null"; same "--yes zonder invoer geeft exit 0" 0 "$rc"
[ ! -e "$joomla/$first/verouderd.txt" ] && pass "  en synct" || bad "  heeft niet gesynct"
hasnt "  stelt geen vraag" 'ja/nee'
echo oud > "$joomla/$first/verouderd.txt"
run bash -c "cd '$repo' && bash bin/deploy-ddev.sh -y -n < /dev/null"; same "-y -n samen geeft exit 0" 0 "$rc"
[ -e "$joomla/$first/verouderd.txt" ] && pass "  dry run wint: schrijft niets" || bad "  -y -n heeft toch gesynct"

# Een ontbrekende bronmap: overgeslagen, exit 1, de rest wordt wel gesynct
sed "s#^DEV_LINKS=(#DEV_LINKS=(\n\"x/y|Src/bestaat/niet\"#" "$repo/scripts.conf" > "$tmp/conf.bak"
copy_repo "$tmp/copy"; cp "$tmp/conf.bak" "$tmp/copy/scripts.conf"
run bash -c "cd '$tmp/copy' && printf 'ja\n' | bash bin/deploy-ddev.sh"
same "ontbrekende bronmap geeft exit 1" 1 "$rc"; has "  benoemt de map" 'Src/bestaat/niet'
[ ! -e "$joomla/$first/verouderd.txt" ] && pass "  de overige mappen zijn wel gesynct" || bad "  de overige mappen zijn niet gesynct"

# Onbekende optie en ongeldig Joomla-pad
run bash -c "cd '$repo' && bash bin/deploy-ddev.sh --onbekend"; same "onbekende optie" 2 "$rc"
run env "$envvar=$tmp/leeg" bash -c "cd '$repo' && bash bin/deploy-ddev.sh < /dev/null"; same "ongeldig Joomla-pad" 1 "$rc"

finish
