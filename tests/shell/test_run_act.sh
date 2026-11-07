#!/bin/bash
# Test voor bin/run-act.sh met een nep-act. Gebruik: bash tests/shell/test_run_act.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

r="$tmp/r"
mkdir -p "$r/.github/workflows" "$tmp/bin" "$tmp/cache/act"; git_init "$r"
cp -R "$repo/bin" "$r/bin"; cp "$repo/scripts.conf" "$r/"
printf '<extension><version>26.1.0</version></extension>\n' > "$r/package.xml"

# Nep-act: logt de argumenten en de inhoud van het event-bestand.
cat > "$tmp/bin/act" <<'SH'
#!/bin/bash
echo "ARGS: $*" >> "$ACT_LOG"
while [ $# -gt 0 ]; do [ "$1" = "-e" ] && cat "$2" >> "$ACT_LOG"; shift; done
SH
chmod +x "$tmp/bin/act"
export PATH="$tmp/bin:$PATH" ACT_LOG="$tmp/act.log" XDG_CACHE_HOME="$tmp/cache"
ra() { ( cd "$r" && bash bin/run-act.sh "$@" ); }
workflow() { printf 'jobs:\n  b:\n    steps:\n' > "$r/.github/workflows/release.yml"; for u in "$@"; do printf '      - uses: %s\n' "$u" >> "$r/.github/workflows/release.yml"; done; }

# ── Alleen actions/checkout: geen waarschuwing over externe actions ──
workflow actions/checkout@v4
printf -- '--env LOCAL_ACT=1\n' > "$r/.actrc"
run ra 26.1.0; same "alleen checkout: exit 0" 0 "$rc"
hasnt "  geen melding over externe actions" 'externe actions'
grep -qE 'ARGS: push -W \.github/workflows/release\.yml -e act-event\.json --env LOCAL_ACT=1 -s GITHUB_TOKEN=dummy-token-lokaal' "$ACT_LOG" && pass "  act krijgt de release-workflow, LOCAL_ACT en de dummy-token" || bad "  act-aanroep klopt niet: $(head -1 "$ACT_LOG")"
grep -q "\"ref\": \"refs/tags/v26.1.0\"" "$ACT_LOG" && pass "  event-bestand bevat de tag" || bad "  tag ontbreekt in het event-bestand"
grep -q "\"full_name\": \"${GITHUB_REPO}\"" "$ACT_LOG" && pass "  event-bestand bevat GITHUB_REPO" || bad "  GITHUB_REPO ontbreekt in het event-bestand"
grep -q "\"login\": \"${GITHUB_REPO%%/*}\"" "$ACT_LOG" && pass "  event-bestand bevat de owner" || bad "  owner ontbreekt in het event-bestand"
[ ! -e "$r/act-event.json" ] && pass "  event-bestand is opgeruimd" || bad "  act-event.json staat er nog"

# ── Externe action zonder cache en zonder offline-modus ──
workflow actions/checkout@v4 shivammathur/setup-php@v2 './lokaal' 'docker://alpine:3'
rm -f "$r/.actrc"
run ra 26.1.0; same "externe action: exit 0 (alleen een waarschuwing)" 0 "$rc"
has "  noemt de externe action" 'externe actions \(shivammathur/setup-php@v2\)'
hasnt "  noemt checkout, lokale en docker-actions niet" 'checkout@|lokaal|docker://'
has "  geeft het clone-commando" 'git clone --depth 1 -b v2 https://github\.com/shivammathur/setup-php ".*/act/shivammathur-setup-php@v2"'
has "  vraagt om --action-offline-mode" "--action-offline-mode"
has "  waarschuwt voor een ontbrekende .actrc" '\.actrc ontbreekt'

# ── Gecachet, maar .actrc zonder offline-modus: alleen die hint ──
mkdir -p "$tmp/cache/act/shivammathur-setup-php@v2"
printf -- '--env LOCAL_ACT=1\n' > "$r/.actrc"
run ra 26.1.0
hasnt "  gecachet: geen clone-commando meer" 'git clone'
has "  maar nog wel de offline-hint" "--action-offline-mode"

# ── Gecachet én offline-modus: geen melding ──
printf -- '--action-offline-mode\n' >> "$r/.actrc"
run ra 26.1.0
hasnt "  volledig ingesteld: geen melding" 'externe actions'

# ── Versie ──
run ra 99.9.9; has "afwijkende versie waarschuwt" 'komt niet overeen met package\.xml \(26\.1\.0\)'
printf '26.1.0\n' | ( cd "$r" && bash bin/run-act.sh ) > "$tmp/out.txt" 2>&1; rc=$?
same "versie uit een prompt (Enter = package.xml)" 0 "$rc"
grep -q 'refs/tags/v26.1.0' "$ACT_LOG" && pass "  gebruikt de versie uit package.xml" || bad "  verkeerde versie"

# ── act ontbreekt ──
run env PATH="/usr/bin:/bin" bash -c "cd '$r' && bash bin/run-act.sh 26.1.0"
same "act ontbreekt geeft exit 1" 1 "$rc"; has "  met uitleg" 'act niet gevonden'
rm -f "$r/.github/workflows/release.yml"
run ra 26.1.0; same "workflow ontbreekt geeft exit 1" 1 "$rc"

finish
