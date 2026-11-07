#!/bin/bash
#
# bin/run-release.sh — de lokale release-procedure (zie RELEASE_DOC in scripts.conf).
#
# Stappen:
#   1. controleert dat de werkmap schoon is en haalt origin en de tags op
#   2. bepaalt het versienummer JJ.WW.N (argument, of voorstel op basis van de v*-tags)
#   3. toont een samenvatting en vraagt bevestiging
#   4. werkt main bij en merget develop → main (lokaal) als daar nog niet-gemergde commits in staan
#   5. bouwt het package (bash package.sh {versie}): stempelt versies (ook __DEPLOY_VERSION__) en consolideert sql/migrations
#   6. commit, pusht main één keer, tagt v{versie} en pusht de tag (dat start de release-workflow)
#   7. wacht tot de release zichtbaar is (gh release view)
# Tot stap 6 staat er niets op GitHub, dus een mislukte run kun je veilig terugdraaien.
#
# Gebruik: bash bin/run-release.sh [versie] [opties]
#   -n, --dry-run     toont het versievoorstel en de geplande stappen; voert niets uit
#       --act         simuleert de release-workflow lokaal met act (bin/run-act.sh); pusht
#                     of publiceert niets. Los te combineren met --dry-run.
#       --print-version  drukt alleen het voorgestelde versienummer af
#   -y, --yes         slaat de bevestigingsvraag over
#       --install     maakt ~/bin/release aan (wrapper die het script van de huidige repo start,
#                     dus één wrapper voor alle HKweb-repo's). Doet verder niets.
#   -h, --help        toont deze hulp en stopt
#
# Omgeving: RELEASE_YY en RELEASE_WW overschrijven jaar en week; RELEASE_DATE=JJJJ-MM-DD de
#           datum (bedoeld voor tests).
# Vereist: git, zip; gh voor het wachten op de release (zonder gh sla je die stap over).
#
# BASH 3.2-COMPATIBEL (macOS).
set -eo pipefail

usage() { sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ─── Argumenten ──────────────────────────────────────────────────────────────
dryRun=0
runAct=0
printVersion=0
assumeYes=0
install=0
versionArg=""
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run)    dryRun=1 ;;
        --act)           runAct=1 ;;
        --print-version) printVersion=1 ;;
        -y|--yes)        assumeYes=1 ;;
        --install)       install=1 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "Onbekende optie: $arg" >&2; exit 2 ;;
        *)               versionArg="$arg" ;;
    esac
done

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$REPO_DIR"

pollInterval=10   # seconden tussen checks
pollTimeout=600   # seconden totaal (= timeout-minutes van de workflow)

# ─── --install: ~/bin/release-wrapper aanmaken ──────────────────────────────
if [ "$install" -eq 1 ]; then
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/release" <<'EOF'
#!/bin/bash
# Automatisch aangemaakt door 'bin/run-release.sh --install'.
# Start het release-script van de repo waarin je nu staat: bin/ of, in repo's die nog niet
# zijn overgezet, het oude Scripts/.
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Fout: geen git-repository." >&2; exit 1; }
for dir in bin Scripts; do
    [ -f "$root/$dir/run-release.sh" ] && exec bash "$root/$dir/run-release.sh" "$@"
done
echo "Fout: $root/bin/run-release.sh bestaat niet (ook niet in Scripts/)." >&2; exit 1
EOF
    chmod +x "$HOME/bin/release"
    success "Wrapper aangemaakt: $HOME/bin/release"
    info "Zet $HOME/bin in je PATH om 'release' overal te kunnen typen."
    exit 0
fi

# ISO-weekjaar en weeknummer uit één date-aanroep: het kalenderjaar (%y) en de ISO-week (%V)
# lopen rond de jaarwisseling uiteen (29 dec 2025 is week 1 van 2026).
iso_year_week() {
    if [ -n "${RELEASE_DATE:-}" ]; then
        TZ="$TIMEZONE" date -j -f '%Y-%m-%d' "${RELEASE_DATE}" +'%G %V' 2>/dev/null || TZ="$TIMEZONE" date -d "${RELEASE_DATE}" +'%G %V'
    else
        TZ="$TIMEZONE" date +'%G %V'
    fi
}

# Volgende versie: zelfde ISO-jaar en -week als de nieuwste v*-tag geeft patch + 1, anders patch 0.
# Het weeknummer heeft geen voorloopnul (26.3.0), zodat versies numeriek sorteren.
propose_version() {
    local isoYear isoWeek yy ww latest
    read -r isoYear isoWeek <<< "$(iso_year_week)"
    yy="${RELEASE_YY:-${isoYear:2:2}}"
    ww="${RELEASE_WW:-$((10#${isoWeek}))}"
    latest=$(git tag --list | sed 's/^v//' | grep -E "^${yy}\.${ww}\.[0-9]+$" | sort -t. -k3,3n | tail -1 || true)
    if [ -z "$latest" ]; then
        echo "${yy}.${ww}.0"
    else
        echo "${yy}.${ww}.$(( ${latest##*.} + 1 ))"
    fi
}

if [ "$printVersion" -eq 1 ]; then
    propose_version
    exit 0
fi

# ─── Vooraf: tools, repo en actuele stand ───────────────────────────────────
for tool in git zip; do
    command -v "$tool" >/dev/null || die "'$tool' is niet gevonden. Installeer het en probeer opnieuw."
done
haveGh=true
command -v gh >/dev/null || haveGh=false
[ -f package.sh ] || die "package.sh niet gevonden in ${REPO_DIR} — klopt dit wel de repo-root?"

if [ "$dryRun" -eq 1 ] || [ "$runAct" -eq 1 ]; then
    git fetch origin --quiet --tags 2>/dev/null || notice "Waarschuwing: git fetch origin mislukt; het voorstel gebruikt de lokale stand."
else
    [ -z "$(git status --porcelain)" ] || die "werkmap is niet schoon. Commit of stash je wijzigingen eerst.
$(git status --short)"
    info "Ophalen van laatste stand (git fetch origin)..."
    git fetch origin --quiet --tags || die "git fetch origin mislukt."
fi

# ─── Status bepalen (wijzigt niets aan je checkout) ─────────────────────────
mergeNeeded=0
commitsToMerge=0
if git rev-parse --verify --quiet "origin/${MAIN_BRANCH}" >/dev/null && git rev-parse --verify --quiet "origin/${DEVELOP_BRANCH}" >/dev/null; then
    commitsToMerge=$(git rev-list --count "origin/${MAIN_BRANCH}..origin/${DEVELOP_BRANCH}")
    if [ "$commitsToMerge" -gt 0 ]; then
        mergeNeeded=1
        echo
        notice "${DEVELOP_BRANCH} staat ${commitsToMerge} commit(s) voor op ${MAIN_BRANCH}:"
        git --no-pager log --oneline "origin/${MAIN_BRANCH}..origin/${DEVELOP_BRANCH}"
    else
        success "${MAIN_BRANCH} bevat alle commits van ${DEVELOP_BRANCH}, geen merge nodig."
    fi
fi

# Huidige versie: package.xml op origin/main (val terug op develop en de werkmap).
currentVersion=$( { git show "origin/${MAIN_BRANCH}:package.xml" 2>/dev/null || git show "origin/${DEVELOP_BRANCH}:package.xml" 2>/dev/null || cat package.xml; } \
    | grep -m1 '<version>' | sed -E 's#.*<version>([^<]+)</version>.*#\1#')

version="${versionArg:-$(propose_version)}"
if [ -z "$versionArg" ] && [ "$dryRun" -eq 0 ] && [ "$assumeYes" -eq 0 ]; then
    read -rp "Versienummer [${version}]: " answer
    version="${answer:-$version}"
fi
[[ "$version" =~ ^[0-9]{2}\.[0-9]{1,2}\.[0-9]+$ ]] || die "versienummer '${version}' heeft niet het formaat JJ.WW.N (bv. 26.38.0)."
if git rev-parse "v${version}" >/dev/null 2>&1; then die "tag v${version} bestaat al."; fi

print_summary() {
    echo
    echo "─────────────────────────────────────────────────────────────"
    if [ "$dryRun" -eq 1 ]; then echo "${C_B}Release samenvatting (dry run — er wordt niets uitgevoerd)${C_0}"; else echo "${C_B}Release samenvatting${C_0}"; fi
    echo "─────────────────────────────────────────────────────────────"
    echo "  Repo:                ${GITHUB_REPO} (${REPO_DIR})"
    echo "  Huidige versie:      ${currentVersion:-onbekend}"
    echo "  Nieuwe versie:       ${version} (tag v${version})"
    if [ "$mergeNeeded" -eq 1 ]; then echo "  Merge ${DEVELOP_BRANCH}→${MAIN_BRANCH}:  JA (${commitsToMerge} commit(s))"; else echo "  Merge ${DEVELOP_BRANCH}→${MAIN_BRANCH}:  nee, niet nodig"; fi
    echo "  Acties:"
    if [ "$dryRun" -eq 1 ] || [ "$runAct" -eq 1 ]; then
        [ "$runAct" -eq 1 ] && echo "    - bash bin/run-act.sh ${version} (simulatie, niets wordt gepusht)"
        echo "    (echte release:)"
    fi
    echo "    - git checkout ${MAIN_BRANCH} + fast-forward naar origin/${MAIN_BRANCH} (indien nodig)"
    echo "    - eventueel git merge --no-ff origin/${DEVELOP_BRANCH} (lokaal)"
    echo "    - bash package.sh ${version}"
    echo "    - commit 'chore(release): versie bijgewerkt naar ${version}' + push naar ${MAIN_BRANCH} (de eerste push)"
    echo "    - git tag v${version} + push (start de release-workflow)"
    echo "    - wachten op de GitHub Release (gh release view)"
    echo "─────────────────────────────────────────────────────────────"
    echo
}

# ─── Dry run en/of simulatie met act ─────────────────────────────────────────
if [ "$dryRun" -eq 1 ] || [ "$runAct" -eq 1 ]; then
    print_summary
    if [ "$runAct" -eq 1 ]; then
        [ -f bin/run-act.sh ] || die "bin/run-act.sh niet gevonden."
        info "Workflow lokaal simuleren met act (bin/run-act.sh ${version})..."
        bash bin/run-act.sh "$version"
        success "Act-simulatie afgerond."
    fi
    notice "Dry run — er is niets gewijzigd, gecommit of gepusht."
    exit 0
fi

# ─── Samenvatting en bevestiging ─────────────────────────────────────────────
print_summary
if [ "$assumeYes" -ne 1 ]; then
    confirm "Doorgaan met deze release?" || { notice "Geannuleerd, er is niets gewijzigd of gepusht."; exit 0; }
fi

# Bij een fout na dit punt: zeg waar het script stond en hoe je herstelt.
startBranch=$(git rev-parse --abbrev-ref HEAD)
stage="voorbereiding"
released=0
on_exit() {
    local rc=$?
    [ "$rc" -ne 0 ] && [ "$released" -eq 0 ] || return 0
    echo >&2
    notice "Release afgebroken tijdens: ${stage}." >&2
    echo "  Je staat op '$(git rev-parse --abbrev-ref HEAD 2>/dev/null)' (begonnen op '${startBranch}'). Bekijk 'git status'." >&2
    case "$stage" in
        "merge")
            echo "  Merge-conflict? 'git merge --abort', ga terug naar ${DEVELOP_BRANCH} en los het conflict op via een PR." ;;
        "build"|"release-commit"|"push main")
            echo "  Er staat nog niets op GitHub. Bekijk 'git log origin/${MAIN_BRANCH}..${MAIN_BRANCH}': staan daar alleen commits van dit script"
            echo "  (de merge en/of de release-commit), dan zet 'git reset --hard origin/${MAIN_BRANCH}' alles terug."
            echo "  Ruim daarna op wat package.sh nieuw aanmaakte ('git clean -n' toont wat) en draai dit script opnieuw." ;;
        "tag")
            echo "  ${MAIN_BRANCH} is gepusht; alleen de tag ontbreekt op GitHub. Push hem zelf: git push origin v${version}"
            echo "  (bestaat de tag lokaal niet meer: git tag -a v${version} -m \"Release ${version}\")" ;;
    esac >&2
    [ -z "${RELEASE_DOC:-}" ] || echo "  Volledige herstelstappen: ${RELEASE_DOC}" >&2
}
trap on_exit EXIT

# ─── Main up-to-date brengen en mergen ──────────────────────────────────────
stage="merge"
[ "$startBranch" = "$MAIN_BRANCH" ] || { info "Wisselen naar ${MAIN_BRANCH}..."; git checkout "$MAIN_BRANCH" --quiet; }

if [ "$(git rev-parse "$MAIN_BRANCH")" != "$(git rev-parse "origin/${MAIN_BRANCH}")" ]; then
    info "Lokale ${MAIN_BRANCH} loopt achter op origin/${MAIN_BRANCH}, fast-forwarden..."
    git merge --ff-only "origin/${MAIN_BRANCH}" --quiet || die "${MAIN_BRANCH} kan niet fast-forwarded worden (lokale afwijkende commits?). Los dit handmatig op."
fi

ahead=$(git rev-list --count "origin/${MAIN_BRANCH}..${MAIN_BRANCH}")
if [ "$ahead" -gt 0 ]; then
    die "Lokale ${MAIN_BRANCH} loopt ${ahead} commit(s) voor op origin/${MAIN_BRANCH} (niet gepusht). Push of verwijder die eerst zelf; dit script pusht ze niet ongezien mee."
fi

if [ "$mergeNeeded" -eq 1 ]; then
    info "Mergen van origin/${DEVELOP_BRANCH} naar ${MAIN_BRANCH}..."
    git merge --no-ff "origin/${DEVELOP_BRANCH}" -m "Merge ${DEVELOP_BRANCH} into ${MAIN_BRANCH} voor release ${version}" --quiet \
        || die "Merge-conflict tussen ${DEVELOP_BRANCH} en ${MAIN_BRANCH}. Los dit handmatig op, rond de merge af en draai dit script opnieuw."
fi

# scripts.conf is ingelezen vanaf de branch waarop het script startte; na de merge kan hij
# anders zijn (bijv. een nieuwe plugin in VERSIONED_MANIFESTS). package.sh leest de nieuwe,
# dus lees hem hier opnieuw, anders stempelt package.sh bestanden die de release-commit mist.
# shellcheck source=scripts.conf
. "$CONF_FILE"

# ─── Package bouwen ───────────────────────────────────────────────────────────
stage="build"
# Bestanden met @since __DEPLOY_VERSION__: package.sh vult daar de versie in (als de repo dat doet),
# dus ze horen in de release-commit. Nu bepalen, want na het bouwen staat de placeholder er niet meer.
deployVersionFiles=()
while IFS= read -r f; do deployVersionFiles+=("$f"); done < <(git grep -lI '__DEPLOY_VERSION__' -- "$SRC_DIR" || true)
info "Package bouwen: bash package.sh ${version}..."
bash package.sh "$version"

# ─── Release-commit ────────────────────────────────────────────────────────────
# Wat package.sh wijzigt: package.xml, de versie-manifests en -JSON, de geconsolideerde
# migraties (sql/), het gegenereerde updatebestand van het component en de bestanden met
# __DEPLOY_VERSION__.
stage="release-commit"
info "Wijzigingen committen..."
releasePaths=(package.xml sql)
[ -z "${COMPONENT_DIR:-}" ] || releasePaths+=("${COMPONENT_DIR}/sql/updates")
for f in "${VERSIONED_MANIFESTS[@]}" "${VERSIONED_JSON[@]}"; do releasePaths+=("$f"); done
for f in ${deployVersionFiles[@]+"${deployVersionFiles[@]}"}; do releasePaths+=("$f"); done
git add -- "${releasePaths[@]}"
git diff --cached --quiet && die "package.sh leverde geen wijzigingen op om te committen — klopt dit?"
git commit --quiet -m "chore(release): versie bijgewerkt naar ${version}"

# Alles wat package.sh aan gevolgde bestanden wijzigde, hoort in de release-commit. Blijft er iets
# over, dan klopt scripts.conf niet (bijv. een manifest ontbreekt in VERSIONED_MANIFESTS): stop
# vóór de eerste push, zodat er niets half op GitHub komt.
leftover="$(git status --porcelain --untracked-files=no)"
[ -z "$leftover" ] || die "package.sh wijzigde bestanden die niet in de release-commit zitten (ontbreken ze in scripts.conf?):
${leftover}"

stage="push main"
info "Pushen naar ${MAIN_BRANCH}..."
git push origin "$MAIN_BRANCH" --quiet

# ─── Tag + push ────────────────────────────────────────────────────────────────
stage="tag"
info "Tag v${version} aanmaken en pushen..."
git tag -a "v${version}" -m "Release ${version}"
git push origin "v${version}" --quiet
released=1

# Terug naar de branch waarop je begon (tenzij dat main was)
[ "$startBranch" = "$MAIN_BRANCH" ] || git checkout "$startBranch" --quiet || true

success "Tag gepusht — GitHub Actions bouwt en publiceert de release nu."
echo "  Workflow-runs: https://github.com/${GITHUB_REPO}/actions"

# ─── Pollen op de release ──────────────────────────────────────────────────────
if [ "$haveGh" != true ]; then
    notice "'gh' niet gevonden — check de release handmatig via bovenstaande link."
    echo "Vergeet niet: ${MAIN_BRANCH} terug te mergen naar ${DEVELOP_BRANCH} (de workflow pusht updates.xml naar ${MAIN_BRANCH})."
    exit 0
fi

echo
info "Wachten tot de release zichtbaar is op GitHub (max $((pollTimeout / 60)) minuten)..."
elapsed=0
while [ "$elapsed" -lt "$pollTimeout" ]; do
    if releaseUrl=$(gh release view "v${version}" --repo "$GITHUB_REPO" --json url --jq .url 2>/dev/null); then
        echo
        success "Release v${version} staat op GitHub!"
        echo "  ${releaseUrl}"
        echo "Vergeet niet: ${MAIN_BRANCH} terug te mergen naar ${DEVELOP_BRANCH} (de workflow pusht updates.xml naar ${MAIN_BRANCH})."
        exit 0
    fi
    printf '.'
    sleep "$pollInterval"
    elapsed=$((elapsed + pollInterval))
done

echo
notice "Timeout: release nog niet gevonden na $((pollTimeout / 60)) minuten."
notice "Check de workflow-run handmatig: https://github.com/${GITHUB_REPO}/actions  (of: gh run list --repo ${GITHUB_REPO})"
exit 1
