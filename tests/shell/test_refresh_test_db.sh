#!/bin/bash
# Test voor bin/refresh-test-db.sh met nep-ssh, nep-mariadb-dump en nep-mariadb (geen netwerk, geen
# database). De nep-ssh draait de remote scripts lokaal, zodat het uitlezen van configuration.php
# en het overnemen van $secret echt getest worden. Gebruik: bash tests/shell/test_refresh_test_db.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

command -v php >/dev/null || { echo "php ontbreekt; test overgeslagen."; exit 0; }

# Een minimale repo met deze bin/ en een scripts.conf met live- en testinstellingen.
copy="$tmp/repo"; mkdir -p "$copy"
cp -R "$repo/bin" "$copy/bin"
grep -vE '^(LIVE|TEST)_[A-Z_]+=' "$repo/scripts.conf" > "$copy/scripts.conf"
cat >> "$copy/scripts.conf" <<CONF
LIVE_SSH_HOST="live01"
LIVE_JOOMLA_DIR="$tmp/live"
TEST_SSH_HOST="test01"
TEST_JOOMLA_DIR="$tmp/test"
TEST_BACKUP_DIR="$tmp/backups"
TEST_PHP_BIN="php"
TEST_AFTER_IMPORT_SQL="after.sql"
CONF
printf 'UPDATE `#__extensions` SET `params` = 1;\n' > "$copy/after.sql"
git_init "$copy"

writeConfig() { # map database prefix secret
    mkdir -p "$1"
    cat > "$1/configuration.php" <<PHP
<?php
class JConfig {
	public \$secret = '$4';
	public \$host = 'localhost';
	public \$user = 'u_$2';
	public \$password = 'pw $2';
	public \$db = '$2';
	public \$dbprefix = '$3';
}
PHP
}
writeConfig "$tmp/live" livedb tst_ 'liveGeheim123'
writeConfig "$tmp/test" testdb tst_ 'testGeheim'
mkdir -p "$tmp/test/administrator/cache"
echo '<?php return [];' > "$tmp/test/administrator/cache/autoload_psr4.php"

# Nep-commando's. Ze schrijven wat ze krijgen naar $FAKE_LOG; SQL op stdin naar $FAKE_SQL.
mkdir -p "$tmp/fakebin" "$tmp/home"
cat > "$tmp/fakebin/ssh" <<'SH'
#!/bin/bash
echo "ssh host=$1" >> "$FAKE_LOG"
shift
exec bash -c "$*"
SH
cat > "$tmp/fakebin/mariadb-dump" <<'SH'
#!/bin/bash
echo "dump args=$* pwd=$MYSQL_PWD" >> "$FAKE_LOG"
case "$*" in *livedb*) [ -n "$FAKE_DUMP_FAIL" ] && { echo "dump mislukt" >&2; exit 1; } ;; esac
echo "-- dump van ${*: -1}"
SH
cat > "$tmp/fakebin/mariadb" <<'SH'
#!/bin/bash
echo "mariadb args=$*" >> "$FAKE_LOG"
cat >> "$FAKE_SQL"
SH
chmod +x "$tmp/fakebin/"*

export HOME="$tmp/home" FAKE_LOG="$tmp/log" FAKE_SQL="$tmp/sql" PATH="$tmp/fakebin:$PATH"
refresh() { : > "$FAKE_LOG"; : > "$FAKE_SQL"; run bash "$copy/bin/refresh-test-db.sh" "$@"; }
files() { find "$tmp/backups" -name "$1" 2>/dev/null | wc -l | tr -d ' '; }
secretOf() { php -r 'require $argv[1]; echo (new JConfig())->secret;' "$1/configuration.php"; }

# Gewone run.
refresh --yes
same "gewone run geeft exit 0" 0 "$rc"
grep -q '^ssh host=live01$' "$FAKE_LOG" && pass "  ssh naar LIVE_SSH_HOST" || bad "  geen ssh naar live01"
grep -q '^ssh host=test01$' "$FAKE_LOG" && pass "  ssh naar TEST_SSH_HOST" || bad "  geen ssh naar test01"
same "  één back-up van test" 1 "$(files 'test-before-import-*.sql.gz')"
same "  één back-up van de test-configuration.php" 1 "$(files 'configuration-before-import-*.php')"
same "  één live-dump" 1 "$(files 'live-*.sql.gz')"
liveDump="$(find "$tmp/backups" -name 'live-*.sql.gz' | head -1)"
gzip -dc "$liveDump" 2>/dev/null | grep -q -- '-- dump van livedb' && pass "  live-dump bevat de live-database" || bad "  live-dump klopt niet"
gzip -dc "$(find "$tmp/backups" -name 'test-before-import-*.sql.gz' | head -1)" | grep -q -- '-- dump van testdb' \
    && pass "  back-up bevat de testdatabase" || bad "  back-up klopt niet"
grep -q 'pwd=pw livedb$' "$FAKE_LOG" && pass "  wachtwoord met spatie heel doorgegeven" || bad "  wachtwoord verminkt"
grep -q -- '-- dump van livedb' "$FAKE_SQL" && pass "  live-dump in test geïmporteerd" || bad "  niet geïmporteerd"
grep -q -- '-u u_testdb testdb$' "$FAKE_LOG" && pass "  import in de testdatabase" || bad "  import niet in testdb: $(grep mariadb "$FAKE_LOG")"
grep -q -- '-u u_livedb livedb$' <(grep '^mariadb ' "$FAKE_LOG") && bad "  SQL op de live-database" || pass "  geen SQL op live"
grep -q 'TRUNCATE TABLE `tst_session`;' "$FAKE_SQL" && pass "  sessietabel geleegd" || bad "  sessies niet geleegd"
grep -q 'UPDATE `tst_extensions` SET `params` = 1;' "$FAKE_SQL" && pass "  TEST_AFTER_IMPORT_SQL met prefix" || bad "  TEST_AFTER_IMPORT_SQL niet gedraaid"
same "  \$secret van live overgenomen" 'liveGeheim123' "$(secretOf "$tmp/test")"
same "  \$secret van live ongewijzigd" 'liveGeheim123' "$(secretOf "$tmp/live")"
hasnt "  secret niet in de uitvoer" 'liveGeheim123'
has "  meldt dat de secret is aangepast" 'aangepast naar de live-waarde'
has "  2FA-controle overgeslagen zonder Joomla" '2FA-controle overgeslagen'
[ ! -e "$tmp/test/administrator/cache/autoload_psr4.php" ] && pass "  autoload_psr4.php weggehaald" || bad "  autoload_psr4.php staat er nog"
same "  backup-map alleen voor de eigenaar" 700 "$(stat -f %Lp "$tmp/backups" 2>/dev/null || stat -c %a "$tmp/backups")"
same "  live-dump alleen voor de eigenaar" 600 "$(stat -f %Lp "$liveDump" 2>/dev/null || stat -c %a "$liveDump")"
grep -q 'testGeheim' "$(find "$tmp/backups" -name 'configuration-before-import-*.php' | head -1)" \
    && pass "  config-back-up bevat de oude secret" || bad "  config-back-up klopt niet"

# Tweede run: secret is al gelijk.
sleep 1; refresh --yes
same "tweede run geeft exit 0" 0 "$rc"
has "  secret al gelijk" 'al gelijk aan live'

# --keep=1 ruimt oudere bestanden op.
sleep 1; refresh --yes --keep=1
same "--keep=1 geeft exit 0" 0 "$rc"
same "  één live-dump over" 1 "$(files 'live-*.sql.gz')"
same "  één config-back-up over" 1 "$(files 'configuration-before-import-*.php')"

# Zonder --yes en met "nee": niets gedaan.
: > "$FAKE_SQL"; : > "$FAKE_LOG"; run bash "$copy/bin/refresh-test-db.sh" <<< "nee"
same "\"nee\" geeft exit 1" 1 "$rc"
grep -q 'mariadb-dump\|^dump' "$FAKE_LOG" && bad "  toch gedumpt" || pass "  niets gedumpt"

# Mislukte live-dump: geen halve dump, niets geïmporteerd.
rm -rf "$tmp/backups"; FAKE_DUMP_FAIL=1 refresh --yes
[ "$rc" -ne 0 ] && pass "mislukte dump geeft een fout (exit $rc)" || bad "mislukte dump gaf exit 0"
same "  geen live-dump achtergelaten" 0 "$(files 'live-*.sql.gz')"
[ -s "$FAKE_SQL" ] && bad "  toch geïmporteerd" || pass "  niets geïmporteerd"

# Ander tabelprefix: stoppen vóór er iets gebeurt.
writeConfig "$tmp/test" testdb anders_ 'testGeheim'
rm -rf "$tmp/backups"; refresh --yes
same "ander prefix geeft exit 1" 1 "$rc"; has "  noemt het prefix" 'prefix'
same "  geen back-up gemaakt" 0 "$(files '*')"
writeConfig "$tmp/test" testdb tst_ 'testGeheim'

# Live en test dezelfde database op dezelfde host.
cp "$copy/scripts.conf" "$tmp/conf.bak"
sed -i.tmp -e 's/^TEST_SSH_HOST=.*/TEST_SSH_HOST=""/' -e "s|^TEST_JOOMLA_DIR=.*|TEST_JOOMLA_DIR=\"$tmp/live\"|" "$copy/scripts.conf"
refresh --yes
same "zelfde database geeft exit 1" 1 "$rc"; has "  noemt dezelfde database" 'dezelfde database'
cp "$tmp/conf.bak" "$copy/scripts.conf"

# Geen testsite in scripts.conf.
grep -v '^TEST_JOOMLA_DIR=' "$tmp/conf.bak" > "$copy/scripts.conf"
refresh --yes
same "zonder TEST_JOOMLA_DIR geeft exit 1" 1 "$rc"; has "  noemt de instelling" 'TEST_JOOMLA_DIR'
grep -q 'ssh' "$FAKE_LOG" && bad "  toch ssh gestart" || pass "  geen ssh gestart"
cp "$tmp/conf.bak" "$copy/scripts.conf"

# Ontbrekend TEST_AFTER_IMPORT_SQL-bestand.
mv "$copy/after.sql" "$tmp/after.sql"; refresh --yes
same "ontbrekend SQL-bestand geeft exit 1" 1 "$rc"; has "  noemt de instelling" 'TEST_AFTER_IMPORT_SQL'
mv "$tmp/after.sql" "$copy/after.sql"

# Onbekende optie.
refresh --onbekend; same "onbekende optie" 2 "$rc"

finish
