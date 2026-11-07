#!/bin/bash
# Integratietest voor de echte release-run van bin/run-release.sh, met een lokale bare origin,
# een nep-package.sh en een nep-gh. Er gaat niets naar het netwerk.
# Gebruik: bash tests/shell/test_run_release_flow.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

origin="$tmp/origin.git"
work="$tmp/work"
mkdir -p "$tmp/bin"
git init -q --bare -b main "$origin"

# Nep-gh: elke `gh release view` slaagt meteen.
printf '#!/bin/bash\necho "https://example.test/release"\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# Werkrepo met alles wat scripts.conf noemt, zodat de release-commit zijn paden vindt.
mkdir -p "$work"; git_init "$work"
cp -R "$repo/bin" "$work/bin"; cp "$repo/scripts.conf" "$work/"
(
  cd "$work"
  printf '<extension><version>26.1.0</version><creationDate>2026-01-01</creationDate></extension>\n' > package.xml
  for f in "${VERSIONED_MANIFESTS[@]}"; do mkdir -p "$(dirname "$f")"; printf '<extension><version>26.1.0</version></extension>\n' > "$f"; done
  for f in "${VERSIONED_JSON[@]}"; do mkdir -p "$(dirname "$f")"; printf '{\n  "version": "26.1.0"\n}\n' > "$f"; done
  # Zoals de echte repo: sql/ en het updatebestand van het component alleen als die er zijn.
  [ ! -d "$repo/sql" ] || { mkdir -p sql/migrations; touch sql/migrations/.gitkeep; }
  [ -z "${COMPONENT_DIR:-}" ] || { mkdir -p "$COMPONENT_DIR/sql/updates/mysql"; touch "$COMPONENT_DIR/sql/updates/mysql/.gitkeep"; }
  # Nep-package.sh: stempelt de versie zoals het echte script en schrijft het updatebestand.
  cat > package.sh <<'SH'
#!/bin/bash
[ -z "$FAKE_PACKAGE_FAIL" ] || { echo "package.sh: mislukt (test)" >&2; exit 1; }
version="$1"
for f in package.xml $FAKE_MANIFESTS; do sed -i.bak -E "s#<version>[^<]+</version>#<version>${version}</version>#" "$f"; rm -f "$f.bak"; done
[ -z "$FAKE_UPDATES" ] || { mkdir -p "$FAKE_UPDATES"; echo "-- ${version}" > "$FAKE_UPDATES/${version}.sql"; }
[ -z "$FAKE_EXTRA" ] || echo "${version}" >> "$FAKE_EXTRA"
# Zoals het echte script: @since __DEPLOY_VERSION__ in Src/ wordt de versie.
grep -rlI '__DEPLOY_VERSION__' Src 2>/dev/null | while IFS= read -r f; do sed -i.bak "s#__DEPLOY_VERSION__#${version}#g" "$f"; rm -f "$f.bak"; done
SH
  git add -A && git commit -q -m "start" && git remote add origin "$origin" && git push -q origin main
  git checkout -q -b develop
  echo een > feature1.txt; git add -A; git commit -q -m "feat: #1 een"
  echo twee > feature2.txt; git add -A; git commit -q -m "feat: #2 twee"
  git push -q origin develop
)
export FAKE_MANIFESTS="${VERSIONED_MANIFESTS[*]}" FAKE_UPDATES="${COMPONENT_DIR:+$COMPONENT_DIR/sql/updates/mysql}"
rel() { ( cd "$work" && bash bin/run-release.sh "$@" ); }
og() { git --git-dir="$origin" "$@"; }

# ── In een terminal opent het script geen pager (#173) ──
# develop staat hier 2 commits voor op main, dus het script toont de lijst met te mergen commits.
# Een pager zou in een echte terminal wachten op `q`; de nep-pager laat een merkteken achter.
pagerMark="$tmp/pager-gebruikt"
GIT_PAGER="touch '$pagerMark'; cat" run in_tty bash -c "cd '$work' && bash bin/run-release.sh 99.1.0 --dry-run"
if [ "$rc" -eq 127 ]; then
  echo "skip: 'script' ontbreekt, de pager-controle is overgeslagen"
else
  same "dry-run in een terminal geeft exit 0" 0 "$rc"
  has "  toont de te mergen commits" 'feat: #2 twee'
  [ ! -e "$pagerMark" ] && pass "  opent geen git-pager" || bad "  opende de git-pager (git log zonder --no-pager)"
fi

# ── Mislukte build: niets op origin, hints in de uitvoer ──
main_before="$(og rev-parse main)"
FAKE_PACKAGE_FAIL=1 run rel 99.1.0 --yes
same "mislukte build geeft exit 1" 1 "$rc"
same "  origin/main is ongewijzigd" "$main_before" "$(og rev-parse main)"
[ -z "$(og tag --list)" ] && pass "  er is geen tag gepusht" || bad "  er staat toch een tag op origin"
has "  meldt dat er niets op GitHub staat" 'Er staat nog niets op GitHub'
has "  noemt de fase" 'tijdens: build'
# Herstel zoals de hint aangeeft
( cd "$work" && git reset -q --hard origin/main && git checkout -q develop )

# ── Geslaagde release met merge develop → main ──
run rel 99.1.0 --yes
same "release geeft exit 0" 0 "$rc"
has "  meldt de release" 'Release v99\.1\.0 staat op GitHub'
has "  herinnert aan main → develop" 'main terug te mergen naar develop'
same "  tag v99.1.0 is een annotated tag" "tag" "$(og cat-file -t v99.1.0)"
og merge-base --is-ancestor "$( cd "$work" && git rev-parse develop )" main && pass "  main bevat alle commits van develop" || bad "  main mist commits van develop"
same "  laatste commit op main is de release-commit" "chore(release): versie bijgewerkt naar 99.1.0" "$(og log -1 --format=%s main)"
og log --format=%s main | grep -q '^Merge develop into main voor release 99.1.0$' && pass "  merge-commit met release-versie in het bericht" || bad "  merge-commit ontbreekt"
same "  package.xml op origin/main heeft de nieuwe versie" "1" "$(og show main:package.xml | grep -c '<version>99.1.0</version>')"
# Alleen in een repo met een component (COMPONENT_DIR) maakt package.sh een SQL-updatebestand.
if [ -n "${COMPONENT_DIR:-}" ]; then
  og show "main:${COMPONENT_DIR}/sql/updates/mysql/99.1.0.sql" > /dev/null 2>&1 && pass "  het updatebestand zit in de release-commit" || bad "  updatebestand ontbreekt in de release-commit"
fi
same "  het script staat weer op de branch waar het begon" "develop" "$( cd "$work" && git rev-parse --abbrev-ref HEAD )"
same "  de werkmap is schoon" "" "$( cd "$work" && git status --porcelain )"

# ── Tweede release zonder nieuwe develop-commits: geen merge nodig ──
( cd "$work" && git fetch -q origin && git checkout -q develop && git merge -q --ff-only origin/main 2>/dev/null || git merge -q origin/main -m "sync" )
( cd "$work" && git push -q origin develop )
run rel 99.1.1 --yes
same "tweede release zonder merge geeft exit 0" 0 "$rc"
has "  meldt dat er geen merge nodig is" 'geen merge nodig'
same "  tag v99.1.1 bestaat" "tag" "$(og cat-file -t v99.1.1)"

# ── scripts.conf verandert in de merge: wat package.sh stempelt, komt mee in de release-commit ──
# Een andere clone pusht een nieuwe plugin naar develop; de lokale develop loopt daardoor achter
# en heeft de oude scripts.conf (zo ging release 26.43.0 mis met printbooklets.xml).
other="$tmp/other"; nieuw="Src/plugins/task/nieuw/nieuw.xml"
git clone -q -b develop "$origin" "$other"
(
  cd "$other"
  mkdir -p "$(dirname "$nieuw")"; printf '<extension><version>26.1.0</version></extension>\n' > "$nieuw"
  perl -0pi -e 's#VERSIONED_MANIFESTS=\(\n#VERSIONED_MANIFESTS=(\n"'"$nieuw"'"\n#' scripts.conf
  git add -A && git -c user.name=t -c user.email=t@t.test commit -q -m "feat: #3 nieuwe plugin" && git push -q origin develop
)
FAKE_MANIFESTS="$FAKE_MANIFESTS $nieuw" run rel 99.1.3 --yes
same "release met een nieuwe manifest uit de merge geeft exit 0" 0 "$rc"
same "  de nieuwe manifest heeft op origin/main de nieuwe versie" "1" "$(og show "main:$nieuw" | grep -c '<version>99.1.3</version>')"
same "  de werkmap is schoon" "" "$( cd "$work" && git status --porcelain )"
same "  het script staat weer op develop" "develop" "$( cd "$work" && git rev-parse --abbrev-ref HEAD )"

# ── Wijzigt package.sh een bestand buiten de release-paden, dan stopt het script vóór de push ──
( cd "$work" && git fetch -q origin && git merge -q --ff-only origin/develop 2>/dev/null || git merge -q origin/develop -m "sync" )
main_before="$(og rev-parse main)"
FAKE_MANIFESTS="$FAKE_MANIFESTS $nieuw" FAKE_EXTRA="feature1.txt" run rel 99.1.4 --yes
same "een gestempeld bestand buiten de release-commit geeft exit 1" 1 "$rc"
has "  noemt het bestand" 'feature1\.txt'
same "  origin/main is ongewijzigd" "$main_before" "$(og rev-parse main)"
same "  er is geen tag gepusht" "" "$(og tag --list | grep -c '99.1.4' | sed 's/^0$//')"
( cd "$work" && git checkout -q -- . && git checkout -q main && git reset -q --hard origin/main && git checkout -q develop )

# ── Code met @since __DEPLOY_VERSION__: de ingevulde versie zit in de release-commit ──
(
  cd "$work" && git fetch -q origin && git merge -q --ff-only origin/main 2>/dev/null || git merge -q origin/main -m "sync"
  mkdir -p Src/nieuw && printf '/** @since  __DEPLOY_VERSION__ */\n' > Src/nieuw/Klasse.php
  git add -A && git commit -q -m "feat: #3 nieuwe klasse" && git push -q origin develop
)
FAKE_MANIFESTS="$FAKE_MANIFESTS $nieuw" run rel 99.1.5 --yes
same "release met __DEPLOY_VERSION__ in de code geeft exit 0" 0 "$rc"
same "  de klasse heeft op origin/main de versie" "1" "$(og show main:Src/nieuw/Klasse.php | grep -c '@since  99.1.5')"
same "  de werkmap is schoon" "" "$( cd "$work" && git status --porcelain )"

# ── Een lokale main die voorloopt op origin wordt geweigerd ──
( cd "$work" && git checkout -q main && git pull -q origin main && echo x > ongepusht.txt && git add -A && git commit -q -m "lokaal" && git checkout -q develop )
run rel 99.1.2 --yes
same "lokale main vóór op origin wordt geweigerd" 1 "$rc"
has "  met uitleg" 'loopt 1 commit\(s\) voor op origin/main'
same "  er is geen tag gepusht" "" "$(og tag --list | grep -c '99.1.2' | sed 's/^0$//')"

finish
