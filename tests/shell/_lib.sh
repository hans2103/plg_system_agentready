#!/bin/bash
# tests/shell/_lib.sh — gedeelde helpers voor de shell-tests; wordt gesourced door test_*.sh.
# De tests zijn repo-agnostisch: alles wat per repo verschilt komt uit scripts.conf, zodat
# dezelfde tests in elke HKweb-Joomla-repo draaien.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

# shellcheck disable=SC1091
. "$repo/scripts.conf"
: "${SRC_DIR:=Src}"   # dezelfde default als bin/_common.sh
[ "${BUILT_DIRS+x}" ] || BUILT_DIRS=()
# --built=-argumenten voor bin/check-manifests.php, zoals preflight ze uit BUILT_DIRS maakt.
built_args=()
for _d in "${BUILT_DIRS[@]}"; do [ -n "$_d" ] && built_args+=("--built=$_d"); done
unset _d

pass() { echo "ok:   $1"; }
bad()  { echo "FAIL: $1"; failed=1; }

same() { # label verwacht werkelijk
  if [ "$2" = "$3" ]; then pass "$1 ($3)"; else bad "$1: verwachtte '$2', kreeg '$3'"; fi
}

# Draait een commando, bewaart de uitvoer in $tmp/out.txt en het resultaat in $rc.
run() { "$@" > "$tmp/out.txt" 2>&1; rc=$?; }

expect() { # label verwachte-exitcode commando...
  local label="$1" want="$2"; shift 2
  run "$@"
  if [ "$rc" -eq "$want" ]; then pass "$label (exit $rc)"; else bad "$label gaf exit $rc, verwachtte $want"; sed 's/^/      /' "$tmp/out.txt" | tail -8; fi
}

has() { # label patroon: staat het patroon in de laatste uitvoer?
  if grep -qE -- "$2" "$tmp/out.txt"; then pass "$1"; else bad "$1 (patroon '$2' niet in de uitvoer)"; sed 's/^/      /' "$tmp/out.txt" | tail -8; fi
}

hasnt() { # label patroon
  if grep -qE -- "$2" "$tmp/out.txt"; then bad "$1 (patroon '$2' staat wel in de uitvoer)"; sed 's/^/      /' "$tmp/out.txt" | tail -8; else pass "$1"; fi
}

# Draait een commando met een pseudo-terminal als uitvoer, zoals in een interactieve shell (dan
# start git bijvoorbeeld zijn pager). Geeft 127 als `script` ontbreekt. util-linux (Linux) wil het
# commando als string na -c; BSD (macOS) neemt het als losse argumenten na het uitvoerbestand.
in_tty() {
  command -v script > /dev/null 2>&1 || return 127
  if script --version 2>/dev/null | grep -q util-linux; then
    script -qec "$(printf '%q ' "$@")" /dev/null < /dev/null
  else
    script -q /dev/null "$@" < /dev/null
  fi
}

git_init() { # map
  ( cd "$1" && git init -q -b main && git config gc.auto 0 && git config commit.gpgsign false && git config user.email t@t && git config user.name t )
}

# Kopieert de repo (gevolgde en nieuwe, niet-genegeerde bestanden; geen vendor of build-uitvoer)
# naar $1 als eigen git-repo met één commit, zodat controles op een schone stand kunnen draaien.
copy_repo() {
  mkdir -p "$1"
  ( cd "$repo" && git ls-files --cached --others --exclude-standard | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done | tar -cf - -T - ) | tar -xf - -C "$1"
  git_init "$1"
  ( cd "$1" && git add -A && git commit -q -m init )
}

# Zet een kopie terug naar zijn commit (gewijzigde bestanden terug, nieuwe bestanden weg).
reset_copy() { ( cd "$1" && git checkout -q -- . && git clean -fdq ); }

finish() { if [ "$failed" -eq 0 ]; then echo "Alle controles geslaagd."; else exit 1; fi; }
