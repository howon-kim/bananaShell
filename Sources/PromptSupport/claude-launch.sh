# Executed as the foreground job. exec keeps its PID when Claude takes over.
binary=$1
shift
case " $* " in
  *" --settings"*|*" --bare "*|*" --help "*|*" --version "*|*" --print "*|*" -p "*) exec "$binary" "$@" ;;
esac
# Hooks are session-scoped; user/project settings are never rewritten.
export BANANA_CLAUDE_COMPLETED="${0%/*}/claude-completed.sh"
settings='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh \"$BANANA_CLAUDE_COMPLETED\"","timeout":5}]}]}}'
# Preserve an existing status line while still installing completion notifications.
custom_status=no
for config in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
  if [ -r "$config" ] && /usr/bin/jq -e '.statusLine != null' "$config" >/dev/null 2>&1; then
    custom_status=yes
  fi
done
export BANANA_CLAUDE_LIMITS="$BANANA_LIMITS_BASE-$$"
export BANANA_CLAUDE_COLLECTOR="${0%/*}/claude-limits.sh"
rm -f "$BANANA_CLAUDE_LIMITS"
if [ "$custom_status" = no ]; then
  settings=$(printf '%s' "$settings" | /usr/bin/jq -c '. + {statusLine: {type: "command", command: "/bin/sh \"$BANANA_CLAUDE_COLLECTOR\""}}')
fi
exec "$binary" --settings "$settings" "$@"
