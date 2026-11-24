#!/bin/bash
# Test voor de stempel van bin/ci-local.sh (#643), in een wegwerprepo zonder netwerk.
# Gebruik: bash tests/shell/test_ci_local.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

r="$tmp/r"
ci_repo "$r"
ci() { ( cd "$r" && bash bin/ci-local.sh "$@" ); }
stamps="$r/.git/ci-local"

expect "--check zonder stempel" 1 ci --check
expect "ci-local groen" 0 ci
has "stempel gezet" 'Stempel gezet'
sha="$(git -C "$r" rev-parse HEAD)"
tree="$(git -C "$r" rev-parse 'HEAD^{tree}')"
if [ -f "$stamps/$sha" ]; then pass "stempel in git-common-dir/ci-local"; else bad "stempel ontbreekt in $stamps"; fi
grep -qx "commit=$sha" "$stamps/$sha" 2>/dev/null && grep -qx "tree=$tree" "$stamps/$sha" 2>/dev/null \
  && pass "stempel bevat commit- en tree-hash" || bad "stempel mist commit of tree"
expect "--check met stempel" 0 ci --check
expect "--check <commit> met stempel" 0 ci --check "$sha"

# Werkboom vies: de stempel geldt niet (ook niet bij een ongevolgd bestand).
echo x > "$r/los.txt"
expect "--check bij ongevolgd bestand" 1 ci --check
expect "--check <commit> negeert de werkboom" 0 ci --check "$sha"
expect "ci-local bij vieze werkboom draait wel" 0 ci
has "maar zet geen stempel" 'Geen stempel'
rm -f "$r/los.txt"
expect "--check weer schoon" 0 ci --check

# Nieuwe commit: HEAD is niet meer de gestempelde commit.
( cd "$r" && echo a > a.txt && git add a.txt && git commit -q -m "a #1" )
expect "--check na nieuwe commit" 1 ci --check

# Gemanipuleerde stempel (andere tree) telt niet.
sha2="$(git -C "$r" rev-parse HEAD)"
printf 'commit=%s\ntree=%s\n' "$sha2" "$tree" > "$stamps/$sha2"
expect "--check bij verkeerde tree-hash" 1 ci --check
rm -f "$stamps/$sha2"

# Falende controle: exit 1, geen stempel.
( cd "$r" && touch .ci-fail && git add .ci-fail && git commit -q -m "fail #1" )
expect "falende controle" 1 ci
has "melding van de gefaalde stap" 'gefaald'
expect "geen stempel na fout" 1 ci --check
( cd "$r" && git rm -q .ci-fail && git commit -q -m "ok #1" )

# --quick zet geen stempel.
expect "--quick groen" 0 ci --quick
has "--quick zonder stempel" 'Geen stempel bij --quick'
expect "--check na --quick" 1 ci --check

# Worktree: de stempel staat in de gedeelde git-dir en geldt dus ook daar.
expect "ci-local in de hoofdcheckout" 0 ci
git -C "$r" worktree add -q "$tmp/wt" -b wt-test > /dev/null 2>&1
expect "--check in worktree op dezelfde commit" 0 bash -c "cd '$tmp/wt' && bash bin/ci-local.sh --check"
expect "ci-local in een worktree" 0 bash -c "cd '$tmp/wt' && echo b > b.txt && git add b.txt && git commit -q -m 'b #1' && bash bin/ci-local.sh"
wsha="$(git -C "$tmp/wt" rev-parse HEAD)"
if [ -f "$stamps/$wsha" ]; then pass "worktree-stempel in de gedeelde git-dir"; else bad "worktree-stempel niet in $stamps"; fi

expect "onbekende optie" 2 ci --bestaat-niet

finish
