# A Stop event means Claude finished a response, not that the CLI exited.
# Persist routing metadata plus a short plain-text preview of the final reply
# (owner-only file, consumed and deleted by the app within a second).
umask 077
[ -n "$BANANA_LIMITS_BASE" ] || exit 0
payload=$(cat)
printf '%s' "$payload" | /usr/bin/jq -e '.hook_event_name == "Stop" and ((.background_tasks // []) | length == 0) and ((.session_crons // []) | length == 0)' >/dev/null 2>&1 || exit 0
directory="${BANANA_LIMITS_BASE%/*}/completions"
mkdir -p "$directory" || exit 0
tmp=$(mktemp "$directory/.pending.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT
pane=${BANANA_LIMITS_BASE##*/limits-}
source=claude
[ "${BANANA_COMPLETION_SOURCE:-}" = test ] && source=test
# Strip code fences and markdown markers, collapse whitespace, keep 200 characters.
summary=$(printf '%s' "$payload" | /usr/bin/jq -r '(.last_assistant_message // "") | strings
  | gsub("```[^\n]*"; " ") | gsub("[`*_#>|]+"; "") | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
  | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ") | .[:200]' 2>/dev/null)
/usr/bin/jq -nc --arg source "$source" --arg pane "$pane" --arg summary "$summary" --argjson timestamp "$(date +%s)" \
  '{pane: $pane, timestamp: $timestamp, source: $source} + (if $summary == "" then {} else {summary: $summary} end)' > "$tmp" && mv "$tmp" "$tmp.json"
exit 0
