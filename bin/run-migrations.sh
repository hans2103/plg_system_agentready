#!/bin/bash
#
# bin/run-migrations.sh — voert alle pending SQL-migraties uit sql/migrations/ uit tegen
# een lokale Joomla-installatie. DB-gegevens en tabelprefix komen uit configuration.php;
# `#__` wordt door de echte prefix vervangen.
#
# Het Joomla-pad komt uit ${ENV_PREFIX}_JOOMLA_DIR (bijv. KWEKFESTIJN_JOOMLA_DIR), anders uit
# .dev-local (gitignored; regel JOOMLA_DIR=... of de oudere SITE=...), anders uit
# JOOMLA_DIR_DEFAULT in scripts.conf, anders wordt het gevraagd en in .dev-local opgeslagen.
#
# Migraties draaien in volgorde van hun tijdstempel (het datum- en tijddeel van de naam, niet
# het issuenummer). Ze moeten idempotent zijn: dit script draait ze elke keer opnieuw. De
# bestanden blijven in sql/migrations/ staan; package.sh verplaatst ze bij een release naar
# sql/migrations/applied/.
#
# DDEV: staat er een .ddev/config.yaml in het Joomla-pad of in de map erboven, dan wordt de
# SQL via `ddev mysql` uitgevoerd (de database in de container is vanaf de Mac niet
# rechtstreeks bereikbaar). `ddev mysql` bestaat alleen binnen een DDEV-project; daarom doet
# het script eerst een `cd` naar de projectmap. DDEV start het project zelf, dus Docker/
# OrbStack moet draaien. `ddev mysql` verbindt met database 'db'; heet de database in
# configuration.php anders, dan stopt het script.
# ${ENV_PREFIX}_NO_DDEV=1 forceert de directe mysql-client, ook als er een .ddev aanwezig is.
#
# Gebruik: bash bin/run-migrations.sh [--dry-run]
#   --dry-run   toont de pending migraties en de verbinding; voert niets uit en vraagt niets
# Omgeving: PHP_BIN (default php; leest configuration.php)
#
# BASH 3.2-COMPATIBEL (macOS).
set -eo pipefail

dryRun=0
case "${1:-}" in
    "") ;;
    --dry-run) dryRun=1 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Onbekende optie: $1 (zie --help)" >&2; exit 2 ;;
esac

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

migrationsDir="${REPO_DIR}/sql/migrations"

command -v "$PHP_BIN" >/dev/null || die "php is vereist om configuration.php te lezen (zet PHP_BIN)."
require_joomla_dir
sitePath="$JOOMLA_DIR"

# DDEV-projectmap: het Joomla-pad zelf of de map erboven (bijv. Sites/x/public_html -> Sites/x).
ddevProjectDir=""
if [ -f "${sitePath}/.ddev/config.yaml" ]; then
    ddevProjectDir=${sitePath}
elif [ -f "$(dirname "${sitePath}")/.ddev/config.yaml" ]; then
    ddevProjectDir=$(dirname "${sitePath}")
fi
useDdev=false
if [ -n "${ddevProjectDir}" ] && [ "$(project_env NO_DDEV)" != "1" ]; then
    useDdev=true
fi

if [ "${dryRun}" -eq 0 ]; then
    if [ "${useDdev}" = true ]; then
        command -v ddev >/dev/null || die "ddev is vereist voor dit DDEV-project (zie https://ddev.readthedocs.io/en/stable/). Of zet ${ENV_PREFIX}_NO_DDEV=1 voor de directe mysql-client."
    else
        command -v mysql >/dev/null || die "mysql-client is vereist (macOS: brew install mysql-client)."
    fi
fi

# DB-gegevens uit configuration.php (het is Joomla's eigen JConfig-klasse; shell-veilig gequote).
eval "$("$PHP_BIN" -r '
error_reporting(0);
require $argv[1];
$c = new JConfig();
foreach (["dbHost" => "host", "dbUser" => "user", "dbPass" => "password", "dbName" => "db", "dbPrefix" => "dbprefix"] as $shell => $prop) {
    echo $shell, "=", escapeshellarg((string) ($c->$prop ?? "")), "\n";
}
' "${sitePath}/configuration.php")"
[ -n "${dbPrefix}" ] || die "dbprefix niet gevonden in configuration.php."
[[ "${dbPrefix}" =~ ^[A-Za-z0-9_]+$ ]] || die "dbprefix '${dbPrefix}' bevat andere tekens dan letters, cijfers en underscores; niets uitgevoerd."
# `ddev mysql` verbindt zonder extra argumenten met DDEV's standaarddatabase 'db'.
if [ "${useDdev}" = true ] && [ "${dbName}" != "db" ]; then
    die "DDEV's 'ddev mysql' verbindt met database 'db', maar configuration.php gebruikt '${dbName}'. Zet ${ENV_PREFIX}_NO_DDEV=1 of pas de database aan."
fi

# host:poort (Joomla staat "127.0.0.1:3307" toe) gaat als --host en --port naar mysql.
mysqlHost=${dbHost}
mysqlPort=""
if [[ "${dbHost}" == *:* ]] && [[ "${dbHost##*:}" =~ ^[0-9]+$ ]]; then
    mysqlHost=${dbHost%%:*}
    mysqlPort=${dbHost##*:}
fi

# Leest de SQL van stdin en voert die uit: via ddev (vanuit de projectmap) of via de mysql-client.
run_sql() {
    if [ "${useDdev}" = true ]; then
        (cd "${ddevProjectDir}" && ddev mysql)
    else
        local args=(--host="${mysqlHost}" --user="${dbUser}" --database="${dbName}" --default-character-set=utf8mb4)
        [ -z "${mysqlPort}" ] || args+=(--port="${mysqlPort}")
        MYSQL_PWD="${dbPass}" mysql "${args[@]}"
    fi
}

# Namen (zonder pad) in tijdstempelvolgorde: {issue}_{JJJJMMDD}_{UUMMSS}_… -> sorteer op veld 2 en 3.
pendingNames=$(find "${migrationsDir}" -maxdepth 1 -name "*.sql" -exec basename {} \; | sort -t_ -k2,3)
if [ -z "${pendingNames}" ]; then
    echo "Geen pending migraties in sql/migrations/ — niets te doen."
    exit 0
fi

echo "Site       : ${sitePath}"
if [ "${useDdev}" = true ]; then
    echo "Verbinding : DDEV (projectmap: ${ddevProjectDir})"
else
    echo "Verbinding : ${dbName} @ ${dbHost}"
fi
echo "Prefix     : ${dbPrefix}"
if [ "${useDdev}" != true ] && [ "${dbHost}" = "db" ] && [ "$(project_env NO_DDEV)" != "1" ]; then
    echo "Let op: host 'db' wijst op DDEV, maar er is geen DDEV-project gevonden bij ${sitePath} of de map erboven (symlink? zet ${ENV_PREFIX}_JOOMLA_DIR op het echte pad). Zonder DDEV kan mysql deze host waarschijnlijk niet bereiken."
fi
echo "Pending    :"
echo "${pendingNames}" | while read -r f; do echo "  · ${f}"; done

if [ "${dryRun}" -eq 1 ]; then
    echo ""
    echo "Dry run — er is niets uitgevoerd."
    exit 0
fi

echo ""
confirm "Alle migraties uitvoeren tegen '${dbName}'?" || { echo "Afgebroken."; exit 0; }

errFile=$(mktemp)
trap 'rm -f "${errFile}"' EXIT
failedName=""
skipped=""
while IFS= read -r migrationName; do
    # Na de eerste fout niets meer uitvoeren: latere migraties kunnen ervan afhangen.
    if [ -n "${failedName}" ]; then
        skipped="${skipped}  · ${migrationName}
"
        continue
    fi
    echo -n "  ${migrationName} ... "
    if sed "s/#__/${dbPrefix}/g" "${migrationsDir}/${migrationName}" | run_sql 2>"${errFile}"; then
        echo "OK"
    else
        echo "MISLUKT"
        tail -n 3 "${errFile}" | sed 's/^/    /'
        if [ "${useDdev}" = true ]; then
            echo "    Bij een verbindingsfout: draait Docker/OrbStack en het DDEV-project? Probeer: cd ${ddevProjectDir} && ddev start"
        fi
        failedName=${migrationName}
    fi
done <<< "${pendingNames}"

echo ""
if [ -n "${failedName}" ]; then
    echo "Migratie ${failedName} mislukt; de migraties daarvoor zijn wel uitgevoerd."
    if [ -n "${skipped}" ]; then
        echo "Overgeslagen (niet uitgevoerd):"
        printf '%s' "${skipped}"
    fi
    echo "Los de fout op en draai het script opnieuw."
    exit 1
fi
echo "Alle migraties uitgevoerd."
