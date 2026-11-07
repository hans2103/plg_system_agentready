#!/bin/bash
# Test voor bin/setup-dev-links.sh met een wegwerp-Joomla en omgeleide HOME. Gebruik: bash tests/shell/test_setup_dev_links.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

[ "${#DEV_LINKS[@]}" -gt 0 ] || { echo "DEV_LINKS is leeg; niets te testen."; exit 0; }

joomla="$tmp/joomla"; mkdir -p "$joomla" "$tmp/home"; echo '<?php' > "$joomla/configuration.php"
envvar="${ENV_PREFIX}_JOOMLA_DIR"
export HOME="$tmp/home" "$envvar=$joomla"
dl() { ( cd "$repo" && printf 'ja\n' | bash bin/setup-dev-links.sh "$@" ); }

run dl; same "eerste run geeft exit 0" 0 "$rc"
all_ok=1
for pair in "${DEV_LINKS[@]}"; do
  dest="$joomla/${pair%%|*}"
  [ -L "$dest" ] && [ "$(readlink "$dest")" = "$repo/${pair##*|}" ] || { all_ok=0; echo "      ${pair%%|*} wijst niet naar de repo"; }
done
[ "$all_ok" -eq 1 ] && pass "elke link in DEV_LINKS wijst naar de bron in de repo" || bad "een link ontbreekt of wijst verkeerd"
[ ! -d "$HOME/Development" ] && pass "geen back-up nodig bij een schone Joomla" || bad "er is onnodig een back-up gemaakt"

run dl; same "tweede run (idempotent)" 0 "$rc"

# Een bestaande echte map wordt geback-upt en vervangen
first="${DEV_LINKS[0]%%|*}"
rm "$joomla/$first"; mkdir -p "$joomla/$first"; echo oud > "$joomla/$first/oud.txt"
run dl; same "echte map wordt vervangen" 0 "$rc"
[ -L "$joomla/$first" ] && pass "  door een symlink" || bad "  nog geen symlink"
find "$HOME/Development" -name oud.txt 2>/dev/null | grep -q . && pass "  na een back-up" || bad "  zonder back-up"

# Een ontbrekende bronmap: er wordt niets aangepast
sed "s#^DEV_LINKS=(#DEV_LINKS=(\n\"x/y|Src/bestaat/niet\"#" "$repo/scripts.conf" > "$tmp/conf.bak"
copy_repo "$tmp/copy"; cp "$tmp/conf.bak" "$tmp/copy/scripts.conf"
run bash -c "cd '$tmp/copy' && printf 'ja\n' | bash bin/setup-dev-links.sh"
same "ontbrekende bronmap geeft exit 1" 1 "$rc"; has "  benoemt de map" 'Src/bestaat/niet'

# Nee bij de bevestiging
run bash -c "cd '$repo' && printf 'nee\n' | bash bin/setup-dev-links.sh"; same "'nee' breekt af" 1 "$rc"

# Ongeldig Joomla-pad
run env "$envvar=$tmp/leeg" bash -c "cd '$repo' && bash bin/setup-dev-links.sh"; same "ongeldig Joomla-pad" 1 "$rc"

finish
