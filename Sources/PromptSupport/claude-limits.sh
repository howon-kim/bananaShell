# Store only the four quota fields, never the raw status-line input.
umask 077
tmp=$(mktemp "${BANANA_CLAUDE_LIMITS:?}.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
/usr/bin/jq -c 'def window: {used_percentage, resets_at}; .rate_limits | {five_hour: (.five_hour | window), seven_day: (.seven_day | window)}' > "$tmp" &&
  mv -f "$tmp" "$BANANA_CLAUDE_LIMITS"
