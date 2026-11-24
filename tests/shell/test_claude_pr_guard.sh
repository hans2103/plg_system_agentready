#!/bin/bash
# Test voor bin/claude-pr-guard.sh (#643), de PreToolUse-hook uit .claude/settings.json.
# Gebruik: bash tests/shell/test_claude_pr_guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

r="$tmp/r"
ci_repo "$r"

# guard verwachte-exit commando [tool]: voert de hook-JSON zoals Claude Code die stuurt.
guard() {
  local want="$1" cmd="$2" tool="${3:-Bash}" rc
  php -r 'echo json_encode(["hook_event_name" => "PreToolUse", "tool_name" => $argv[1], "cwd" => $argv[2], "tool_input" => ["command" => $argv[3]]]);' "$tool" "$r" "$cmd" \
    | bash "$r/bin/claude-pr-guard.sh" > "$tmp/out.txt" 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$cmd -> $rc"; else bad "$cmd gaf $rc, verwachtte $want"; sed 's/^/      /' "$tmp/out.txt"; fi
}

# Zonder stempel.
guard 0 'ls -la'
guard 0 'git status'
guard 0 'gh pr view 12'
guard 0 'gh pr create --draft --base develop --title "x #1"'
guard 0 'gh pr create -d --base develop'
guard 0 'gh pr ready 12 --undo'
guard 2 'gh pr create --base develop --title "x #1"'
has "uitleg verwijst naar ci-local" 'bin/ci-local.sh'
guard 2 'gh pr ready 12'
guard 2 'cd /tmp && gh pr ready'
guard 2 'GH_REPO=o/t gh pr ready 12'
guard 2 'gh pr create --draft=false --base develop'
guard 0 'gh pr ready 12' 'Write'
# Tekst in quotes of een heredoc telt niet als commando.
guard 0 "gh pr create --draft --title 'na gh pr ready' --body \"lokaal groen, dan; gh pr ready\""
guard 0 "$(printf '%s\n' 'gh pr create --draft --body "$(cat <<'"'"'EOF'"'"'' 'Werkwijze:' 'gh pr ready' 'EOF' ')"')"
guard 0 'echo "gh pr ready"'

# F1: meerregelige body met --draft achteraan (het hele commando wordt getokeniseerd, niet per regel).
heredoc_body="$(printf '%s\n' 'gh pr create --title "x" --body "$(cat <<'"'"'EOF'"'"'' 'body' 'gh pr ready' 'EOF' ')" --draft')"
guard 0 "$heredoc_body"
guard 2 "${heredoc_body% --draft}"
guard 0 "$(printf '%s\n' 'gh pr create --title "x" --body "regel 1' 'regel 2' 'gh pr ready" --draft')"
guard 2 "$(printf '%s\n' 'gh pr create --title "x" --body "regel 1' 'regel 2"')"
guard 0 "$(printf '%s\n' "gh pr create --body 'een' 'twee' -d")"
guard 0 'gh pr create --base develop --draft=true'

# F2: omwegen naar gh pr ready/create tellen ook.
guard 2 'gh -R o/r pr ready 1'
guard 2 'gh --repo=o/r pr ready 1'
guard 2 'gh --repo o/r pr create --base develop'
guard 2 'gh pr -R o/r ready 1'
guard 2 'command gh pr ready'
guard 2 'env gh pr ready'
guard 2 'env -i GH_X=1 gh pr ready'
guard 2 '/opt/homebrew/bin/gh pr ready'
guard 2 "bash -c 'gh pr ready'"
guard 2 "sh -c \"cd /tmp && gh pr ready 3\""
guard 2 'echo start; gh pr ready'
guard 2 'x=$(gh pr ready 4)'
guard 2 'gh pr ready 1 | cat'
guard 2 'gh -R o/r pr create --title "x"'
# M1: meer wrappers.
guard 2 'timeout 5 gh pr ready'
guard 2 'timeout -s KILL -k 2 5m gh pr ready'
guard 2 'sudo gh pr ready'
guard 2 'sudo -u hans -E gh pr ready'
guard 2 'nice -n 5 gh pr ready'
guard 2 'nice gh pr ready'
guard 2 'xargs gh pr ready <<< 1'
guard 2 'xargs -n 1 -I {} gh pr ready {}'
guard 2 'stdbuf -oL gh pr ready'
guard 2 'stdbuf -o L -e 0 gh pr create --base develop'
guard 0 'timeout 5 gh pr create --draft'
guard 0 'sudo ls'
# Geen vals positieven.
guard 0 'git commit -m "gh pr ready"'
guard 0 'echo gh pr ready'
guard 0 'gh pr edit 12 --title "gh pr ready"'
guard 0 'gh -R o/r pr ready 1 --undo'
guard 0 'gh issue view 643'
guard 0 '# gh pr ready'
guard 0 "grep -n 'gh pr ready' Docs/x.md"
guard 0 'gh pr view 12 --json title -q ".title" # gh pr ready'

# Met stempel.
( cd "$r" && bash bin/ci-local.sh > /dev/null )
guard 0 'gh pr ready 12'
guard 0 'gh pr create --base develop'

# Vieze werkboom: de stempel geldt niet.
echo x > "$r/los.txt"
guard 2 'gh pr ready 12'
rm -f "$r/los.txt"

# F3: het hookcommando uit .claude/settings.json geeft in een checkout zonder het script exit 0
# (geen 127 bij elke Bash-aanroep), en met het script weigert het nog steeds.
hook_cmd="$(php -r '$d = json_decode((string) file_get_contents($argv[1]), true); echo $d["hooks"]["PreToolUse"][0]["hooks"][0]["command"];' "$repo/.claude/settings.json")"
mkdir -p "$tmp/leeg"
( cd "$r" && echo y > y.txt && git add y.txt && git commit -q -m "y #1" )   # HEAD zonder stempel
expect "hookcommando zonder script" 0 bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr ready\"}}' | CLAUDE_PROJECT_DIR='$tmp/leeg' bash -c '$hook_cmd'"
expect "hookcommando met script weigert" 2 bash -c "php -r 'echo json_encode([\"tool_name\" => \"Bash\", \"cwd\" => \$argv[1], \"tool_input\" => [\"command\" => \"gh pr ready\"]]);' '$r' | CLAUDE_PROJECT_DIR='$r' bash -c '$hook_cmd'"

finish
