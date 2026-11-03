# Executed as the foreground job. exec keeps its PID when Claude takes over.
binary=$1
shift
case " $* " in
  *" --settings"*|*" --bare "*|*" --help "*|*" --version "*|*" --print "*|*" -p "*) exec "$binary" "$@" ;;
esac
# Do not replace an existing status line. Leave those sessions uninstrumented.
for config in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
  if [ -r "$config" ] && /usr/bin/jq -e '.statusLine != null' "$config" >/dev/null 2>&1; then
    exec "$binary" "$@"
  fi
done
export BANANA_CLAUDE_LIMITS="$BANANA_LIMITS_BASE-$$"
export BANANA_CLAUDE_COLLECTOR="${0%/*}/claude-limits.sh"
rm -f "$BANANA_CLAUDE_LIMITS"
exec "$binary" --settings '{"statusLine":{"type":"command","command":"/bin/sh \"$BANANA_CLAUDE_COLLECTOR\""}}' "$@"
