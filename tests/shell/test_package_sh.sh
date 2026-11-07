#!/bin/bash
# Tests voor package.sh van pkg_agentready: bouwt in een kopie van de repo (de werkmap blijft
# ongemoeid) en controleert de zip, het stempelen en __DEPLOY_VERSION__.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

copy="$tmp/repo"
mkdir -p "$copy"
( cd "$repo" && git ls-files -z --cached --others --exclude-standard | xargs -0 -I{} rsync -R {} "$copy/" )
cd "$copy" || exit 1

version=$(grep -m1 '<version>' package.xml | sed -E 's#.*<version>([^<]+)</version>.*#\1#')

expect "build zonder versie" 0 bash package.sh
zip="packages/${version}/pkg_agentready-${version}.zip"
[ -f "$zip" ] && pass "pakket-zip bestaat" || bad "pakket-zip ontbreekt: $zip"
list=$(unzip -Z1 "$zip")
for entry in pkg_agentready.xml package_script.php plg_system_agentready.zip language/en-GB/pkg_agentready.sys.ini language/nl-NL/pkg_agentready.sys.ini; do
  echo "$list" | grep -qx "$entry" && pass "  in het pakket: $entry" || bad "  ontbreekt in het pakket: $entry"
done
unzip -p "$zip" plg_system_agentready.zip > "$tmp/plg.zip"
plg=$(unzip -Z1 "$tmp/plg.zip")
for entry in agentready.xml services/provider.php src/Extension/AgentReady.php vendor/autoload.php vendor/league/html-to-markdown/LICENSE composer.lock; do
  echo "$plg" | grep -qx "$entry" && pass "  in de plugin: $entry" || bad "  ontbreekt in de plugin: $entry"
done
echo "$plg" | grep -q 'CLAUDE.md' && bad "  CLAUDE.md in de plugin-zip" || pass "  geen CLAUDE.md in de plugin-zip"
same "zonder versie niets gestempeld" "" "$(git -C "$repo" status --porcelain -- package.xml)"

expect "build met versie" 0 bash package.sh 99.1.0
same "package.xml gestempeld" "1" "$(grep -c '<version>99.1.0</version>' package.xml)"
same "plugin-manifest gestempeld" "1" "$(grep -c '<version>99.1.0</version>' Src/plugins/system/agentready/agentready.xml)"
grep -rq '__DEPLOY_VERSION__' Src package_script.php && bad "__DEPLOY_VERSION__ niet vervangen" || pass "__DEPLOY_VERSION__ vervangen"
[ -f packages/99.1.0/pkg_agentready-99.1.0.zip ] && pass "zip met de nieuwe versie" || bad "zip met de nieuwe versie ontbreekt"

expect "ongeldige versie geweigerd" 1 bash package.sh 1.2
rm -rf Src/plugins/system/agentready/vendor
expect "zonder vendor/ geweigerd" 1 bash package.sh

exit "$failed"
