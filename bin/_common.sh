#!/bin/bash
#
# bin/_common.sh — gedeelde basis voor alle scripts in bin/. Wordt gesourced, nooit
# direct gedraaid.
#
# De map bin/ is in alle HKweb-Joomla-repo's byte-identiek. Alles wat per repo verschilt
# staat in scripts.conf in de repo-root (alleen bash-variabelen, geen logica); dit bestand
# leest die configuratie, valideert de verplichte variabelen en zet de defaults.
#
# Omgeving (allemaal optioneel):
#   PHP_BIN                php-binary (default: php uit PATH; PHP_LINT_BIN werkt nog als alias)
#   {ENV_PREFIX}_JOOMLA_DIR  pad naar de lokale Joomla-installatie (bijv. KWEKFESTIJN_JOOMLA_DIR)
#   {ENV_PREFIX}_NO_DDEV     =1 forceert de directe mysql-client in run-migrations.sh
#
# BASH 3.2-COMPATIBEL (macOS): geen mapfile, geen `declare -A`, geen ${var,,}, en geen
# `set -u` in combinatie met arrays (een lege array is daar een 'unbound variable').

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! REPO_DIR="$(git -C "$SCRIPTS_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Fout: geen git-repository (bin/ hoort in een repo te staan). Exit code 2." >&2
    exit 2
fi

CONF_FILE="$REPO_DIR/scripts.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "Fout: $CONF_FILE ontbreekt (de repo-specifieke instellingen voor bin/). Exit code 2." >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$CONF_FILE"

for _var in PROJECT_NAME PACKAGE_ELEMENT ENV_PREFIX GITHUB_REPO; do
    if [ -z "${!_var}" ]; then
        echo "Fout: $_var ontbreekt in scripts.conf. Exit code 2." >&2
        exit 2
    fi
done
unset _var

# Defaults voor optionele variabelen (zie scripts.conf voor de betekenis).
: "${SRC_DIR:=Src}"
: "${MAIN_BRANCH:=main}"
: "${DEVELOP_BRANCH:=develop}"
: "${TIMEZONE:=Europe/Amsterdam}"
: "${UPDATES_XML:=updates.xml}"
: "${AIDOCS_FLAVOUR:=}"
# BUILT_DIRS: mappen onder SRC_DIR die de build maakt (niet in git, wel in de package). Leeg = geen.
[ "${BUILT_DIRS+x}" ] || BUILT_DIRS=()
: "${LENGTH_LIMIT_SEVERITY:=WARNING}"
case "$LENGTH_LIMIT_SEVERITY" in
    WARNING|ERROR) ;;
    *) echo "Fout: LENGTH_LIMIT_SEVERITY moet WARNING of ERROR zijn (zie scripts.conf). Exit code 2." >&2; exit 2 ;;
esac
: "${PHP_BIN:=${PHP_LINT_BIN:-php}}"

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_W=$'\033[33m'; C_F=$'\033[31m'; C_I=$'\033[36m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_OK=""; C_W=""; C_F=""; C_I=""; C_B=""; C_D=""; C_0=""
fi

info()    { printf '%s%s%s\n' "$C_I" "$*" "$C_0"; }
success() { printf '%s%s%s\n' "$C_OK" "$*" "$C_0"; }
notice()  { printf '%s%s%s\n' "$C_W" "$*" "$C_0"; }
die()     { printf '%sFout: %s%s\n' "$C_F" "$*" "$C_0" >&2; exit 1; }

# Vraagt bevestiging; alleen ja/j gaat door. $1 = vraag.
confirm() {
    local answer
    read -rp "$(printf '%s%s%s [ja/nee]: ' "$C_B" "$1" "$C_0")" answer
    [[ "$answer" =~ ^([jJyY]|[jJ][aA]|[yY][eE][sS])$ ]]
}

# Waarde van <ENV_PREFIX>_<naam> uit de omgeving (leeg als niet gezet). $1 = naam (JOOMLA_DIR).
project_env() {
    local var="${ENV_PREFIX}_$1"
    printf '%s' "${!var}"
}

# Eerste waarde van sleutel $1 uit .dev-local. Bewust geen `source`: het bestand is gebruikerscode
# en staat buiten git.
dev_local_get() {
    [ -f "$REPO_DIR/.dev-local" ] || return 0
    grep -m1 "^$1=" "$REPO_DIR/.dev-local" | cut -d= -f2- || true
}

# Zet JOOMLA_DIR: omgeving ({ENV_PREFIX}_JOOMLA_DIR), dan .dev-local (JOOMLA_DIR=, of de oudere
# sleutel SITE=), dan JOOMLA_DIR_DEFAULT uit scripts.conf mits daar een configuration.php staat.
# Geeft 1 terug als niets bruikbaars gevonden is.
find_joomla_dir() {
    JOOMLA_DIR="$(project_env JOOMLA_DIR)"
    [ -n "$JOOMLA_DIR" ] || JOOMLA_DIR="$(dev_local_get JOOMLA_DIR)"
    [ -n "$JOOMLA_DIR" ] || JOOMLA_DIR="$(dev_local_get SITE)"
    if [ -z "$JOOMLA_DIR" ] && [ -n "$JOOMLA_DIR_DEFAULT" ] && [ -f "$JOOMLA_DIR_DEFAULT/configuration.php" ]; then
        JOOMLA_DIR="$JOOMLA_DIR_DEFAULT"
    fi
    JOOMLA_DIR="${JOOMLA_DIR%/}"
    [ -n "$JOOMLA_DIR" ]
}

# Als find_joomla_dir, maar vraagt het pad (en slaat het pas op als het klopt) wanneer het
# nergens staat. Stopt met een foutmelding als er geen geldige installatie is.
require_joomla_dir() {
    if ! find_joomla_dir; then
        read -rp "Pad naar de Joomla-installatie (map met configuration.php): " JOOMLA_DIR
        JOOMLA_DIR="${JOOMLA_DIR%/}"
        [ -f "$JOOMLA_DIR/configuration.php" ] || die "$JOOMLA_DIR/configuration.php niet gevonden; pad niet opgeslagen."
        echo "JOOMLA_DIR=$JOOMLA_DIR" >> "$REPO_DIR/.dev-local"
    fi
    [ -f "$JOOMLA_DIR/configuration.php" ] \
        || die "$JOOMLA_DIR/configuration.php niet gevonden. Zet ${ENV_PREFIX}_JOOMLA_DIR of pas .dev-local aan."
}

# <version>-waarde van een manifest (eerste voorkomen). $1 = pad.
manifest_version() {
    grep -m1 '<version>' "$1" 2>/dev/null | sed -E 's#.*<version>([^<]+)</version>.*#\1#'
}
