#!/bin/bash
#
# bin/setup-dev-links.sh — zet symlinks van een lokale Joomla-installatie naar deze repo
# (Src/-structuur), zodat je in de repo ontwikkelt en in Joomla test. Bestaande mappen worden
# eerst geback-upt.
#
# Joomla-pad: ${ENV_PREFIX}_JOOMLA_DIR, anders .dev-local (JOOMLA_DIR=...), anders
# JOOMLA_DIR_DEFAULT uit scripts.conf. Welke mappen gelinkt worden staat in DEV_LINKS (en de
# op te ruimen oude taalbestanden in STALE_LINKS) in scripts.conf.
#
# Opnieuw draaien is nodig na een verhuizing van de bronmappen: de oude links wijzen dan naar
# mappen die niet meer bestaan.
#
# Gebruik: bash bin/setup-dev-links.sh
#
# BASH 3.2-COMPATIBEL (macOS).
set -e

case "${1:-}" in
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[ "${#DEV_LINKS[@]}" -gt 0 ] || die "DEV_LINKS is leeg in scripts.conf; er is niets om te linken."
find_joomla_dir || die "geen Joomla-installatie gevonden (zet ${ENV_PREFIX}_JOOMLA_DIR, of JOOMLA_DIR= in .dev-local)."
[ -d "$JOOMLA_DIR" ] && [ -f "$JOOMLA_DIR/configuration.php" ] \
    || die "geen Joomla-installatie gevonden in ${JOOMLA_DIR} (zet ${ENV_PREFIX}_JOOMLA_DIR)."

# Alle bronnen vooraf controleren, vóór er iets geback-upt of verwijderd wordt: een ontbrekende
# latere bron mag nooit een deel van de links al vervangen hebben.
missing=""
for pair in "${DEV_LINKS[@]}"; do
    [ -d "${REPO_DIR}/${pair##*|}" ] || missing="${missing}
  - ${REPO_DIR}/${pair##*|}"
done
if [ -n "${missing}" ]; then
    die "bronmap(pen) ontbreken in de repo; er is niets aangepast:${missing}"
fi

success "${PROJECT_NAME} dev-links"
echo "Repo:   ${REPO_DIR}"
echo "Joomla: ${JOOMLA_DIR}"
echo
notice "Bestaande component-mappen worden geback-upt en vervangen door symlinks."
confirm "Doorgaan?" || { echo "Afgebroken."; exit 1; }

# De back-upmap wordt pas aangemaakt als er echt iets geback-upt moet worden.
BACKUP_DIR="$HOME/Development/${PROJECT_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_USED=0

backup_and_remove() {
    local target="$1"
    if [ -L "${target}" ]; then
        rm "${target}"
    elif [ -e "${target}" ]; then
        BACKUP_USED=1
        mkdir -p "${BACKUP_DIR}/$(dirname "${target#${JOOMLA_DIR}/}")"
        cp -R "${target}" "${BACKUP_DIR}/${target#${JOOMLA_DIR}/}"
        rm -rf "${target}"
    fi
}

for pair in "${DEV_LINKS[@]}"; do
    dest="${JOOMLA_DIR}/${pair%%|*}"
    src="${REPO_DIR}/${pair##*|}"
    backup_and_remove "${dest}"
    mkdir -p "$(dirname "${dest}")"
    ln -s "${src}" "${dest}"
    echo "  → ${pair%%|*}"
done

for rel in "${STALE_LINKS[@]}"; do
    backup_and_remove "${JOOMLA_DIR}/${rel}"
done

echo
if [ "${BACKUP_USED}" -eq 1 ]; then
    success "✓ Symlinks aangemaakt. Back-up: ${BACKUP_DIR}"
else
    success "✓ Symlinks aangemaakt. Geen back-up nodig."
fi
first="${DEV_LINKS[0]%%|*}"
echo "Controleer met: ls -la ${JOOMLA_DIR}/$(dirname "${first}")/ | grep ${PROJECT_NAME}"
