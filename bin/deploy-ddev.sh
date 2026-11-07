#!/bin/bash
#
# bin/deploy-ddev.sh — synct de Src/-mappen (DEV_LINKS in scripts.conf) naar een lokale
# Joomla-installatie: echte bestanden via rsync (--delete), nooit een symlink. Bedoeld voor
# installaties waar setup-dev-links.sh's symlinks niet werken (bijv. DDEV met mutagen-sync).
#
# Dezelfde mappen als setup-dev-links.sh (DEV_LINKS in scripts.conf) en dezelfde
# .deployignore-uitsluitingen als package.sh/preflight check 11.
#
# Joomla-pad: ${ENV_PREFIX}_JOOMLA_DIR, anders .dev-local (JOOMLA_DIR=...), anders
# JOOMLA_DIR_DEFAULT uit scripts.conf; ontbreekt het overal, dan wordt het gevraagd en
# opgeslagen (zie _common.sh, gedeeld met run-migrations.sh en setup-dev-links.sh).
#
# Gebruik: bash bin/deploy-ddev.sh [-n|--dry-run] [-y|--yes]
#   -n, --dry-run   toont wat er zou veranderen; schrijft niets
#   -y, --yes       geen bevestigingsvraag (voor watchers zoals pnpm start)
#
# BASH 3.2-COMPATIBEL (macOS).
set -eo pipefail

dryRun=0
assumeYes=0
for arg in "$@"; do
    case "${arg}" in
        -n|--dry-run) dryRun=1 ;;
        -y|--yes) assumeYes=1 ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Onbekende optie: ${arg} (zie --help)" >&2; exit 2 ;;
    esac
done

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

command -v rsync >/dev/null || die "rsync is vereist."
[ "${#DEV_LINKS[@]}" -gt 0 ] || die "DEV_LINKS is leeg in scripts.conf; er is niets om te deployen."
require_joomla_dir

# DDEV-projectmap: het Joomla-pad zelf of de map erboven (informatief; bestanden worden hoe dan
# ook rechtstreeks naar schijf gekopieerd, zie run-migrations.sh voor dezelfde detectie).
ddevProjectDir=""
if [ -f "${JOOMLA_DIR}/.ddev/config.yaml" ]; then
    ddevProjectDir="${JOOMLA_DIR}"
elif [ -f "$(dirname "${JOOMLA_DIR}")/.ddev/config.yaml" ]; then
    ddevProjectDir="$(dirname "${JOOMLA_DIR}")"
fi

# rsync-excludes uit .deployignore (gedeeld met package.sh): een voorloop-'*' die daar voor
# zip's shell-context ge-escaped is, neemt rsync letterlijk, dus wordt de escape hier gestript.
rsyncExcludes=()
if [ -f "${REPO_DIR}/.deployignore" ]; then
    while IFS= read -r pattern || [ -n "${pattern}" ]; do
        case "${pattern}" in ''|'#'*) continue ;; esac
        pattern="${pattern#\\}"
        rsyncExcludes+=("--exclude=${pattern}")
    done < "${REPO_DIR}/.deployignore"
fi

echo "${PROJECT_NAME} — Src/ deployen naar een lokale test-installatie"
echo "=================================================="
echo "Repo   : ${REPO_DIR}"
echo "Joomla : ${JOOMLA_DIR}"
if [ -n "${ddevProjectDir}" ]; then
    ddevName=$(grep '^name:' "${ddevProjectDir}/.ddev/config.yaml" 2>/dev/null | awk '{print $2}')
    echo "DDEV   : project '${ddevName:-onbekend}' (start het project zodat mutagen de wijziging oppikt)"
fi
echo "Items  : ${#DEV_LINKS[@]}"
[ "${dryRun}" -eq 1 ] && notice "Modus  : dry run — er wordt niets geschreven"
echo

if [ "${dryRun}" -eq 0 ] && [ "${assumeYes}" -eq 0 ]; then
    confirm "Src/ naar '${JOOMLA_DIR}' deployen?" || { echo "Afgebroken."; exit 0; }
    echo
fi

deploy_one() {
    local dest="$1" src="$2" srcPath="${REPO_DIR}/$2" destPath="${JOOMLA_DIR}/$1"

    if [ ! -d "${srcPath}" ]; then
        notice "  skip   ${dest} (bron ${src} niet gevonden)"
        return 1
    fi

    if [ "${dryRun}" -eq 1 ]; then
        echo "  ${dest}/:"
        rsync -a --delete "${rsyncExcludes[@]}" --dry-run -i "${srcPath}/" "${destPath}/" | sed 's/^/    /'
    else
        mkdir -p "$(dirname "${destPath}")"
        rsync -a --delete "${rsyncExcludes[@]}" "${srcPath}/" "${destPath}/"
        success "  synced ${dest}/"
    fi
}

failed=0
for pair in "${DEV_LINKS[@]}"; do
    deploy_one "${pair%%|*}" "${pair##*|}" || failed=$((failed + 1))
done

echo
if [ "${dryRun}" -eq 1 ]; then
    info "Dry run klaar — er is niets geschreven."
elif [ "${failed}" -gt 0 ]; then
    echo "${failed} item(en) overgeslagen (bron niet gevonden)." >&2
    exit 1
else
    success "Deploy klaar."
fi
