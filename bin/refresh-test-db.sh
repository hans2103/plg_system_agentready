#!/bin/bash
#
# bin/refresh-test-db.sh — kopieert de live-database naar de testsite op de server en houdt de
# testsite daarna bruikbaar.
#
# Live: ssh naar LIVE_SSH_HOST, Joomla-map LIVE_JOOMLA_DIR. Test: ssh naar TEST_SSH_HOST (standaard
# dezelfde host), Joomla-map TEST_JOOMLA_DIR. Alles staat in scripts.conf; de databasegegevens leest
# het script op de server uit de configuration.php van elke site, dus er staan hier geen
# wachtwoorden en ze gaan ook niet over de lijn. Staat er in de opgegeven map geen
# configuration.php, dan zoekt het script er precies één tot twee mappen dieper.
#
# Stappen:
#   1. Controleert dat live en test hetzelfde tabelprefix hebben en niet dezelfde database zijn.
#   2. Back-up van de testdatabase (test-before-import-<stempel>.sql.gz) en van de
#      configuration.php van test (configuration-before-import-<stempel>.php) in TEST_BACKUP_DIR.
#   3. Dumpt live naar TEST_BACKUP_DIR (live-<stempel>.sql.gz) en importeert die in test.
#   4. Leegt de sessietabel en draait TEST_AFTER_IMPORT_SQL uit scripts.conf (#__ wordt het
#      tabelprefix): daarin staat wat op test anders moet dan op live, zoals paden.
#   5. Neemt $secret van live over in de configuration.php van test als die afwijkt. Joomla
#      versleutelt de 2FA-gegevens (#__user_mfa) met $secret; met een andere waarde kan op test
#      niemand meer inloggen met een verificatiecode, passkey of back-upcodes.
#   6. Haalt administrator/cache/autoload_psr4.php weg, leegt de Joomla-cache (als eigenaar van de
#      site) en controleert dat elk 2FA-record met de $secret van test te ontsleutelen is.
#
# Live wordt alleen gelezen. Dumps en back-ups bevatten persoonsgegevens: TEST_BACKUP_DIR is alleen
# voor de eigenaar (700, bestanden 600) en per soort blijven alleen de nieuwste --keep staan.
# Iedereen op de testsite moet daarna opnieuw inloggen.
#
# Gebruik: bash bin/refresh-test-db.sh [--yes] [--keep=N]
#   --yes      niet om bevestiging vragen
#   --keep=N   bewaar per soort de nieuwste N dumps en back-ups op de server (standaard 3)
#
# BASH 3.2-COMPATIBEL (macOS).
set -eo pipefail

assumeYes=0
keep=3
for arg in "$@"; do
    case "${arg}" in
        --yes) assumeYes=1 ;;
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

umask 077

[ -n "${LIVE_SSH_HOST}" ] || die "LIVE_SSH_HOST is leeg in scripts.conf; deze repo heeft geen live-database."
[ -n "${LIVE_JOOMLA_DIR}" ] || die "LIVE_JOOMLA_DIR is leeg in scripts.conf."
[ -n "${TEST_JOOMLA_DIR}" ] || die "TEST_JOOMLA_DIR is leeg in scripts.conf; deze repo heeft geen testsite."
: "${TEST_SSH_HOST:=${LIVE_SSH_HOST}}"
: "${TEST_BACKUP_DIR:=$(dirname "${TEST_JOOMLA_DIR}")/backup}"
: "${TEST_PHP_BIN:=php}"
for _value in "${TEST_JOOMLA_DIR}" "${TEST_BACKUP_DIR}" "${LIVE_JOOMLA_DIR}"; do
    [[ "${_value}" == /* ]] || die "paden in scripts.conf moeten absoluut zijn: ${_value}"
done
unset _value

afterSqlFile=""
if [ -n "${TEST_AFTER_IMPORT_SQL:-}" ]; then
    afterSqlFile="${REPO_DIR}/${TEST_AFTER_IMPORT_SQL}"
    [ -f "${afterSqlFile}" ] || die "TEST_AFTER_IMPORT_SQL uit scripts.conf bestaat niet: ${TEST_AFTER_IMPORT_SQL}"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
liveDump="${TEST_BACKUP_DIR}/live-${stamp}.sql.gz"

# Begin van elk remote script: zoek de map met configuration.php, ga erheen en lees de
# databasegegevens. Daarna staan DB, DBUSER, PFX en CONN klaar en zit het wachtwoord in MYSQL_PWD.
# shellcheck disable=SC2016 # remote code: wordt pas op de server door bash uitgebreid
remotePrelude='set -euo pipefail
umask 077
dir="$JOOMLA"
if [ ! -f "$dir/configuration.php" ]; then
    shopt -s nullglob
    found=("$dir"/*/configuratio[n].php "$dir"/*/*/configuratio[n].php)
    if [ "${#found[@]}" -ne 1 ]; then
        echo "Verwachtte één configuration.php in of onder $dir, vond ${#found[@]}. Pas scripts.conf aan." >&2
        exit 1
    fi
    dir="$(dirname "${found[0]}")"
fi
cd "$dir"
{ read -r DB; read -r DBUSER; read -r PASS; read -r HOST; read -r PFX; } < <("$PHP" -r '\''define("_JEXEC", 1); require "configuration.php"; $c = new JConfig; echo "$c->db\n$c->user\n$c->password\n$c->host\n$c->dbprefix\n";'\'')
CONN=(-h "$HOST")
if [[ "$HOST" == *:* ]]; then
    PORT="${HOST#*:}"
    if [[ "$PORT" == /* ]]; then CONN=(-h "${HOST%%:*}" --socket="$PORT"); else CONN=(-h "${HOST%%:*}" -P "$PORT"); fi
fi
export MYSQL_PWD="$PASS"
'

# Draait een script op een server. Het script gaat base64-gecodeerd mee in de opdracht, zodat stdin
# vrij blijft voor gegevens (de dump, SQL, de secret) en de login-shell daar niet uitmaakt.
# $1 = ssh-host, $2 = Joomla-map, $3 = php-binary, $4 = script (na de prelude). Extra variabelen
# voor het script gaan als NAAM=waarde in $5 en verder.
remote() {
    local host="$1" joomla="$2" php="$3" body="$4" vars="" encoded
    shift 4
    vars="$(printf 'JOOMLA=%q\nPHP=%q\n' "${joomla}" "${php}")"
    while [ $# -gt 0 ]; do
        vars="${vars}"$'\n'"$(printf '%s=%q' "${1%%=*}" "${1#*=}")"
        shift
    done
    encoded="$(printf '%s\n%s\n%s\n' "${vars}" "${remotePrelude}" "${body}" | base64 | tr -d '\n')"
    # shellcheck disable=SC2029 # bewust: de opdracht wordt hier samengesteld
    ssh "${host}" "bash -c \"\$(printf %s '${encoded}' | base64 -d)\""
}
onLive() { remote "${LIVE_SSH_HOST}" "${LIVE_JOOMLA_DIR}" php "$@"; }
onTest() { remote "${TEST_SSH_HOST}" "${TEST_JOOMLA_DIR}" "${TEST_PHP_BIN}" "$@"; }

# shellcheck disable=SC2016 # remote code
dbInfo='printf "%s\n%s\n%s\n" "$DB" "$PFX" "${CONN[*]}"'

info "==> Gegevens van live en test controleren..."
liveInfo="$(onLive "${dbInfo}")" || die "kon de live-configuratie niet lezen."
testInfo="$(onTest "${dbInfo}")" || die "kon de test-configuratie niet lezen."
liveDb="$(printf '%s\n' "${liveInfo}" | sed -n 1p)"; livePfx="$(printf '%s\n' "${liveInfo}" | sed -n 2p)"
testDb="$(printf '%s\n' "${testInfo}" | sed -n 1p)"; testPfx="$(printf '%s\n' "${testInfo}" | sed -n 2p)"
[[ "${testPfx}" =~ ^[A-Za-z0-9_]+$ ]] || die "tabelprefix '${testPfx}' van test is ongeldig."
[ "${livePfx}" = "${testPfx}" ] || die "tabelprefix verschilt (live ${livePfx}, test ${testPfx}); niets gedaan."
if [ "${LIVE_SSH_HOST}" = "${TEST_SSH_HOST}" ] && [ "${liveInfo}" = "${testInfo}" ]; then
    die "live en test gebruiken dezelfde database (${liveDb}); niets gedaan."
fi
echo "    live: ${LIVE_SSH_HOST} ${liveDb}  ->  test: ${TEST_SSH_HOST} ${testDb}"

if [ "${assumeYes}" -ne 1 ]; then
    confirm "De database ${testDb} op ${TEST_SSH_HOST} overschrijven met een kopie van live?" || die "afgebroken; niets gewijzigd."
fi

info "==> Back-up van test in ${TEST_BACKUP_DIR}..."
# shellcheck disable=SC2016 # remote code
onTest 'mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
out="$BACKUP_DIR/test-before-import-$STAMP.sql.gz"
mariadb-dump "${CONN[@]}" -u "$DBUSER" --single-transaction --quick --routines --triggers --no-tablespaces "$DB" | gzip -c > "$out" \
    || { rm -f "$out"; exit 1; }
gzip -t "$out"
cp -p configuration.php "$BACKUP_DIR/configuration-before-import-$STAMP.php"
chmod 600 "$out" "$BACKUP_DIR/configuration-before-import-$STAMP.php"' \
    "BACKUP_DIR=${TEST_BACKUP_DIR}" "STAMP=${stamp}" || die "back-up van test mislukt; niets geïmporteerd."
success "    test-before-import-${stamp}.sql.gz en configuration-before-import-${stamp}.php"

info "==> Live-database dumpen naar test..."
# shellcheck disable=SC2016 # remote code
if ! onLive 'mariadb-dump "${CONN[@]}" -u "$DBUSER" --single-transaction --quick --routines --triggers --no-tablespaces "$DB" | gzip -c' \
    | onTest 'cat > "$OUT"; chmod 600 "$OUT"; [ -s "$OUT" ] && gzip -t "$OUT"' "OUT=${liveDump}"; then
    # shellcheck disable=SC2016 # remote code
    onTest 'rm -f "$OUT"' "OUT=${liveDump}" || true
    die "dump van live mislukt of corrupt; test is niet gewijzigd."
fi
success "    ${liveDump}"

info "==> Importeren in test..."
# shellcheck disable=SC2016 # remote code
onTest 'gunzip -c "$IN" | mariadb "${CONN[@]}" -u "$DBUSER" "$DB"' "IN=${liveDump}" \
    || die "import mislukt; terugzetten kan met ${TEST_BACKUP_DIR}/test-before-import-${stamp}.sql.gz"

info "==> Sessies legen${afterSqlFile:+ en ${TEST_AFTER_IMPORT_SQL} draaien}..."
# shellcheck disable=SC2016 # remote code en SQL-backticks
{
    printf 'TRUNCATE TABLE `%ssession`;\n' "${testPfx}"
    [ -z "${afterSqlFile}" ] || sed "s/#__/${testPfx}/g" "${afterSqlFile}"
} | onTest 'mariadb "${CONN[@]}" -u "$DBUSER" "$DB"' || die "SQL na de import mislukt."

info "==> \$secret van live overnemen..."
# shellcheck disable=SC2016 # remote code
liveSecret="$(onLive '"$PHP" -r '\''define("_JEXEC", 1); require "configuration.php"; echo (new JConfig)->secret ?? "";'\''')" || liveSecret=""
[[ "${liveSecret}" =~ ^[A-Za-z0-9]+$ ]] || die "\$secret van live niet uit te lezen; de database is wel geïmporteerd, 2FA werkt op test mogelijk niet."
# De secret gaat via stdin, zodat hij niet in een procesoverzicht of logbestand belandt.
# shellcheck disable=SC2016 # remote code
printf '%s' "${liveSecret}" | onTest '"$PHP" -r '\''
    $secret = stream_get_contents(STDIN);
    $config = file_get_contents("configuration.php");
    if (!preg_match("/public \\\$secret = \x27([^\x27]*)\x27;/", $config, $m)) { fwrite(STDERR, "Geen \$secret-regel in configuration.php.\n"); exit(1); }
    if ($m[1] === $secret) { echo "    \$secret is al gelijk aan live.\n"; exit(0); }
    file_put_contents("configuration.php", str_replace($m[0], "public \$secret = \x27" . $secret . "\x27;", $config));
    echo "    \$secret aangepast naar de live-waarde.\n";
'\''
"$PHP" -l configuration.php > /dev/null' || die "\$secret niet over te nemen; herstel met ${TEST_BACKUP_DIR}/configuration-before-import-${stamp}.php"

info "==> Cache legen en 2FA-records controleren..."
# shellcheck disable=SC2016 # remote code
onTest 'rm -f administrator/cache/autoload_psr4.php
owner="$(ls -ld configuration.php | awk "{print \$3}")"
asOwner=()
[ "$(id -u)" -ne 0 ] || [ "$owner" = root ] || asOwner=(sudo -u "$owner")
if [ -f cli/joomla.php ]; then
    ${asOwner[@]+"${asOwner[@]}"} "$PHP" cli/joomla.php cache:clean > /dev/null 2>&1 || echo "    Waarschuwing: cache:clean mislukt; leeg de cache zo nodig in de backend."
fi
if [ ! -f libraries/src/Encrypt/Aes.php ]; then
    echo "    2FA-controle overgeslagen: geen Joomla-Aes gevonden."
    exit 0
fi
mariadb "${CONN[@]}" -u "$DBUSER" "$DB" -N -B -e "SELECT m.id, IFNULL(u.username, \"?\"), m.method, m.options FROM ${PFX}user_mfa m LEFT JOIN ${PFX}users u ON u.id = m.user_id ORDER BY m.id" \
| "$PHP" -r '\''
    define("_JEXEC", 1);
    define("JPATH_BASE", getcwd());
    require "includes/defines.php";
    require JPATH_LIBRARIES . "/bootstrap.php";
    require_once "configuration.php";
    $secret = (new JConfig())->secret;
    $total = 0;
    $failed = 0;
    while (($line = fgets(STDIN)) !== false) {
        [$id, $user, $method, $options] = array_pad(explode("\t", rtrim($line, "\n"), 4), 4, "");
        $ok = !str_starts_with($options, "###AES128###");
        foreach ([false, true] as $legacy) {
            if ($ok) {
                break;
            }
            $aes = new \Joomla\CMS\Encrypt\Aes("cbc");
            $aes->setPassword($secret, $legacy);
            $data = @json_decode(rtrim($aes->decryptString(substr($options, 12), true), "\0"), true);
            if (\is_string($data)) {
                $data = @json_decode($data, true);
            }
            $ok = \is_array($data);
        }
        $total++;
        if (!$ok) {
            $failed++;
            echo "    Niet te ontsleutelen: record $id ($method) van $user\n";
        }
    }
    echo "    $total 2FA-record(s) gecontroleerd, $failed niet te ontsleutelen.\n";
    exit($failed ? 1 : 0);
'\''' || die "niet alle 2FA-records zijn te ontsleutelen; zie hierboven."

# Per soort alleen de nieuwste ${keep} bestanden bewaren.
# shellcheck disable=SC2016 # remote code
onTest 'for kind in live test-before-import configuration-before-import; do
    ls -1t "$BACKUP_DIR/$kind-"* 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done
done' "BACKUP_DIR=${TEST_BACKUP_DIR}" "KEEP=${keep}" || notice "    Waarschuwing: oude dumps niet opgeruimd."

success "==> Klaar. Iedereen op de testsite moet opnieuw inloggen."
