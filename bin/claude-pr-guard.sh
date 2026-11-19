#!/bin/bash
#
# bin/claude-pr-guard.sh — PreToolUse-hook voor Claude Code (geregistreerd in .claude/settings.json).
#
# Leest de hook-JSON op stdin. Alleen een Bash-commando dat `gh pr ready` of `gh pr create` zonder
# --draft/-d draait telt: dan moet bash bin/ci-local.sh --check slagen (geldige stempel voor HEAD,
# schone werkboom), anders weigert de hook met exit 2 en een uitleg op stderr. Een draft-PR openen,
# `gh pr ready --undo` en elk ander commando gaan altijd door (exit 0).
#
# Het herkennen doet bin/claude-pr-guard.php: dat tokeniseert het hele commando zoals een shell
# (quotes, heredocs, $( ), ; && |), dus tekst in een argument of heredoc telt niet en een --draft
# na een meerregelige --body wel. Omwegen als `gh -R o/r pr ready`, `env gh …`, een volledig pad
# naar gh en `bash -c '…'` tellen ook.
#
# Ontbreekt bin/ci-local.sh (oudere branch) of php, dan laat de hook alles door.
#
# BASH 3.2-COMPATIBEL (macOS).

input="$(cat)"
# Snelle uitweg: de meeste Bash-aanroepen hebben niets met gh te maken.
case "$input" in *gh*) ;; *) exit 0 ;; esac
command -v php > /dev/null 2>&1 || exit 0

parsed="$(printf '%s' "$input" | php "$(dirname "${BASH_SOURCE[0]}")/claude-pr-guard.php" 2>/dev/null)" || exit 0
reason="$(printf '%s\n' "$parsed" | sed -n 1p)"
dir="$(printf '%s\n' "$parsed" | sed -n 2p)"
[ -n "$reason" ] || exit 0

[ -n "$dir" ] && [ -d "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$top/bin/ci-local.sh" ] || exit 0

if (cd "$top" && bash bin/ci-local.sh --check < /dev/null); then
    exit 0
fi
{
    echo "Geweigerd: $reason zonder geldige stempel van bin/ci-local.sh voor HEAD."
    echo "Draai eerst apart (ruime time-out): bash bin/ci-local.sh (in $top). Daarvoor moet de"
    echo "werkboom schoon zijn. Open een PR als draft met: gh pr create --draft …"
} >&2
exit 2
