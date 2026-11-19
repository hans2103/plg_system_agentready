#!/bin/bash
# Test voor .githooks/pre-push (#643): pushen naar een lokale bare repo, zonder netwerk.
# Gebruik: bash tests/shell/test_pre_push_hook.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
unset KWEK_SKIP_CI_LOCAL T_SKIP_CI_LOCAL SKIP_CI_LOCAL

r="$tmp/r"
ci_repo "$r"
git init -q --bare "$tmp/remote.git"
( cd "$r" && git config core.hooksPath .githooks && git remote add origin "$tmp/remote.git" && git switch -q -c feature/1-test )
push() { ( cd "$r" && git push "$@" ); }
remote_has() { git -C "$tmp/remote.git" rev-parse --verify --quiet "$1" > /dev/null; }

# Schoon, zonder stempel: de hook draait ci-local, dat is groen, de push gaat door.
expect "push zonder stempel draait ci-local" 0 push -q origin feature/1-test
has "hook meldt de run" 'ci-local.sh draait eerst'
remote_has refs/heads/feature/1-test && pass "branch staat op de remote" || bad "branch niet gepusht"

# Met stempel: geen nieuwe run.
( cd "$r" && echo a > a.txt && git add a.txt && git commit -q -m "a #1" && bash bin/ci-local.sh > /dev/null )
expect "push met stempel" 0 push -q origin feature/1-test
hasnt "geen run met stempel" 'ci-local.sh draait eerst'

# Falende controle: push afgewezen.
( cd "$r" && touch .ci-fail && git add .ci-fail && git commit -q -m "fail #1" )
bad_sha="$(git -C "$r" rev-parse HEAD)"
expect "push bij falende ci-local" 1 push -q origin feature/1-test
has "afwijzing met reden" 'Push afgewezen'
[ "$(git -C "$tmp/remote.git" rev-parse refs/heads/feature/1-test)" != "$bad_sha" ] && pass "remote niet bijgewerkt" || bad "remote toch bijgewerkt"

# Vieze werkboom zonder stempel: afgewezen zonder run.
echo x > "$r/los.txt"
expect "push bij vieze werkboom" 1 push -q origin feature/1-test
has "melding werkboom" 'werkboom is niet schoon'
rm -f "$r/los.txt"

# Noodknop: ${ENV_PREFIX}_SKIP_CI_LOCAL uit scripts.conf (#645); ci_repo heeft ENV_PREFIX="T".
expect "oude naam KWEK_SKIP_CI_LOCAL=1 doet niets meer" 1 bash -c "cd '$r' && KWEK_SKIP_CI_LOCAL=1 git push -q origin feature/1-test"
hasnt "  geen noodknop-waarschuwing" 'lokale CI overgeslagen'
has "  afwijzing noemt de echte noodknop" 'Noodknop: T_SKIP_CI_LOCAL=1 git push'
expect "T_SKIP_CI_LOCAL=1 (ENV_PREFIX=T)" 0 bash -c "cd '$r' && T_SKIP_CI_LOCAL=1 git push -q origin feature/1-test"
has "noodknop waarschuwt met de echte naam" 'T_SKIP_CI_LOCAL=1: lokale CI overgeslagen'

# Tag op een ongestempelde commit: niet geblokkeerd.
( cd "$r" && git tag v0.0.1 )
expect "tag pushen" 0 push -q origin v0.0.1
remote_has refs/tags/v0.0.1 && pass "tag staat op de remote" || bad "tag niet gepusht"

# Verwijderen van een remote branch: niet geblokkeerd.
push -q origin HEAD:refs/heads/weg-ermee --no-verify > /dev/null 2>&1
expect "remote branch verwijderen" 0 push -q origin --delete weg-ermee

# Vanuit een worktree: git zet dan GIT_DIR voor de hook; ci-local.sh moet toch de worktree vinden.
( cd "$r" && git rm -q .ci-fail && git commit -q -m "ok #1" )
git -C "$r" worktree add -q "$tmp/wt" -b feature/2-wt > /dev/null 2>&1
( cd "$tmp/wt" && echo w > w.txt && git add w.txt && git commit -q -m "w #2" )
expect "push vanuit worktree zonder stempel" 0 bash -c "cd '$tmp/wt' && git push -q origin feature/2-wt"
hasnt "  geen scripts.conf-fout" 'scripts.conf ontbreekt'
remote_has refs/heads/feature/2-wt && pass "worktree-branch staat op de remote" || bad "worktree-branch niet gepusht"
( cd "$tmp/wt" && echo v > v.txt && git add v.txt && git commit -q -m "v #2" && bash bin/ci-local.sh > /dev/null )
expect "push vanuit worktree met stempel" 0 bash -c "cd '$tmp/wt' && git push -q origin feature/2-wt"
hasnt "  geen run met stempel" 'ci-local.sh draait eerst'

# Repo zonder .git in de werkmap (GIT_DIR/GIT_WORK_TREE van buiten): de hook laat GIT_DIR dan staan.
sep="$tmp/sep"; mkdir -p "$sep"
cp -R "$r/bin" "$r/.githooks" "$r/scripts.conf" "$sep/"
export_sep() { GIT_DIR="$tmp/sep.git" GIT_WORK_TREE="$sep" "$@"; }
( cd "$sep" && export_sep git init -q -b feature/3-sep && export_sep git config user.email t@t && export_sep git config user.name t \
  && export_sep git config commit.gpgsign false && export_sep git config core.hooksPath .githooks \
  && export_sep git add -A && export_sep git commit -q -m "sep #3" && export_sep git remote add origin "$tmp/remote.git" )
expect "push zonder .git in de werkmap" 0 bash -c "cd '$sep' && GIT_DIR='$tmp/sep.git' GIT_WORK_TREE='$sep' git push -q origin feature/3-sep"
remote_has refs/heads/feature/3-sep && pass "branch met losse git-dir staat op de remote" || bad "branch met losse git-dir niet gepusht"

# Zonder ENV_PREFIX in scripts.conf heet de noodknop SKIP_CI_LOCAL.
np="$tmp/np"; mkdir -p "$np"
cp -R "$r/bin" "$r/.githooks" "$np/"
grep -v '^ENV_PREFIX=' "$r/scripts.conf" > "$np/scripts.conf"
touch "$np/.ci-fail"
git_init "$np"
( cd "$np" && git config core.hooksPath .githooks && git add -A && git commit -q -m "np #4" && git remote add origin "$tmp/remote.git" && git switch -q -c feature/4-np )
expect "zonder ENV_PREFIX: T_SKIP_CI_LOCAL=1 doet niets" 1 bash -c "cd '$np' && T_SKIP_CI_LOCAL=1 git push -q origin feature/4-np"
expect "zonder ENV_PREFIX: SKIP_CI_LOCAL=1" 0 bash -c "cd '$np' && SKIP_CI_LOCAL=1 git push -q origin feature/4-np"
has "  waarschuwt met SKIP_CI_LOCAL" 'SKIP_CI_LOCAL=1: lokale CI overgeslagen'
hasnt "  geen voorvoegsel met underscore" '_SKIP_CI_LOCAL=1: lokale'

# Push naar develop (terugmerge na een release): niet geblokkeerd.
expect "push naar develop" 0 push -q origin HEAD:refs/heads/develop
hasnt "geen run voor develop" 'ci-local.sh draait eerst'

finish
