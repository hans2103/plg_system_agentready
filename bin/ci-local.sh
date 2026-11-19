#!/bin/bash
#
# bin/ci-local.sh — draait lokaal dezelfde controles als de CI en zet bij succes een stempel.
#
# Lokaal = snelle terugkoppeling, CI = bron van waarheid. De stempel laat de pre-push hook
# (.githooks/pre-push) en de Claude-hook (bin/claude-pr-guard.sh) zien dat deze commit lokaal
# groen was, zodat een PR pas ready for review gaat (en de CI pas draait) als dat zo is.
#
# Gebruik: bash bin/ci-local.sh [--quick|--full] [-h|--help]
#          bash bin/ci-local.sh --check [commit]
#   (geen optie)  preflight, composer- en pnpm-scripts, extra commando's, shell-tests, testbuild,
#                 gitleaks (als geïnstalleerd) en de integratietests (als DDEV draait)
#   --quick       alleen preflight, `composer test` en `pnpm test`; zet geen stempel
#   --full        daarbij ook CI_FULL_COMPOSER_SCRIPTS (coverage, infection) en de integratietests
#                 verplicht: wat de release-workflow draait
#   --check       geen controles; exit 0 als er een geldige stempel is, anders 1. Zonder commit:
#                 voor HEAD, en alleen bij een schone werkboom. Met commit: voor die commit.
#
# De stempel staat in <git-common-dir>/ci-local/<commit> (gedeeld door alle worktrees) met de
# commit- en tree-hash. Hij wordt alleen gezet als de werkboom vóór en na de controles schoon is
# (ook geen ongevolgde bestanden) en HEAD niet is veranderd; hij geldt alleen zolang HEAD die
# commit is en de werkboom schoon blijft.
#
# Wat per repo verschilt staat in scripts.conf (CI_COMPOSER_SCRIPTS, CI_PNPM_SCRIPTS,
# CI_FULL_COMPOSER_SCRIPTS, CI_EXTRA_COMMANDS, CI_LOCAL_FILES, CI_INTEGRATION_*, DDEV_PROJECT).
# Ontbreken die, dan kiest het script veilige defaults: alleen scripts die composer.json of
# package.json kent, geen extra commando's en geen integratietests.
#
# Omgeving: CI_LOCAL_DB_NAME  databasenaam voor de integratietests (default:
#                             CI_INTEGRATION_DB_NAME + _<issue uit de branchnaam>)
#           PHP_BIN           php-binary (zie bin/_common.sh)
# Exitcodes: 0 groen (of geldige stempel), 1 een controle faalde (of geen stempel), 2 configuratie.
#
# BASH 3.2-COMPATIBEL (macOS): geen mapfile, geen `declare -A`, geen ${var,,}.
set -o pipefail

mode="standaard"
check_only=0
check_rev=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) mode="quick" ;;
        --full)  mode="full" ;;
        --check)
            check_only=1
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then check_rev="$2"; shift; fi
            ;;
        --help|-h) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Onbekend argument: $1 (zie --help)" >&2; exit 2 ;;
    esac
    shift
done

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$REPO_DIR" || exit 2

# ─── Stempel ────────────────────────────────────────────────────────────
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
[ -n "$common_dir" ] || common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
stamp_dir="$common_dir/ci-local"

tree_clean() { [ -z "$(git status --porcelain 2>/dev/null)" ]; }

# Geldige stempel voor commit $1 (volledige hash): het bestand bestaat en commit en tree kloppen.
stamp_valid() {
    local sha="$1" file="$stamp_dir/$1" tree
    [ -f "$file" ] || return 1
    tree="$(git rev-parse --verify --quiet "$sha^{tree}")" || return 1
    grep -qx "commit=$sha" "$file" && grep -qx "tree=$tree" "$file"
}

if [ "$check_only" -eq 1 ]; then
    if [ -z "$check_rev" ]; then
        tree_clean || exit 1
        check_rev="HEAD"
    fi
    sha="$(git rev-parse --verify --quiet "$check_rev^{commit}")" || exit 1
    stamp_valid "$sha" && exit 0
    exit 1
fi

# ─── Configuratie en defaults ───────────────────────────────────────────
is_declared() { declare -p "$1" > /dev/null 2>&1; }

# Scriptnamen uit composer.json (scripts) of package.json (scripts). $1 = bestand.
json_scripts() {
    [ -f "$1" ] || return 0
    "$PHP_BIN" -r '$d = json_decode((string) file_get_contents($argv[1]), true); foreach (array_keys($d["scripts"] ?? []) as $k) { echo $k, "\n"; }' "$1" 2>/dev/null
}
composer_known="$(json_scripts composer.json)"
pnpm_known="$(json_scripts package.json)"
known() { printf '%s\n' "$2" | grep -qxF -e "$1"; }

# Vult array $1 met de scripts uit de lijst $3… die in $2 (bekende scripts) staan.
pick_known() {
    local name="$1" have="$2" s out=()
    shift 2
    for s in "$@"; do known "$s" "$have" && out+=("$s"); done
    eval "$name=(\"\${out[@]}\")"
}
is_declared CI_COMPOSER_SCRIPTS || pick_known CI_COMPOSER_SCRIPTS "$composer_known" test analyse analyse-library phpmd metrics cs-check
is_declared CI_PNPM_SCRIPTS || pick_known CI_PNPM_SCRIPTS "$pnpm_known" lint:js test jscpd check:taal check:licenties
is_declared CI_FULL_COMPOSER_SCRIPTS || pick_known CI_FULL_COMPOSER_SCRIPTS "$composer_known" coverage infection
is_declared CI_EXTRA_COMMANDS || CI_EXTRA_COMMANDS=()
is_declared CI_LOCAL_FILES || CI_LOCAL_FILES=()
: "${CI_INTEGRATION_SCRIPT:=}"
: "${CI_INTEGRATION_DB_ENV:=}"
: "${CI_INTEGRATION_DB_NAME:=}"
: "${DDEV_PROJECT:=}"

# ─── Stappen ────────────────────────────────────────────────────────────
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-local.XXXXXX")"
n_step=0; n_fail=0; n_skip=0; failed_steps=""

# step label commando… — draait het commando met de uitvoer in een logbestand.
step() {
    local label="$1" log start rc
    shift
    n_step=$((n_step + 1))
    log="$log_dir/$(printf '%02d' "$n_step").log"
    start=$SECONDS
    printf '%s… ' "$label"
    "$@" > "$log" 2>&1 < /dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%sOK%s %s(%ss)%s\n' "$C_OK" "$C_0" "$C_D" "$((SECONDS - start))" "$C_0"
    else
        printf '%sFOUT%s (exit %s, %ss)\n' "$C_F" "$C_0" "$rc" "$((SECONDS - start))"
        tail -n 30 "$log" | sed "s/^/${C_D}    /;s/\$/${C_0}/"
        printf '    %svolledige uitvoer: %s%s\n' "$C_D" "$log" "$C_0"
        n_fail=$((n_fail + 1))
        failed_steps="$failed_steps
  - $label"
    fi
}
skip() { n_skip=$((n_skip + 1)); printf '%s… %sovergeslagen%s (%s)\n' "$1" "$C_W" "$C_0" "$2"; }

head_at_start="$(git rev-parse HEAD 2>/dev/null)"
clean_at_start=0
tree_clean && clean_at_start=1

info "bin/ci-local.sh — modus: $mode, commit ${head_at_start:0:12}"
[ "$clean_at_start" -eq 1 ] || notice "Werkboom niet schoon: de controles draaien, maar er komt geen stempel."

# Gitignored bestanden die een worktree mist (bijv. phpstan.neon) uit de hoofdcheckout.
main_checkout="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
for f in "${CI_LOCAL_FILES[@]}"; do
    [ -n "$f" ] && [ ! -e "$f" ] || continue
    if [ -n "$main_checkout" ] && [ "$main_checkout" != "$REPO_DIR" ] && [ -f "$main_checkout/$f" ]; then
        cp "$main_checkout/$f" "$f" && notice "$f overgenomen uit $main_checkout"
    fi
done

# Afhankelijkheden: alleen installeren als ze ontbreken.
if [ -f composer.json ] && [ ! -d vendor ]; then
    step "composer install" composer install --no-interaction --no-progress
fi
if [ -f package.json ] && [ ! -d node_modules ]; then
    step "pnpm install" pnpm install --frozen-lockfile
fi

# Preflight: de changeset, en lint + conflictmarkers over de hele repo (zoals Validate).
if [ -f bin/preflight.sh ]; then
    step "preflight" bash bin/preflight.sh -q
    [ "$mode" = "quick" ] || step "preflight (PHP-lint hele repo)" bash bin/preflight.sh -q --all --only 1,9
fi

if [ "$mode" = "quick" ]; then
    composer_run=(); pnpm_run=()
    for s in "${CI_COMPOSER_SCRIPTS[@]}"; do [ "$s" = "test" ] && composer_run+=("$s"); done
    for s in "${CI_PNPM_SCRIPTS[@]}"; do [ "$s" = "test" ] && pnpm_run+=("$s"); done
else
    composer_run=("${CI_COMPOSER_SCRIPTS[@]}")
    pnpm_run=("${CI_PNPM_SCRIPTS[@]}")
    [ "$mode" = "full" ] && composer_run+=("${CI_FULL_COMPOSER_SCRIPTS[@]}")
fi

for s in "${composer_run[@]}"; do [ -n "$s" ] && step "composer $s" composer run-script --no-interaction "$s"; done
for s in "${pnpm_run[@]}"; do [ -n "$s" ] && step "pnpm $s" pnpm run "$s"; done

if [ "$mode" != "quick" ]; then
    [ -f composer.lock ] && step "composer audit" composer audit --locked --no-interaction
    for c in "${CI_EXTRA_COMMANDS[@]}"; do [ -n "$c" ] && step "$c" bash -c "$c"; done
    [ -f tests/shell/run-all.sh ] && step "shell-tests" bash tests/shell/run-all.sh
    [ -f package.sh ] && step "testbuild (package.sh)" bash package.sh

    # gitleaks op de commits van deze branch (zoals Bewaking: base..HEAD).
    if command -v gitleaks > /dev/null 2>&1; then
        base=""
        for ref in "origin/$DEVELOP_BRANCH" "$DEVELOP_BRANCH"; do
            git rev-parse --verify --quiet "$ref" > /dev/null && { base="$(git merge-base HEAD "$ref" 2>/dev/null)"; break; }
        done
        if [ -z "$base" ] || [ "$base" = "$head_at_start" ]; then
            skip "gitleaks" "geen eigen commits t.o.v. $DEVELOP_BRANCH"
        else
            gl_args=(git --no-banner --redact --log-opts="$base..HEAD")
            [ -f .gitleaks.toml ] && gl_args+=(--config .gitleaks.toml)
            step "gitleaks" gitleaks "${gl_args[@]}" .
        fi
    else
        skip "gitleaks" "niet geïnstalleerd (brew install gitleaks)"
    fi

    # Integratietests tegen de database van een draaiende DDEV-site, in een eigen tijdelijke DB.
    if [ -z "$CI_INTEGRATION_SCRIPT" ] || ! known "$CI_INTEGRATION_SCRIPT" "$composer_known"; then
        [ -z "$CI_INTEGRATION_SCRIPT" ] || skip "integratietests" "composer-script $CI_INTEGRATION_SCRIPT bestaat niet"
    else
        db_port=""
        if [ -n "$DDEV_PROJECT" ] && command -v ddev > /dev/null 2>&1; then
            db_port="$(ddev describe "$DDEV_PROJECT" -j 2>/dev/null | "$PHP_BIN" -r '$d = json_decode((string) stream_get_contents(STDIN), true); $r = $d["raw"] ?? []; if (($r["status"] ?? "") === "running") { echo (int) ($r["dbinfo"]["published_port"] ?? 0) ?: ""; }' 2>/dev/null)"
        fi
        if [ -z "$db_port" ]; then
            if [ "$mode" = "full" ]; then
                n_fail=$((n_fail + 1)); failed_steps="$failed_steps
  - integratietests (DDEV-project '${DDEV_PROJECT}' draait niet; --full vereist ze)"
                printf 'integratietests… %sFOUT%s (DDEV-project %s draait niet)\n' "$C_F" "$C_0" "${DDEV_PROJECT:-<geen>}"
            else
                skip "integratietests" "DDEV-project '${DDEV_PROJECT:-<geen>}' draait niet; start met: ddev start ${DDEV_PROJECT}"
            fi
        else
            db_name="${CI_LOCAL_DB_NAME:-}"
            if [ -z "$db_name" ]; then
                issue="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed -nE 's#^[A-Za-z]+/([0-9]+)-.*#\1#p')"
                db_name="${CI_INTEGRATION_DB_NAME}_${issue:-local}"
            fi
            p="$CI_INTEGRATION_DB_ENV"
            step "integratietests (DB $db_name, poort $db_port)" env "${p}_HOST=127.0.0.1" "${p}_PORT=$db_port" "${p}_NAME=$db_name" "${p}_DROP=1" "${p}_REQUIRED=1" composer run-script --no-interaction "$CI_INTEGRATION_SCRIPT"
        fi
    fi
fi

# ─── Uitkomst en stempel ────────────────────────────────────────────────
echo ""
if [ "$n_fail" -gt 0 ]; then
    printf '%s%d van %d stap(pen) gefaald:%s%s\n' "$C_F" "$n_fail" "$n_step" "$failed_steps" "$C_0"
    echo "Geen stempel. Exit code 1."
    exit 1
fi
success "Alle $n_step stap(pen) groen ($n_skip overgeslagen)."
rm -rf "$log_dir"

if [ "$mode" = "quick" ]; then
    echo "Geen stempel bij --quick; draai bash bin/ci-local.sh voor gh pr ready of een push."
    exit 0
fi
if [ "$clean_at_start" -ne 1 ] || ! tree_clean || [ "$(git rev-parse HEAD)" != "$head_at_start" ]; then
    notice "Geen stempel: de werkboom was niet schoon of HEAD is veranderd. Commit en draai opnieuw."
    exit 0
fi
mkdir -p "$stamp_dir"
find "$stamp_dir" -type f -mtime +30 -delete 2>/dev/null || true
{
    echo "commit=$head_at_start"
    echo "tree=$(git rev-parse "$head_at_start^{tree}")"
    echo "mode=$mode"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "skipped=$n_skip"
} > "$stamp_dir/$head_at_start"
success "Stempel gezet voor ${head_at_start:0:12} ($stamp_dir/$head_at_start)."
exit 0
