#!/bin/bash
#
# bin/run-act.sh — simuleert .github/workflows/release.yml lokaal met `act`, zonder een
# echte release aan te maken of iets naar GitHub te pushen (die stappen worden overgeslagen
# via `if: !env.LOCAL_ACT`; dit script zet LOCAL_ACT=1 altijd expliciet, ook als het in
# .actrc ontbreekt).
#
# Vraagt interactief om de versie (default: die in package.xml), schrijft een tijdelijk
# act-event.json (gitignored) dat een push van tag v{versie} nabootst en draait act.
#
# Vereist: act (brew install act) en .actrc (kopieer .actrc.sample, als die er is)
#
# Gebruik:
#   bash bin/run-act.sh            — vraagt om de versie
#   bash bin/run-act.sh 26.38.0    — direct voor een bepaalde versie
#
# BASH 3.2-COMPATIBEL (macOS).
set -eo pipefail

case "${1:-}" in
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$REPO_DIR"

command -v act >/dev/null || die "act niet gevonden (brew install act).${RELEASE_DOC:+ Zie '${RELEASE_DOC}'.}"
[ -f .github/workflows/release.yml ] || die ".github/workflows/release.yml niet gevonden."

if [ ! -f .actrc ]; then
    if [ -f .actrc.sample ]; then
        notice "Waarschuwing: .actrc ontbreekt. Kopieer .actrc.sample naar .actrc (evt. --container-architecture aanpassen)."
    else
        notice "Waarschuwing: .actrc ontbreekt; act gebruikt zijn standaardimages."
    fi
fi

# Externe actions (alles behalve actions/checkout, dat act zelf afhandelt) clonet act met de
# dummy-token onderaan dit script, en GitHub weigert die: de run stopt dan met "authentication
# required". Ze moeten dus eenmalig in act's cache staan, en act mag ze niet opnieuw ophalen
# (--action-offline-mode in .actrc). Dit meldt wat er ontbreekt; het stopt niets.
actCache="${XDG_CACHE_HOME:-$HOME/.cache}/act"
externalActions=$(grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' .github/workflows/release.yml \
    | sed -E 's/.*uses:[[:space:]]*//; s/[[:space:]]*#.*$//' | tr -d "\"'" \
    | grep -vE '^(\./|docker://|actions/checkout@)' | sort -u || true)
actionHints=""
while IFS= read -r action; do
    [ -n "$action" ] || continue
    [ -d "${actCache}/${action/\//-}" ] || actionHints="${actionHints}
    git clone --depth 1 -b ${action##*@} https://github.com/${action%%@*} \"${actCache}/${action/\//-}\""
done <<< "$externalActions"
offlineMissing=0
if [ -n "$externalActions" ] && ! grep -qs -- '--action-offline-mode' .actrc; then offlineMissing=1; fi
if [ -n "$actionHints" ] || [ "$offlineMissing" -eq 1 ]; then
    notice "Waarschuwing: de workflow gebruikt externe actions ($(printf '%s' "$externalActions" | tr '\n' ' ' | sed 's/ *$//')); act kan die met de dummy-token niet zelf ophalen."
    [ -z "$actionHints" ] || printf '  Zet ze eenmalig in act'"'"'s cache:%s\n' "$actionHints"
    [ "$offlineMissing" -eq 0 ] || echo "  Voeg '--action-offline-mode' toe aan .actrc, zodat act ze niet opnieuw probeert op te halen."
fi

packageVersion=$(manifest_version package.xml)

version="${1:-}"
if [ -z "$version" ]; then
    read -rp "Versienummer om te testen [${packageVersion}]: " version
    version="${version:-$packageVersion}"
fi

if [ "$version" != "$packageVersion" ]; then
    echo "Waarschuwing: opgegeven versie (${version}) komt niet overeen met package.xml (${packageVersion})."
    echo "De workflow-stap 'Verify version matches package.xml' zal falen."
fi

eventFile="act-event.json"
trap 'rm -f "$eventFile"' EXIT

cat > "$eventFile" <<JSON
{
  "ref": "refs/tags/v${version}",
  "ref_type": "tag",
  "repository": {
    "full_name": "${GITHUB_REPO}",
    "name": "${GITHUB_REPO##*/}",
    "owner": { "login": "${GITHUB_REPO%%/*}" }
  }
}
JSON

echo "Event-bestand geschreven: ${eventFile} (tag v${version})"
echo "Workflow starten met act..."
echo

act push \
    -W .github/workflows/release.yml \
    -e "$eventFile" \
    --env LOCAL_ACT=1 \
    -s GITHUB_TOKEN=dummy-token-lokaal
