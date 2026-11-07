#!/bin/bash
#
# bin/preflight.sh — de controles die het waard zijn vóór een commit/PR, als één exitcode.
#
# Leest en beoordeelt; wijzigt NIETS (geen commit, geen push, alleen stdout).
# Drie uitkomsten per controle: OK / WARNING (menselijk oordeel, nooit een gate) /
# ERROR (zet de exitcode op 1).
# Exitcodes: 0 schoon, 1 minstens één ERROR, 2 configuratieprobleem (geen git-repo,
# scripts.conf ontbreekt of ongeldige opties).
#
# Gebruik: ./bin/preflight.sh [-q|--quiet] [-a|--all] [-o N[,N...]|--only N[,N...]] [-h|--help]
#   -q/--quiet  alleen WARNING en ERROR tonen
#   -a/--all    de hygiënecontroles (1, 2, 6, 9-12, 15) op de hele repo i.p.v. alleen de changeset
#   -o/--only   alleen de genoemde controles draaien (bijv. -o 3,4)
#
# Controles (ERROR blokkeert, WARNING is informatief):
#    1 PHP-lint (ERROR)                       8 Package-lekkage (WARNING)
#    2 SQL-migraties (ERROR + WARNING)        9 Merge-conflictmarkers (ERROR)
#    3 Manifests: XML + dekking (ERROR)      10 Hardgecodeerde home-paden (WARNING)
#    4 Versies gelijk (ERROR)                11 Geheimen (WARNING)
#    5 Commit-msg hook actief (WARNING)      12 AIdocs-dekking van de changeset (flavour ronny)
#    6 Debug-resten (WARNING)                13 Ronny (flavour ronny)
#    7 Lengtegrenzen (scripts.conf)          14 AIdocs-structuur en -dekking (flavour structure)
#                                            15 strict_types in PHP-klassebestanden (WARNING)
# De nummers zijn stabiel: docs verwijzen ernaar. Nieuwe controles komen achteraan.
# Controles 12-14 horen bij een AIdocs-werkwijze (AIDOCS_FLAVOUR in scripts.conf); hoort een controle niet bij
# de gekozen werkwijze, dan toont hij een OK-regel "n.v.t.", zodat elke repo dezelfde lijst 1-15 laat zien.
#
# Omgeving: PHP_BIN       php-binary voor lint en de PHP-scripts (default: php uit PATH)
#           RONNY_SCRIPT  pad naar check-drift.sh voor controle 13
#                         (default: .claude/skills/ronny/scripts/check-drift.sh)
#
# Alles wat per repo verschilt (manifests, versies, AIdocs-flavour, uitsluitingen) staat in
# scripts.conf; controles 12 en 13 lezen daarnaast ronny.conf.
#
# BASH 3.2-COMPATIBEL (macOS): geen mapfile, geen `declare -A`, geen ${var,,}.
set -eo pipefail

# ─── CLI ────────────────────────────────────────────────────────────────
quiet=0
scan_all=0
only_checks=""
set_only() {
    [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "Ongeldige waarde voor --only: '$1' (verwacht bijv. 3,4)" >&2; exit 2; }
    only_checks="$(printf '%s' "$1" | tr ',' ' ')"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet|-q) quiet=1 ;;
        --all|-a)   scan_all=1 ;;
        --only=*)   set_only "${1#--only=}" ;;
        --only|-o)  [ $# -ge 2 ] || { echo "Waarde ontbreekt voor $1 (bijv. $1 3,4)" >&2; exit 2; }; shift; set_only "$1" ;;
        --help|-h)  sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "Onbekend argument: $1 (zie --help)" >&2; exit 2 ;;
    esac
    shift
done

# shellcheck source=bin/_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
cd "$REPO_DIR"

n_ok=0; n_warning=0; n_error=0

# Deze tellen in de HUIDIGE shell; nooit in een pipeline of $( ) aanroepen.
ok()      { n_ok=$((n_ok + 1)); [ "$quiet" -eq 0 ] && printf '%sOK       %s%s\n' "$C_OK" "$*" "$C_0" || true; }
warning() { n_warning=$((n_warning + 1)); printf '%sWARNING  %s%s\n' "$C_W" "$*" "$C_0"; }
error()   { n_error=$((n_error + 1)); printf '%sERROR    %s%s\n' "$C_F" "$*" "$C_0"; }
say()     { [ "$quiet" -eq 0 ] && printf '%s\n' "$*" || true; }
list()    { printf '%s\n' "$1" | grep -v '^$' | sed "s/^/${C_D}    /;s/\$/${C_0}/" || true; }

should_run() {
    [ -z "$only_checks" ] && return 0
    case " $only_checks " in *" $1 "*) return 0 ;; esac
    return 1
}

# ══════════════════════════════════════════════════════════════════════
# DEEL A — de scope: de changeset (commits t.o.v. develop + working tree) of, met --all, de hele repo
# ══════════════════════════════════════════════════════════════════════
base_ref="origin/$DEVELOP_BRANCH"
git rev-parse --verify --quiet "$base_ref" >/dev/null || base_ref="$DEVELOP_BRANCH"
base=""
git rev-parse --verify --quiet "$base_ref" >/dev/null && base="$(git merge-base HEAD "$base_ref" 2>/dev/null || echo '')"

if [ "$scan_all" -eq 1 ]; then
    SET="$(git -c core.quotepath=false ls-files --cached --others --exclude-standard | sort -u || true)"
else
    commit_paths=""
    [ -n "$base" ] && commit_paths="$(git diff --name-only "$base..HEAD" 2>/dev/null || true)"
    # -uall: elk nieuw bestand apart, niet de map als geheel; anders wordt een volledig nieuwe map nooit gelint of gescand.
    tree_paths="$(git -c core.quotepath=false status --porcelain -uall 2>/dev/null | sed -e 's/^...//' -e 's/^.* -> //' -e 's/^"\(.*\)"$/\1/' || true)"
    SET="$(printf '%s\n%s\n' "$commit_paths" "$tree_paths" | grep -v '^$' | sort -u || true)"
fi
# Code van derden wordt nooit gelint of gescand.
SET="$(printf '%s\n' "$SET" | grep -vE '(^|/)vendor/' || true)"

say "${C_D}bin/preflight.sh — controles vóór een commit/PR${C_0}"
say "Repo:   $REPO_DIR"
say "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')  (base: $base_ref)"
if [ "$scan_all" -eq 1 ]; then
    say "Scope:  hele repo (--all), $(printf '%s\n' "$SET" | grep -c . || true) bestand(en)"
else
    say "Changeset: $(printf '%s\n' "$SET" | grep -c . || true) bestand(en)"
fi
say ""

# Valt $1 onder een SCAN_EXCLUDE-prefix?
scan_excluded() {
    local p
    for p in "${SCAN_EXCLUDE[@]}"; do
        case "$1" in "$p"*) return 0 ;; esac
    done
    return 1
}

# Geef "bestand:\n  regel" blokken voor bestanden in de scope die de regex bevatten.
# $1 = regex (ERE), $2 = spatie-gescheiden extensies (leeg = alle)
hits() {
    local regex="$1" exts="$2" f found out=""
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        scan_excluded "$f" && continue
        if [ -n "$exts" ]; then
            case " $exts " in *" ${f##*.} "*) : ;; *) continue ;; esac
        fi
        found="$(grep -nEI -e "$regex" "$f" 2>/dev/null || true)"
        if [ -n "$found" ]; then
            out="$out
$f:
$(printf '%s' "$found" | sed 's/^/  /')"
        fi
    done < <(printf '%s\n' "$SET")
    printf '%s' "$out"
}

# Gedeeld: ronny.conf (modulepaden en AIdocs-map) voor controles 12 en 13.
if [ -f ronny.conf ]; then
    # shellcheck disable=SC1091
    source ronny.conf
else
    AIDOCS_DIR="AIdocs"
    MODULE_GLOBS=()
    SCAN_IGNORE=()
fi
: "${AIDOCS_DIR:=AIdocs}"   # ook een ronny.conf zonder AIDOCS_DIR krijgt de default

# Een bestand valt onder een modulepad als het een MODULE_GLOB matcht (een `*` in [[ ]]
# matcht ook `/`) of onder een glob ligt zonder wildcard (Src/media/com_kwekfestijn).
in_module_scope() {
    local f="$1" g in_module=0
    for g in "${MODULE_GLOBS[@]}"; do
        if [[ "$f" == $g || "$f" == $g/* ]]; then in_module=1; break; fi
    done
    [ "$in_module" -eq 1 ] || return 1
    for g in "${SCAN_IGNORE[@]}"; do
        case "$f" in "$g"|"$g"/*) return 1 ;; esac
    done
    return 0
}

# Staat $1 in de scope? Here-string i.p.v. pipe: onder pipefail geeft `grep -q`
# op een grote SET anders een vals negatief door SIGPIPE.
in_set() {
    grep -qxF -e "$1" <<< "${SET_FILES:-$SET}"
}

# ══════════════════════════════════════════════════════════════════════
# DEEL B — de controles
# ══════════════════════════════════════════════════════════════════════

# 1. LINT (ERROR): php -l op .php-bestanden in de scope, via stdin (nooit een pad).
if should_run 1; then
    lint_count=0; lint_errors=0
    if ! command -v "$PHP_BIN" >/dev/null 2>&1; then
        error "1. Lint — geen php-binary gevonden (zet PHP_BIN)"
    else
        while IFS= read -r f; do
            case "$f" in *.php) : ;; *) continue ;; esac
            [ -f "$f" ] || continue
            lint_count=$((lint_count + 1))
            if ! out="$("$PHP_BIN" -l < "$f" 2>&1)"; then
                error "1. Lint — $f"; list "$out"; lint_errors=$((lint_errors + 1))
            fi
        done < <(printf '%s\n' "$SET")
        [ "$lint_errors" -eq 0 ] && ok "1. Lint — $lint_count bestand(en) schoon [$("$PHP_BIN" -r 'echo PHP_VERSION;')]"
    fi
fi

# 2. SQL-MIGRATIES (ERROR + WARNING): naam, header, #__-prefix, idempotentie.
#    Alleen sql/migrations/*.sql (niet applied/, niet *.example).
if should_run 2; then
    m_count=0; m_errors=0
    while IFS= read -r f; do
        case "$f" in sql/migrations/*.sql) : ;; *) continue ;; esac
        case "$f" in sql/migrations/applied/*) continue ;; esac
        [ -f "$f" ] || continue
        m_count=$((m_count + 1))
        problems=""
        printf '%s' "$(basename "$f")" | grep -qE '^[0-9]+_[0-9]{8}_[0-9]{6}_[a-z0-9_]+\.sql$' \
            || problems="$problems
naam voldoet niet aan {issue}_{JJJJMMDD}_{UUMMSS}_{omschrijving}.sql (omschrijving in kleine letters)"
        grep -qE '^-- ?Issue: ?#[0-9]+' "$f" || problems="$problems
header-regel ontbreekt: -- Issue: #123"
        for h in Auteur Omschrijving; do
            grep -qE "^-- ?${h}:" "$f" || problems="$problems
header-regel ontbreekt: -- ${h}:"
        done
        grep -q '#__' "$f" || problems="$problems
geen #__-tabelprefix gevonden"
        bad_prefix="$(grep -nE "\`[A-Za-z0-9]*_?${PROJECT_NAME}_[A-Za-z_]+\`" "$f" || true)"
        [ -z "$bad_prefix" ] || problems="$problems
tabelnaam zonder #__-prefix (nooit de echte prefix gebruiken):
$(printf '%s' "$bad_prefix" | sed 's/^/  /')"
        # ALTER TABLE … ADD/DROP … IF [NOT] EXISTS: MySQL kent het niet (alleen MariaDB) en Joomla's
        # databasecontrole leest dan 'IF' als kolom- of indexnaam. Gebruik /** CAN FAIL **/.
        if_exists="$(grep -niE '(add|drop)[[:space:]]+(column|key|index|unique)[[:space:]]+if[[:space:]]+(not[[:space:]]+)?exists' "$f" | grep -vE '^[0-9]+:[[:space:]]*--' || true)"
        [ -z "$if_exists" ] || problems="$problems
IF [NOT] EXISTS in ALTER TABLE (MySQL kent het niet; Joomla meldt kolom 'IF'). Schrijf:
  ALTER TABLE \`#__…\` ADD COLUMN \`naam\` … /** CAN FAIL **/;
$(printf '%s' "$if_exists" | sed 's/^/  /')"
        if [ -n "$problems" ]; then
            error "2. SQL-migraties — $f"; list "$problems"; m_errors=$((m_errors + 1))
        fi
        # Idempotent: CREATE TABLE IF NOT EXISTS, en elke ALTER TABLE … ADD/DROP als één regel met
        # /** CAN FAIL **/ aan het eind (zo doet Joomla het zelf; run-migrations.sh draait die regel los).
        not_idempotent="$( {
            grep -niE '^[[:space:]]*create table' "$f" | grep -viE 'if not exists'
            grep -niE '^[[:space:]]*alter table .*[[:space:]](add|drop)[[:space:]]' "$f" | grep -vF '/** CAN FAIL **/;'
            grep -niE '^[[:space:]]*(add|drop)[[:space:]]' "$f"
        } | sort -n -t: -k1,1 || true)"
        if [ -n "$not_idempotent" ]; then
            warning "2. SQL-migraties — $f: niet idempotent (CREATE TABLE IF NOT EXISTS; per ADD/DROP één regel ALTER TABLE … /** CAN FAIL **/;)"; list "$not_idempotent"
        fi
    done < <(printf '%s\n' "$SET")
    if [ "$m_count" -eq 0 ]; then ok "2. SQL-migraties — n.v.t., geen nieuwe/gewijzigde sql/migrations/*.sql"
    elif [ "$m_errors" -eq 0 ]; then ok "2. SQL-migraties — $m_count bestand(en) in orde"; fi
fi

# 3. MANIFESTS (ERROR): geldige XML, en <files>/<media> gelijk aan de schijf. Altijd de hele
#    repo, ook zonder --all: dit zijn structuurcontroles, geen changeset-hygiëne.
if should_run 3; then
    xml_bad=""
    if ! command -v xmllint >/dev/null 2>&1; then
        warning "3. Manifests — xmllint niet gevonden, XML-validatie overgeslagen"
    else
        while IFS= read -r f; do
            [ -n "$f" ] && [ -f "$f" ] || continue
            xmllint --noout "$f" 2>/dev/null || xml_bad="$xml_bad
ongeldige XML: $f"
        done < <({ printf '%s\n' package.xml "$UPDATES_XML"; git ls-files --cached --others --exclude-standard -- "$SRC_DIR" | grep '\.xml$' | grep -vE '(^|/)vendor/'; } | sort -u)
        [ -z "$xml_bad" ] || { error "3. Manifests — XML"; list "$xml_bad"; }
    fi
    if [ "${#EXTENSION_MANIFESTS[@]}" -eq 0 ]; then
        ok "3. Manifests — n.v.t., geen EXTENSION_MANIFESTS in scripts.conf"
    elif manifest_out="$("$PHP_BIN" bin/check-manifests.php --src="$SRC_DIR" "${EXTENSION_MANIFESTS[@]}" 2>&1)"; then
        [ -n "$xml_bad" ] || ok "3. Manifests — XML geldig en manifests komen overeen met de schijf"
    else
        error "3. Manifests — manifest en schijf lopen uiteen"; list "$manifest_out"
    fi
fi

# 4. VERSIES (ERROR): package.xml, de VERSIONED_MANIFESTS en VERSIONED_JSON gelijk.
#    package.sh stempelt ze bij een release allemaal tegelijk; een verschil is dus altijd een fout.
if should_run 4; then
    v_pkg="$(manifest_version package.xml)"
    v_bad=""; v_count=1
    if [ -z "$v_pkg" ]; then
        v_bad="package.xml: geen <version> gevonden"
    else
        for f in "${VERSIONED_MANIFESTS[@]}"; do
            v_count=$((v_count + 1))
            if [ ! -f "$f" ]; then v_bad="$v_bad
$f: ontbreekt"; continue; fi
            v="$(manifest_version "$f")"
            [ "$v" = "$v_pkg" ] || v_bad="$v_bad
$f: versie '$v', package.xml heeft '$v_pkg'"
        done
        for f in "${VERSIONED_JSON[@]}"; do
            v_count=$((v_count + 1))
            if [ ! -f "$f" ]; then v_bad="$v_bad
$f: ontbreekt"; continue; fi
            v="$(grep -m1 '"version"' "$f" | sed -E 's#.*"version": *"([^"]*)".*#\1#')"
            [ "$v" = "$v_pkg" ] || v_bad="$v_bad
$f: versie '$v', package.xml heeft '$v_pkg'"
        done
    fi
    if [ -n "$v_bad" ]; then error "4. Versies — lopen uiteen (package.sh trekt ze bij de release gelijk, maar ze horen nu al gelijk te zijn)"; list "$v_bad"
    else ok "4. Versies — package.xml en $((v_count - 1)) manifest(s)/JSON-bestand(en) staan alle op $v_pkg"; fi
fi

# 5. COMMIT-MSG HOOK (WARNING)
if should_run 5; then
    hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
    if [ "$hooks_path" = ".githooks" ]; then ok "5. Commit-msg hook — core.hooksPath is .githooks"
    else warning "5. Commit-msg hook — core.hooksPath is '${hooks_path:-<niet gezet>}'; draai: git config core.hooksPath .githooks"; fi
fi

# 6. DEBUG-RESTEN (WARNING)
if should_run 6; then
    dbg="$(hits 'var_dump\(|print_r\(|(^|[^A-Za-z_>:$])dd\(' 'php')$(hits 'console\.log\(' 'js')"
    if [ -n "$dbg" ]; then warning "6. Debug-resten — var_dump/print_r/dd/console.log gevonden"; list "$dbg"
    else ok "6. Debug-resten — geen gevonden in de scope"; fi
fi

# 7. LENGTEGRENZEN (ERROR of WARNING, LENGTH_LIMIT_SEVERITY in scripts.conf): CLAUDE.md, elke
#    CLAUDE.md-verwijzing onder $SRC_DIR (niet in vendor/) en elke pagina in $AIDOCS_DIR mogen
#    maximaal 200 regels hebben. Draait op de hele repo, niet alleen op de changeset.
if should_run 7; then
    length_bad=0
    if [ ! -f CLAUDE.md ]; then
        warning "7. Lengtegrenzen — CLAUDE.md niet gevonden"
        length_bad=1
    fi
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        lines="$(awk 'END { print NR }' "$f")"
        if [ "$lines" -gt 200 ]; then
            length_bad=1
            if [ "$LENGTH_LIMIT_SEVERITY" = "ERROR" ]; then error "7. Lengtegrenzen — $f is $lines regels (limiet 200)"
            else warning "7. Lengtegrenzen — $f is $lines regels (limiet 200)"; fi
        fi
    done < <({ [ -f CLAUDE.md ] && echo CLAUDE.md; [ -d "$SRC_DIR" ] && find "$SRC_DIR" -name CLAUDE.md -not -path '*/vendor/*'; [ -d "$AIDOCS_DIR" ] && find "$AIDOCS_DIR" -name '*.md'; } | sort)
    if [ "$length_bad" -eq 0 ]; then ok "7. Lengtegrenzen — CLAUDE.md, verwijzingen en AIdocs-pagina's onder de limiet van 200"; fi
fi

# 8. PACKAGE-LEKKAGE (WARNING): package.sh zipt van schijf, niet uit git, en sluit uit met de
#    patronen in .deployignore. Twee kanten op:
#      a. een genegeerd bestand onder Src/ dat niet door .deployignore wordt uitgesloten
#         belandt in de ZIP;
#      b. een gevolgd bestand onder Src/ dat wel door een patroon wordt uitgesloten (CLAUDE.md-
#         verwijzingen zijn bewust uitgesloten en tellen niet mee) komt juist niet in de ZIP.
if should_run 8; then
    if [ ! -f .deployignore ]; then
        warning "8. Package-lekkage — .deployignore ontbreekt"
    else
        deploy_patterns=()
        while IFS= read -r pat || [ -n "$pat" ]; do
            pat=${pat%$'\r'}
            case "$pat" in ''|'#'*) continue ;; esac
            deploy_patterns+=("$pat")
        done < .deployignore

        is_excluded() {
            local pat
            for pat in "${deploy_patterns[@]}"; do
                # shellcheck disable=SC2254
                case "$1" in $pat) return 0 ;; esac
            done
            return 1
        }

        leaks=""; lost=""
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            is_excluded "$f" || leaks="$leaks
$f"
        done < <(git ls-files --others --ignored --exclude-standard -- "$SRC_DIR" 2>/dev/null || true)
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ "$(basename "$f")" = "CLAUDE.md" ] && continue
            is_excluded "$f" && lost="$lost
$f"
        done < <(git ls-files "$SRC_DIR" 2>/dev/null || true)

        if [ -n "$leaks" ]; then warning "8. Package-lekkage — genegeerde bestanden onder $SRC_DIR/ die niet in .deployignore staan"; list "$leaks"; fi
        if [ -n "$lost" ]; then warning "8. Package-lekkage — gevolgde bestanden onder $SRC_DIR/ die .deployignore uitsluit (ze komen niet in de ZIP)"; list "$lost"; fi
        if [ -z "$leaks" ] && [ -z "$lost" ]; then ok "8. Package-lekkage — .deployignore sluit precies uit wat hoort"; fi
    fi
fi

# 9. MERGE-CONFLICTMARKERS (ERROR)
if should_run 9; then
    cm="$(hits '^<{7}( |$)|^={7}$|^>{7}( |$)' '')"
    if [ -n "$cm" ]; then error "9. Merge-conflictmarkers — onopgeloste marker(s) gevonden"; list "$cm"
    else ok "9. Merge-conflictmarkers — geen gevonden in de scope"; fi
fi

# 10. HARDCODED HOME-PADEN (WARNING): gebruik $HOME, nooit het pad van één developer.
if should_run 10; then
    hp="$(hits '/Use''rs/[A-Za-z][A-Za-z0-9_.-]*' '')"
    if [ -n "$hp" ]; then warning "10. Home-paden — letterlijk gebruikerspad gevonden (gebruik \$HOME)"; list "$hp"
    else ok "10. Home-paden — geen gevonden in de scope"; fi
fi

# 11. GEHEIMEN (WARNING): heuristiek — private-key-header, AWS-key-id, GitHub-token,
#     letterlijke wachtwoordtoekenning.
if should_run 11; then
    sec="$(hits '-----BEGIN ''((RSA|EC|OPENSSH|DSA) )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|(password|passwd|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9!@#$%^&*()_+=-]{8,}["'"'"']' '')"
    if [ -n "$sec" ]; then warning "11. Geheimen — mogelijke credential-literal gevonden"; list "$sec"
    else ok "11. Geheimen — geen credential-literal gevonden in de scope"; fi
fi

# 12. AIDOCS-DEKKING VAN DE CHANGESET (ERROR + WARNING) — alleen bij AIDOCS_FLAVOUR=ronny
#     Bestand in een modulepad dat in geen enkele Covers-regel staat -> ERROR.
#     Wel gedekt, maar de pagina is niet mee veranderd in deze changeset -> WARNING
#     (kan een wijziging zijn die het gedocumenteerde gedrag niet raakt; mensenwerk).
if should_run 12 && [ "$AIDOCS_FLAVOUR" != "ronny" ]; then ok "12. AIdocs-dekking — n.v.t. voor AIDOCS_FLAVOUR='${AIDOCS_FLAVOUR}' (alleen bij ronny)"; fi
if should_run 12 && [ "$AIDOCS_FLAVOUR" = "ronny" ]; then
    covers_map=""
    if [ -d "$AIDOCS_DIR" ]; then
        while IFS= read -r page; do
            [ -f "$page" ] || continue
            block="$(awk '
/^Covers:/ { grab=1; sub(/^Covers:[ \t]*/, ""); printf "%s", $0; next }
grab && NF==0 { exit }
grab { printf " %s", $0 }
' "$page")"
            [ -n "$block" ] || continue
            old_ifs="$IFS"
            IFS=','
            for part in $block; do
                IFS="$old_ifs"
                part="$(printf '%s' "$part" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                [ -n "$part" ] || continue
                covers_map="$covers_map
$part|$page"
            done
            IFS="$old_ifs"
        done < <(find "$AIDOCS_DIR" -name "*.md")
    fi
    covers_map="$(printf '%s\n' "$covers_map" | grep -v '^$' || true)"

    matched_pages() {
        local f="$1" cpath cpage
        while IFS='|' read -r cpath cpage; do
            [ -n "$cpath" ] || continue
            if [[ "$f" == $cpath || "$f" == "$cpath"/* ]]; then
                echo "$cpage"
            fi
        done <<< "$covers_map" | sort -u
    }

    # git status meldt een nieuwe, ongetrackte map als één regel (map/); klap die uit naar
    # bestanden (zonder wat .gitignore uitsluit), anders ontsnapt een volledig nieuwe
    # extensie aan deze controle.
    SET_FILES="$(while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -d "$f" ]; then git -c core.quotepath=false ls-files --others --exclude-standard -- "$f"; else printf '%s\n' "$f"; fi
    done <<< "$SET" | sort -u)"

    covers_errors=0; covers_warnings=0; covers_checked=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        in_module_scope "$f" || continue
        covers_checked=$((covers_checked + 1))
        pages="$(matched_pages "$f")"
        if [ -z "$pages" ]; then
            error "12. AIdocs-dekking — $f staat in geen enkele Covers-regel"
            covers_errors=$((covers_errors + 1))
            continue
        fi
        moved=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if in_set "$p"; then moved=1; fi
        done <<< "$pages"
        if [ "$moved" -eq 0 ]; then
            warning "12. AIdocs-dekking — $f is gewijzigd, maar $(printf '%s' "$pages" | tr '\n' ' ' | sed 's/ *$//') niet"
            covers_warnings=$((covers_warnings + 1))
        fi
    done < <(printf '%s\n' "$SET_FILES")

    if [ "$covers_errors" -eq 0 ] && [ "$covers_warnings" -eq 0 ]; then
        if [ "$covers_checked" -eq 0 ]; then ok "12. AIdocs-dekking — n.v.t., geen bestand onder een modulepad in de scope"
        else ok "12. AIdocs-dekking — $covers_checked bestand(en) gedekt, hun pagina('s) zijn mee veranderd"; fi
    fi
fi

# 13. RONNY (ERROR bij drift, WARNING als het script ontbreekt) — alleen bij AIDOCS_FLAVOUR=ronny
if should_run 13 && [ "$AIDOCS_FLAVOUR" != "ronny" ]; then ok "13. Ronny — n.v.t. voor AIDOCS_FLAVOUR='${AIDOCS_FLAVOUR}' (alleen bij ronny)"; fi
if should_run 13 && [ "$AIDOCS_FLAVOUR" = "ronny" ]; then
    ronny=""; ronny_source=""
    if [ -n "${RONNY_SCRIPT:-}" ] && [ -x "${RONNY_SCRIPT}" ]; then
        ronny="$RONNY_SCRIPT"; ronny_source="\$RONNY_SCRIPT"
    elif [ -x .claude/skills/ronny/scripts/check-drift.sh ]; then
        ronny=".claude/skills/ronny/scripts/check-drift.sh"; ronny_source="repo (.claude/skills/ronny)"
    else
        candidate="$(ls -d "$HOME"/.claude/plugins/cache/*/ronny/*/skills/ronny/scripts/check-drift.sh 2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then ronny="$candidate"; ronny_source="plugin-cache, hoogste versie"; fi
    fi
    if [ -z "$ronny" ]; then
        warning "13. Ronny — niet gevonden; overgeslagen"; list "zet RONNY_SCRIPT of herstel .claude/skills/ronny"
    else
        if ronny_out="$("$ronny" 2>&1)"; then ronny_rc=0; else ronny_rc=$?; fi
        if [ "$ronny_rc" -eq 0 ]; then ok "13. Ronny — exitcode 0 [$ronny_source]"
        elif [ "$ronny_rc" -eq 1 ]; then
            error "13. Ronny — exitcode 1, drift gevonden [$ronny_source]"
            # Alleen de bevindingen: zonder lege regels, sectiekoppen (--- … ---) en "Geen …"-regels.
            ronny_findings="$(printf '%s\n' "$ronny_out" | grep -v -E '^[[:space:]]*$|^--- .* ---$|^Geen' || true)"
            ronny_total="$(printf '%s\n' "$ronny_findings" | grep -c . || true)"
            list "$(printf '%s\n' "$ronny_findings" | head -40)"
            if [ "$ronny_total" -gt 40 ]; then list "… (zie het volledige rapport)"; fi
            list "draai $ronny voor het volledige rapport"
        else
            warning "13. Ronny — exitcode $ronny_rc (configuratieprobleem in ronny.conf?) [$ronny_source]"
            list "$(printf '%s\n' "$ronny_out" | tail -4)"
        fi
    fi
fi

# 14. AIDOCS-STRUCTUUR EN -DEKKING (ERROR + WARNING) — alleen bij AIDOCS_FLAVOUR=structure
#     bin/check-aidocs.php: headers, _index.md-bestanden, CLAUDE.md-verwijzingen, en of elk
#     gewijzigd bestand onder een Covers valt. Zijn uitvoer is "ERROR: …" of "WARNING: …".
if should_run 14 && [ "$AIDOCS_FLAVOUR" != "structure" ]; then ok "14. AIdocs-structuur — n.v.t. voor AIDOCS_FLAVOUR='${AIDOCS_FLAVOUR}' (alleen bij structure)"; fi
if should_run 14 && [ "$AIDOCS_FLAVOUR" = "structure" ]; then
    aidocs_bad=0
    for mode in structure coverage; do
        if aidocs_out="$("$PHP_BIN" bin/check-aidocs.php "$mode" 2>&1)"; then aidocs_rc=0; else aidocs_rc=$?; fi
        if [ "$aidocs_rc" -ge 2 ]; then
            error "14. AIdocs-$mode — kon niet controleren (exitcode $aidocs_rc)"; list "$aidocs_out"; aidocs_bad=1
            continue
        fi
        while IFS= read -r line; do
            case "$line" in
                "ERROR: "*)   error "14. AIdocs-$mode — ${line#ERROR: }"; aidocs_bad=1 ;;
                "WARNING: "*) warning "14. AIdocs-$mode — ${line#WARNING: }"; aidocs_bad=1 ;;
            esac
        done <<< "$aidocs_out"
    done
    [ "$aidocs_bad" -eq 0 ] && ok "14. AIdocs — structuur in orde en gewijzigde bestanden gedekt"
fi

# 15. STRICT_TYPES (WARNING): een PHP-bestand in de scope zonder `declare(strict_types=1);`.
#     Bedoeld om strict_types geleidelijk in te voeren: wie een bestand aanraakt, zet het erin.
#     Nooit massaal toevoegen: het verandert de coercion van scalaire types bij elke aanroep
#     vanuit dat bestand, dus het hoort bij een wijziging die je ook test. Daarom een WARNING.
#     Alleen bestanden met een `<?php`-tag tellen. Bewust overgeslagen: view-templates, dus
#     alles onder een map tmpl/, layouts/ of html/ (template-overrides) en de entry-bestanden
#     van een Joomla-template (templates/<naam>/{index,error,component,offline}.php). Dat is
#     markup met een paar echo's; strict_types is daar onschadelijk maar levert vooral ruis op.
#     Het hoort in klassebestanden: src/, services/, script.php, installerscripts, tests.
#     Per repo extra uit te sluiten paden (prefix): STRICT_TYPES_EXCLUDE in scripts.conf.
if should_run 15; then
    st_missing=""; st_checked=0
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        case "$f" in *.php) : ;; *) continue ;; esac
        scan_excluded "$f" && continue
        st_skip=0
        for p in "${STRICT_TYPES_EXCLUDE[@]}"; do
            case "$f" in "$p"*) st_skip=1; break ;; esac
        done
        [ "$st_skip" -eq 0 ] || continue
        printf '%s\n' "$f" | grep -qE '(^|/)(tmpl|layouts|html)/|(^|/)templates/[^/]+/(index|error|component|offline)\.php$' && continue
        grep -q '<?php' "$f" 2>/dev/null || continue
        st_checked=$((st_checked + 1))
        grep -qE 'declare[[:space:]]*\([[:space:]]*strict_types[[:space:]]*=[[:space:]]*1[[:space:]]*\)' "$f" 2>/dev/null || st_missing="$st_missing
$f"
    done < <(printf '%s\n' "$SET")
    if [ -n "$st_missing" ]; then
        warning "15. strict_types — $(printf '%s\n' "$st_missing" | grep -c .) PHP-bestand(en) zonder declare(strict_types=1); zet het erin als je het bestand toch wijzigt"
        list "$st_missing"
    elif [ "$st_checked" -eq 0 ]; then ok "15. strict_types — n.v.t., geen PHP-klassebestand in de scope"
    else ok "15. strict_types — $st_checked PHP-bestand(en) in de scope declareren strict_types"; fi
fi

# ══════════════════════════════════════════════════════════════════════
echo ""
printf '%s%d OK%s · %s%d warning(s)%s · %s%d error(s)%s\n' "$C_OK" "$n_ok" "$C_0" "$C_W" "$n_warning" "$C_0" "$C_F" "$n_error" "$C_0"
if [ "$n_error" -gt 0 ]; then echo "Niet klaar. Exit code 1."; exit 1; fi
echo "Klaar. Exit code 0."
exit 0
