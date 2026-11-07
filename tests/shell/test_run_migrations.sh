#!/bin/bash
# Test voor bin/run-migrations.sh met een nep-mysql. Gebruik: bash tests/shell/test_run_migrations.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

r="$tmp/r"
mkdir -p "$r/sql/migrations" "$tmp/joomla" "$tmp/bin"; git_init "$r"
cp -R "$repo/bin" "$r/bin"; cp "$repo/scripts.conf" "$r/"
mig="$r/sql/migrations"

# De drie migraties hebben bewust drie verschillende volgordes: tijdstempel 76, 100, 9 (a, b, c);
# gewoon alfabetisch op bestandsnaam 100, 76, 9 (b, a, c); numeriek op issuenummer 9, 76, 100 (c, a, b).
# Alleen sorteren op tijdstempel geeft a, b, c.
printf 'CREATE TABLE IF NOT EXISTS `#__%s_a` (id INT);\n' "$PROJECT_NAME" > "$mig/76_20260901_150000_a.sql"
printf 'CREATE TABLE IF NOT EXISTS `#__%s_b` (id INT);\n' "$PROJECT_NAME" > "$mig/100_20260902_090000_b.sql"
printf 'CREATE TABLE IF NOT EXISTS `#__%s_c` (id INT);\n' "$PROJECT_NAME" > "$mig/9_20260903_120000_c.sql"
config() { # host  → configuration.php met de opgegeven host
  cat > "$tmp/joomla/configuration.php" <<PHP
<?php class JConfig { public \$host = '$1'; public \$user = 'u'; public \$password = "p'w"; public \$db = 'jdb'; public \$dbprefix = 'xyz_'; }
PHP
}
config db.local
# Nep-mysql: logt argumenten, wachtwoord en SQL; faalt als de SQL het woord BOEM bevat, en met
# 1060 (kolom bestaat al) als de SQL het woord DUBBEL bevat.
cat > "$tmp/bin/mysql" <<'SH'
#!/bin/bash
echo "ARGS: $*" >> "$MYSQL_LOG"
echo "PWD: ${MYSQL_PWD:-}" >> "$MYSQL_LOG"
sql="$(cat)"
printf '%s\n' "$sql" >> "$MYSQL_LOG"
case "$sql" in
  *BOEM*) echo "ERROR 1064 (42000) at line 1: syntax" >&2; exit 1 ;;
  *DUBBEL*) echo "ERROR 1060 (42S21) at line 1: Duplicate column name 'DUBBEL'" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/mysql"

envvar="${ENV_PREFIX}_JOOMLA_DIR"
export PATH="$tmp/bin:$PATH" MYSQL_LOG="$tmp/log" "$envvar=$tmp/joomla" HOME="$tmp/home"
mkdir -p "$HOME"
mig_run() { ( cd "$r" && printf 'ja\n' | bash bin/run-migrations.sh "$@" ); }

# Zoekt in het log van de nep-mysql i.p.v. in de scriptuitvoer.
hasl()  { if grep -qE -- "$2" "$tmp/log"; then pass "$1"; else bad "$1 (patroon '$2' niet in het mysql-log)"; sed 's/^/      /' "$tmp/log" | tail -6; fi; }
hasnl() { if grep -qE -- "$2" "$tmp/log"; then bad "$1 (patroon '$2' staat wel in het mysql-log)"; else pass "$1"; fi; }

run mig_run; same "run eindigt met exit 0" 0 "$rc"
hasl "mysql krijgt host, gebruiker en database" 'ARGS: --host=db.local --user=u --database=jdb'
hasl "wachtwoord met quote via MYSQL_PWD" "PWD: p'w"
hasl "#__ vervangen door de tabelprefix" "xyz_${PROJECT_NAME}_a"
hasnl "geen #__ meer in de SQL" '#__'
log="$(cat "$tmp/log")"
a=$(printf '%s\n' "$log" | grep -n "xyz_${PROJECT_NAME}_a" | head -1 | cut -d: -f1)
b=$(printf '%s\n' "$log" | grep -n "xyz_${PROJECT_NAME}_b" | head -1 | cut -d: -f1)
c=$(printf '%s\n' "$log" | grep -n "xyz_${PROJECT_NAME}_c" | head -1 | cut -d: -f1)
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then
  pass "volgorde op tijdstempel (76_20260901 vóór 100_20260902 vóór 9_20260903)"
else
  bad "volgorde klopt niet (a=$a b=$b c=$c)"
fi

# host:poort gaat als --host en --port naar mysql
config 127.0.0.1:3307; rm -f "$tmp/log"
run mig_run; hasl "host:poort wordt gesplitst" 'ARGS: --host=127.0.0.1 --user=u --database=jdb --default-character-set=utf8mb4 --port=3307'
config db.local

# --dry-run roept mysql niet aan en vraagt niets
rm -f "$tmp/log"
run bash -c "cd '$r' && bash bin/run-migrations.sh --dry-run"
same "--dry-run eindigt met exit 0" 0 "$rc"; has "  meldt dry run" 'Dry run'
[ ! -f "$tmp/log" ] && pass "--dry-run roept mysql niet aan" || bad "--dry-run riep mysql aan"

# Afbreken bij 'nee'
rm -f "$tmp/log"
run bash -c "cd '$r' && printf 'nee\n' | bash bin/run-migrations.sh"
has "'nee' breekt af" 'Afgebroken'; [ ! -f "$tmp/log" ] && pass "  zonder mysql-aanroep" || bad "  mysql werd toch aangeroepen"

# Na de eerste fout wordt niets meer uitgevoerd: b (100_…) bevat BOEM, c (9_…) komt daarna
printf 'BOEM;\n' >> "$mig/100_20260902_090000_b.sql"; rm -f "$tmp/log"
run mig_run; same "mislukte migratie geeft exit 1" 1 "$rc"
has "  meldt de mislukte migratie" 'Migratie 100_20260902_090000_b.sql mislukt'
has "  noemt de overgeslagen migratie" 'Overgeslagen.*'
hasnl "  latere migratie c is niet uitgevoerd" "xyz_${PROJECT_NAME}_c"
printf 'CREATE TABLE IF NOT EXISTS `#__%s_b` (id INT);\n' "$PROJECT_NAME" > "$mig/100_20260902_090000_b.sql"

# /** CAN FAIL **/: de regel gaat los naar mysql; 'bestaat al' (1060) is geen fout, de rest loopt door.
cf="$mig/101_20260902_100000_cf.sql"
printf 'CREATE TABLE IF NOT EXISTS `#__%s_d` (id INT);\nALTER TABLE `#__%s_d` ADD COLUMN `DUBBEL` INT /** CAN FAIL **/;\nALTER TABLE `#__%s_d` ADD COLUMN `na` INT /** CAN FAIL **/;  \nUPDATE `#__%s_d` SET id = 1;\n' "$PROJECT_NAME" "$PROJECT_NAME" "$PROJECT_NAME" "$PROJECT_NAME" > "$cf"
rm -f "$tmp/log"
run mig_run; same "CAN FAIL met 'bestaat al' geeft exit 0" 0 "$rc"
has "  meldt de overgeslagen regel" '101_20260902_100000_cf.sql ... OK \(1 CAN FAIL'
hasl "  de regel na de CAN FAIL-regel draait" "ADD COLUMN \`na\`"
hasl "  het UPDATE daarna draait" "UPDATE \`xyz_${PROJECT_NAME}_d\`"
hasl "  latere migratie c draait" "xyz_${PROJECT_NAME}_c"
log="$(cat "$tmp/log")"
cr=$(printf '%s\n' "$log" | grep -n "CREATE TABLE IF NOT EXISTS \`xyz_${PROJECT_NAME}_d\`" | head -1 | cut -d: -f1)
up=$(printf '%s\n' "$log" | grep -n "UPDATE \`xyz_${PROJECT_NAME}_d\`" | head -1 | cut -d: -f1)
du=$(printf '%s\n' "$log" | grep -n 'ADD COLUMN `DUBBEL`' | head -1 | cut -d: -f1)
if [ -n "$cr" ] && [ -n "$du" ] && [ -n "$up" ] && [ "$cr" -lt "$du" ] && [ "$du" -lt "$up" ]; then
  pass "  volgorde binnen de migratie blijft (CREATE, CAN FAIL-regel, UPDATE)"
else
  bad "  volgorde binnen de migratie klopt niet (create=$cr canfail=$du update=$up)"
fi
# Een andere fout op een CAN FAIL-regel stopt de run wel.
printf 'ALTER TABLE `#__%s_d` ADD COLUMN `BOEM` INT /** CAN FAIL **/;\n' "$PROJECT_NAME" > "$cf"; rm -f "$tmp/log"
run mig_run; same "CAN FAIL met een andere fout geeft exit 1" 1 "$rc"
has "  meldt de mislukte migratie" 'Migratie 101_20260902_100000_cf.sql mislukt'
rm -f "$cf"

# Joomla-pad: .dev-local (JOOMLA_DIR= en de oudere SITE=) wanneer de omgevingsvariabele ontbreekt
unset "$envvar"
for key in JOOMLA_DIR SITE; do
  printf '%s=%s\n' "$key" "$tmp/joomla" > "$r/.dev-local"
  run bash -c "cd '$r' && bash bin/run-migrations.sh --dry-run"
  same ".dev-local met $key= wordt gelezen" 0 "$rc"
done
# Geen pad bekend en geen terminal: het script vraagt het en slaat een geldig pad op
rm -f "$r/.dev-local"
run bash -c "cd '$r' && printf '%s\n' '$tmp/joomla' | bash bin/run-migrations.sh --dry-run"
same "gevraagd pad geeft exit 0" 0 "$rc"
grep -q "^JOOMLA_DIR=$tmp/joomla$" "$r/.dev-local" && pass "  en wordt opgeslagen in .dev-local" || bad "  pad niet opgeslagen"
rm -f "$r/.dev-local"
run bash -c "cd '$r' && printf 'bestaat-niet\n' | bash bin/run-migrations.sh --dry-run"
same "ongeldig pad wordt geweigerd" 1 "$rc"; [ ! -f "$r/.dev-local" ] && pass "  en niet opgeslagen" || bad "  ongeldig pad is toch opgeslagen"

expect "onbekende optie" 2 bash -c "cd '$r' && bash bin/run-migrations.sh --nope"

finish
