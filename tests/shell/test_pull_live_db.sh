#!/bin/bash
# Test voor bin/pull-live-db.sh met nep-ssh, nep-mariadb-dump en nep-ddev (geen netwerk, geen
# database). De nep-ssh draait het remote script lokaal, zodat het uitlezen van configuration.php
# echt getest wordt. Gebruik: bash tests/shell/test_pull_live_db.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

command -v php >/dev/null || { echo "php ontbreekt; test overgeslagen."; exit 0; }

# Een minimale repo met deze bin/ en een scripts.conf met live-instellingen.
copy="$tmp/repo"; mkdir -p "$copy"
cp -R "$repo/bin" "$copy/bin"
grep -vE '^LIVE_(SSH_HOST|JOOMLA_DIR)=' "$repo/scripts.conf" > "$copy/scripts.conf"
printf 'LIVE_SSH_HOST="live01"\nLIVE_JOOMLA_DIR="%s"\n' "$tmp/live" >> "$copy/scripts.conf"
git_init "$copy"

# De "live"-site: alleen een configuration.php.
mkdir -p "$tmp/live"
writeLiveConfig() { # host wachtwoord
  cat > "$tmp/live/configuration.php" <<PHP
<?php
class JConfig {
    public \$host = '$1';
    public \$user = 'liveuser';
    public \$password = '$2';
    public \$db = 'livedb';
}
PHP
}
writeLiveConfig 'db.internal:3307' 'geheim met spatie'

# De lokale DDEV-site: public_html met configuration.php, .ddev/ ernaast.
site="$tmp/site"; mkdir -p "$site/public_html" "$site/.ddev"
printf '<?php\nclass JConfig {\n    public $dbprefix = %s;\n}\n' "'tst_'" > "$site/public_html/configuration.php"
echo 'name: testsite' > "$site/.ddev/config.yaml"
mkdir -p "$site/public_html/administrator/cache"
echo '<?php return [];' > "$site/public_html/administrator/cache/autoload_psr4.php"

# Nep-commando's. Ze schrijven wat ze krijgen naar $tmp/log.
mkdir -p "$tmp/fakebin" "$tmp/home"
cat > "$tmp/fakebin/ssh" <<'SH'
#!/bin/bash
echo "ssh host=$1" >> "$FAKE_LOG"
shift
exec "$@"
SH
cat > "$tmp/fakebin/mariadb-dump" <<'SH'
#!/bin/bash
echo "dump args=$* pwd=$MYSQL_PWD" >> "$FAKE_LOG"
[ -n "$FAKE_DUMP_FAIL" ] && { echo "dump mislukt" >&2; exit 1; }
echo "-- dump van $*"
SH
cat > "$tmp/fakebin/ddev" <<'SH'
#!/bin/bash
echo "ddev cwd=$PWD $*" >> "$FAKE_LOG"
case "$1" in
  export-db) printf 'lokaal\n' | gzip -c > "${2#--file=}" ;;
  import-db) gzip -t "${2#--file=}" || exit 1 ;;
  mysql) cat >> "$FAKE_SQL" ;;
esac
SH
chmod +x "$tmp/fakebin/"*

export HOME="$tmp/home" FAKE_LOG="$tmp/log" FAKE_SQL="$tmp/sql" PATH="$tmp/fakebin:$PATH"
export "${ENV_PREFIX}_JOOMLA_DIR=$site/public_html"
pull() { : > "$FAKE_LOG"; run bash "$copy/bin/pull-live-db.sh" "$@"; }
dumps() { find "$site/backup" -name "$1" 2>/dev/null | wc -l | tr -d ' '; }

# Gewone run: dump van live in backup/ van de DDEV-site, back-up van lokaal, dan import.
pull
same "gewone run geeft exit 0" 0 "$rc"
same "  één live-dump in backup/ van de site" 1 "$(dumps 'live-*.sql.gz')"
same "  één lokale back-up" 1 "$(dumps 'local-before-import-*.sql.gz')"
liveDump="$(find "$site/backup" -name 'live-*.sql.gz' | head -1)"
gzip -dc "$liveDump" 2>/dev/null | grep -q -- '-- dump van' && pass "  live-dump bevat de dump" || bad "  live-dump is leeg of geen gzip"
grep -q '^ssh host=live01$' "$FAKE_LOG" && pass "  ssh naar LIVE_SSH_HOST" || bad "  ssh ging niet naar live01"
grep -q -- '-h db.internal -P 3307 -u liveuser .*livedb' "$FAKE_LOG" && pass "  host:poort uit configuration.php gesplitst" || bad "  verkeerde verbindingsargumenten: $(grep dump "$FAKE_LOG")"
grep -q 'pwd=geheim met spatie$' "$FAKE_LOG" && pass "  wachtwoord met spatie heel doorgegeven" || bad "  wachtwoord verminkt: $(grep dump "$FAKE_LOG")"
grep -q "^ddev cwd=$site export-db" "$FAKE_LOG" && pass "  ddev export-db in de DDEV-projectmap" || bad "  export-db niet in $site"
grep -q "^ddev cwd=$site import-db --file=$liveDump" "$FAKE_LOG" && pass "  ddev import-db met de live-dump" || bad "  import-db niet zoals verwacht"
[ ! -e "$copy/backup" ] && pass "  niets in de package-repo geschreven" || bad "  backup/ in de package-repo aangemaakt"
[ ! -e "$site/public_html/administrator/cache/autoload_psr4.php" ] && pass "  autoload_psr4.php weggehaald" || bad "  autoload_psr4.php staat er nog"

# LIVE_JOOMLA_DIR een map hoger (zoals htdocs boven public_html): configuration.php wordt gevonden.
mkdir -p "$tmp/livehome"; mv "$tmp/live" "$tmp/livehome/public_html"
sed -i.bak "s|^LIVE_JOOMLA_DIR=.*|LIVE_JOOMLA_DIR=\"$tmp/livehome\"|" "$copy/scripts.conf"
rm -rf "$site/backup"; pull --no-backup
same "configuration.php een map dieper geeft exit 0" 0 "$rc"
has "  noemt de gevonden map" 'Live Joomla-map: .*livehome/public_html'
grep -q -- '-u liveuser .*livedb' "$FAKE_LOG" && pass "  dumpt de database uit die configuration.php" || bad "  geen dump: $(cat "$FAKE_LOG")"
# Twee kandidaten: geen gok, een duidelijke fout.
mkdir -p "$tmp/livehome/tweede"; cp "$tmp/livehome/public_html/configuration.php" "$tmp/livehome/tweede/"
rm -rf "$site/backup"; pull --no-backup
[ "$rc" -ne 0 ] && pass "twee configuration.php's geeft een fout (exit $rc)" || bad "twee configuration.php's gaf exit 0"
has "  noemt LIVE_JOOMLA_DIR" 'LIVE_JOOMLA_DIR'
grep -q 'import-db' "$FAKE_LOG" && bad "  toch geïmporteerd" || pass "  niets geïmporteerd"
rm -rf "$tmp/livehome/tweede"; mv "$tmp/livehome/public_html" "$tmp/live"
mv "$copy/scripts.conf.bak" "$copy/scripts.conf"

# DDEV-projectmap is een git-repo zonder /backup/ in .gitignore: stoppen vóór de dump.
git_init "$site"
rm -rf "$site/backup"; pull --no-backup
same "backup/ niet genegeerd geeft exit 1" 1 "$rc"; has "  noemt de .gitignore" '\.gitignore'
grep -q 'ssh' "$FAKE_LOG" && bad "  toch ssh gestart" || pass "  geen ssh gestart"
echo '/backup/' > "$site/.gitignore"
pull --no-backup
same "met /backup/ in .gitignore geeft exit 0" 0 "$rc"
rm -rf "$site/.git" "$site/.gitignore"

# --no-backup: geen export van de lokale database.
rm -rf "$site/backup"; pull --no-backup
same "--no-backup geeft exit 0" 0 "$rc"
grep -q 'export-db' "$FAKE_LOG" && bad "  toch een lokale back-up gemaakt" || pass "  geen lokale back-up"
grep -q 'import-db' "$FAKE_LOG" && pass "  wel geïmporteerd" || bad "  niet geïmporteerd"

# Host met socket.
writeLiveConfig 'localhost:/run/mysqld/mysqld.sock' 'x'
rm -rf "$site/backup"; pull --no-backup
grep -q -- '-h localhost --socket=/run/mysqld/mysqld.sock -u liveuser' "$FAKE_LOG" && pass "host:socket wordt --socket" || bad "socket niet herkend: $(grep dump "$FAKE_LOG")"
writeLiveConfig 'db.internal:3307' 'geheim met spatie'

# Mislukte dump: geen (halve) dump achtergelaten, niets geïmporteerd.
rm -rf "$site/backup"; FAKE_DUMP_FAIL=1 pull
[ "$rc" -ne 0 ] && pass "mislukte dump geeft een fout (exit $rc)" || bad "mislukte dump gaf exit 0"
same "  geen dump achtergelaten" 0 "$(dumps 'live-*.sql.gz')"
grep -q 'import-db' "$FAKE_LOG" && bad "  toch geïmporteerd" || pass "  niets geïmporteerd"

# Geen live-instellingen in scripts.conf: duidelijke fout, niets gedaan.
cp "$copy/scripts.conf" "$tmp/conf.bak"
grep -vE '^LIVE_' "$tmp/conf.bak" > "$copy/scripts.conf"
pull
same "zonder LIVE_SSH_HOST geeft exit 1" 1 "$rc"; has "  noemt de instelling" 'LIVE_SSH_HOST'
grep -q 'ssh' "$FAKE_LOG" && bad "  toch ssh gestart" || pass "  geen ssh gestart"
cp "$tmp/conf.bak" "$copy/scripts.conf"

# Geen DDEV-project bij de Joomla-site.
mv "$site/.ddev" "$site/ddev.weg"; pull
same "zonder .ddev geeft exit 1" 1 "$rc"; has "  noemt DDEV" 'DDEV'
mv "$site/ddev.weg" "$site/.ddev"

# Onbekende optie.
pull --onbekend; same "onbekende optie" 2 "$rc"


# Bestandsrechten: dumps bevatten persoonsgegevens, dus alleen leesbaar voor de eigenaar (#56).
rm -rf "$site/backup"; pull
same "rechten-run geeft exit 0" 0 "$rc"
mode() { ls -l "$1" | cut -c1-10; }
same "  live-dump is -rw-------" "-rw-------" "$(mode "$(find "$site/backup" -name 'live-*.sql.gz' | head -1)")"
same "  lokale back-up is -rw-------" "-rw-------" "$(mode "$(find "$site/backup" -name 'local-before-import-*.sql.gz' | head -1)")"
same "  backup/ is drwx------" "drwx------" "$(ls -ld "$site/backup" | cut -c1-10)"

# --keep: standaard blijven de nieuwste 3 dumps per soort staan (#56).
rm -rf "$site/backup"; mkdir -p "$site/backup"
for d in 20200101-000001 20200101-000002 20200101-000003 20200101-000004; do
  : > "$site/backup/live-$d.sql.gz"; : > "$site/backup/local-before-import-$d.sql.gz"
  touch -t "${d:0:8}0000.${d:13:2}" "$site/backup/live-$d.sql.gz" "$site/backup/local-before-import-$d.sql.gz"
done
: > "$site/backup/eigen-bestand.txt"
pull
same "--keep standaard geeft exit 0" 0 "$rc"
same "  3 live-dumps over" 3 "$(dumps 'live-*.sql.gz')"
same "  3 lokale back-ups over" 3 "$(dumps 'local-before-import-*.sql.gz')"
[ -e "$site/backup/live-20200101-000004.sql.gz" ] && pass "  nieuwste oude dump blijft" || bad "  verkeerde dump weggehaald"
[ ! -e "$site/backup/live-20200101-000001.sql.gz" ] && pass "  oudste dump weg" || bad "  oudste dump staat er nog"
[ -e "$site/backup/eigen-bestand.txt" ] && pass "  andere bestanden blijven staan" || bad "  eigen bestand weggehaald"
pull --keep=1 --no-backup
same "  --keep=1: 1 live-dump over" 1 "$(dumps 'live-*.sql.gz')"
pull --keep=0; same "--keep=0 is ongeldig" 2 "$rc"
pull --keep=abc; same "--keep=abc is ongeldig" 2 "$rc"

# --anonymize: na de import persoonsgegevens overschrijven, met het lokale tabelprefix (#56).
rm -rf "$site/backup"; : > "$FAKE_SQL"; pull --no-backup
same "zonder --anonymize geen SQL" "" "$(cat "$FAKE_SQL")"
printf 'UPDATE `#__kwek_club` SET `email` = NULL;\n' > "$copy/anon.sql"
printf 'ANONYMIZE_SQL="anon.sql"\n' >> "$copy/scripts.conf"
rm -rf "$site/backup"; : > "$FAKE_SQL"; pull --no-backup --anonymize
same "--anonymize geeft exit 0" 0 "$rc"
grep -q 'UPDATE `tst_users` SET' "$FAKE_SQL" && pass "  Joomla-gebruikers geanonimiseerd met prefix tst_" || bad "  geen users-update: $(cat "$FAKE_SQL")"
grep -q 'example.invalid' "$FAKE_SQL" && pass "  e-mail naar example.invalid" || bad "  geen example.invalid-adres"
grep -q 'UPDATE `tst_kwek_club` SET `email` = NULL;' "$FAKE_SQL" && pass "  ANONYMIZE_SQL uit scripts.conf met prefix" || bad "  ANONYMIZE_SQL niet uitgevoerd: $(cat "$FAKE_SQL")"
[ "$(grep -E 'import-db|mysql' "$FAKE_LOG" | head -1 | grep -c import-db)" = 1 ] && pass "  pas na de import" || bad "  volgorde import/mysql klopt niet"
printf 'ANONYMIZE_SQL="bestaat-niet.sql"\n' >> "$copy/scripts.conf"
rm -rf "$site/backup"; pull --no-backup --anonymize
[ "$rc" -ne 0 ] && pass "ontbrekend ANONYMIZE_SQL-bestand geeft een fout" || bad "ontbrekend ANONYMIZE_SQL-bestand gaf exit 0"
has "  noemt het bestand" 'bestaat-niet.sql'
grep -v '^ANONYMIZE_SQL=' "$copy/scripts.conf" > "$tmp/conf.tmp" && cp "$tmp/conf.tmp" "$copy/scripts.conf"

finish
