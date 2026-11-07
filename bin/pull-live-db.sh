#!/bin/bash
#
# bin/pull-live-db.sh — haalt een verse dump van de live-database op en importeert die in de
# lokale DDEV-site.
#
# Live: ssh naar LIVE_SSH_HOST, de databasegegevens komen uit LIVE_JOOMLA_DIR/configuration.php
# (beide in scripts.conf), dus er staan hier geen wachtwoorden. Staat daar geen
# configuration.php, dan zoekt het script er precies één tot twee mappen dieper (zoals
# htdocs/public_html). Lokaal: de DDEV-site van JOOMLA_DIR (zie _common.sh, gedeeld met
# deploy-ddev.sh); .ddev/ staat in die map of erboven.
#
# Dumps en back-ups komen in backup/ van de DDEV-projectmap, nooit in deze repo:
# live-<stempel>.sql.gz en local-before-import-<stempel>.sql.gz. Is die projectmap een
# git-repo, dan moet backup/ daar genegeerd worden (de dump bevat klantgegevens). Na de import
# verdwijnt administrator/cache/autoload_psr4.php, zodat Joomla zijn PSR-4-map opnieuw maakt.
#
# Dumps bevatten persoonsgegevens: backup/ en de dumps zijn alleen leesbaar voor de eigenaar
# (umask 077, chmod 600), en per soort blijven alleen de nieuwste --keep dumps staan.
#
# Gebruik: bash bin/pull-live-db.sh [--no-backup] [--keep=N] [--anonymize]
#   --no-backup   geen back-up van de huidige lokale database vóór de import
#   --keep=N      bewaar per soort (live-, local-before-import-) de nieuwste N dumps (standaard 3)
#   --anonymize   na de import e-mailadressen van Joomla-gebruikers vervangen door
#                 user<id>@example.invalid en ANONYMIZE_SQL uit scripts.conf draaien (#__ wordt
#                 het lokale tabelprefix)
#
# BASH 3.2-COMPATIBEL (macOS).
set -eo pipefail

doBackup=1
keep=3
anonymize=0
for arg in "$@"; do
    case "${arg}" in
        --no-backup) doBackup=0 ;;
        --anonymize) anonymize=1 ;;
        --keep=*)
            keep="${arg#--keep=}"
            [[ "${keep}" =~ ^[1-9][0-9]*$ ]] || { echo "--keep verwacht een getal vanaf 1, kreeg: ${keep}" >&2; exit 2; }
            ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Onbekende optie: ${arg} (zie --help)" >&2; exit 2 ;;
    esac
done

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Alles wat dit script aanmaakt (backup/, dumps) alleen voor de eigenaar.
umask 077

[ -n "${LIVE_SSH_HOST}" ] || die "LIVE_SSH_HOST is leeg in scripts.conf; deze repo heeft geen live-database om op te halen."
[ -n "${LIVE_JOOMLA_DIR}" ] || die "LIVE_JOOMLA_DIR is leeg in scripts.conf."
command -v ddev >/dev/null || die "ddev is vereist."
require_joomla_dir

# DDEV-projectmap: het Joomla-pad zelf of de map erboven (zoals deploy-ddev.sh).
if [ -f "${JOOMLA_DIR}/.ddev/config.yaml" ]; then
    ddevProjectDir="${JOOMLA_DIR}"
elif [ -f "$(dirname "${JOOMLA_DIR}")/.ddev/config.yaml" ]; then
    ddevProjectDir="$(dirname "${JOOMLA_DIR}")"
else
    die "geen DDEV-project bij ${JOOMLA_DIR} (geen .ddev/config.yaml daar of erboven)."
fi

anonymizeFile=""
if [ "${anonymize}" -eq 1 ] && [ -n "${ANONYMIZE_SQL:-}" ]; then
    anonymizeFile="${REPO_DIR}/${ANONYMIZE_SQL}"
    [ -f "${anonymizeFile}" ] || die "ANONYMIZE_SQL uit scripts.conf bestaat niet: ${ANONYMIZE_SQL}"
fi

backupDir="${ddevProjectDir}/backup"
stamp="$(date +%Y%m%d-%H%M%S)"
liveDump="${backupDir}/live-${stamp}.sql.gz"
localBackup="${backupDir}/local-before-import-${stamp}.sql.gz"

# Een productiedump hoort nooit in git: stop als de projectmap een repo is die backup/ niet negeert.
if git -C "${ddevProjectDir}" rev-parse --git-dir >/dev/null 2>&1 \
    && ! git -C "${ddevProjectDir}" check-ignore -q "backup/live-${stamp}.sql.gz"; then
    die "backup/ wordt niet door git genegeerd in ${ddevProjectDir}; voeg /backup/ toe aan de .gitignore daar."
fi
mkdir -p "${backupDir}"
chmod 700 "${backupDir}"

info "==> Live-database dumpen van ${LIVE_SSH_HOST}..."
# Een mislukte dump laat toch een gzip-header achter: bij elke fout het bestand weghalen.
trap 'rc=$?; [ "$rc" -eq 0 ] && [ -s "${liveDump}" ] || rm -f "${liveDump}"' EXIT
ssh "${LIVE_SSH_HOST}" bash -s -- "${LIVE_JOOMLA_DIR}" <<'REMOTE' > "${liveDump}"
set -euo pipefail
dir="${1:-}"
if [ ! -f "$dir/configuration.php" ]; then
    # Eén map dieper of twee (htdocs/public_html); [n] laat nullglob een ontbrekend pad weglaten.
    shopt -s nullglob
    found=("$dir"/*/configuratio[n].php "$dir"/*/*/configuratio[n].php)
    if [ "${#found[@]}" -ne 1 ]; then
        echo "Verwachtte één configuration.php in of onder $dir, vond ${#found[@]}: ${found[*]:-geen}. Zet LIVE_JOOMLA_DIR in scripts.conf." >&2
        exit 1
    fi
    dir="$(dirname "${found[0]}")"
    echo "    Live Joomla-map: $dir" >&2
fi
cd "$dir"
# Eén waarde per regel, zodat een wachtwoord met spaties heel blijft.
{ read -r DB; read -r USER; read -r PASS; read -r HOST; } < <(php -r 'define("_JEXEC", 1); require "configuration.php"; $c = new JConfig; echo "$c->db\n$c->user\n$c->password\n$c->host\n";')
# Joomla staat "host:poort" en "host:/pad/naar.sock" toe; mariadb-dump wil die apart.
CONN=(-h "$HOST")
if [[ "$HOST" == *:* ]]; then
    PORT="${HOST#*:}"
    if [[ "$PORT" == /* ]]; then CONN=(-h "${HOST%%:*}" --socket="$PORT"); else CONN=(-h "${HOST%%:*}" -P "$PORT"); fi
fi
MYSQL_PWD="$PASS" mariadb-dump "${CONN[@]}" -u "$USER" \
    --single-transaction --quick --routines --triggers --no-tablespaces \
    "$DB" | gzip -c
REMOTE

if [ ! -s "${liveDump}" ] || ! gzip -t "${liveDump}" 2>/dev/null; then
    die "dump is leeg of corrupt: ${liveDump}"
fi
chmod 600 "${liveDump}"
success "    $(du -h "${liveDump}" | cut -f1) opgeslagen in ${liveDump}"

if [ "${doBackup}" -eq 1 ]; then
    info "==> Back-up van de huidige lokale database..."
    ( cd "${ddevProjectDir}" && ddev export-db --file="${localBackup}" )
    chmod 600 "${localBackup}"
    success "    Opgeslagen in ${localBackup}"
fi

info "==> Importeren in DDEV..."
( cd "${ddevProjectDir}" && ddev import-db --file="${liveDump}" )

if [ "${anonymize}" -eq 1 ]; then
    info "==> Persoonsgegevens anonimiseren..."
    prefix="$("${PHP_BIN}" -r 'error_reporting(0); require $argv[1]; echo (new JConfig())->dbprefix ?? "";' "${JOOMLA_DIR}/configuration.php")"
    [[ "${prefix}" =~ ^[A-Za-z0-9_]+$ ]] || die "dbprefix '${prefix}' uit configuration.php is ongeldig; niets geanonimiseerd."
    {
        printf 'UPDATE `%susers` SET `email` = CONCAT('"'"'user'"'"', `id`, '"'"'@example.invalid'"'"');\n' "${prefix}"
        [ -z "${anonymizeFile}" ] || sed "s/#__/${prefix}/g" "${anonymizeFile}"
    } | ( cd "${ddevProjectDir}" && ddev mysql )
    success "    E-mailadressen van gebruikers vervangen${anonymizeFile:+ en ${ANONYMIZE_SQL} uitgevoerd}."
fi

# Per soort alleen de nieuwste ${keep} dumps bewaren.
for kind in live local-before-import; do
    # shellcheck disable=SC2012 # bestandsnamen zijn vast (soort-stempel.sql.gz), ls -t is hier veilig
    { ls -1t "${backupDir}/${kind}-"*.sql.gz 2>/dev/null || true; } | tail -n +$((keep + 1)) | while read -r old; do rm -f "${old}"; done
done

# Joomla maakt zijn PSR-4-map alleen opnieuw als het bestand ontbreekt; een verouderde lokale
# kopie breekt extensies die productie sindsdien kreeg ("Class ... not found").
rm -f "${JOOMLA_DIR}/administrator/cache/autoload_psr4.php"

success "==> Klaar."
