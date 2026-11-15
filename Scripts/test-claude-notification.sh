#!/bin/sh
# Run inside a bananaShell zsh terminal. No Claude process or API call is used.
set -eu
if [ -z "${BANANA_LIMITS_BASE:-}" ]; then
    echo 'This terminal has no bananaShell session ID. Open a new zsh terminal in bananaShell and try again.' >&2
    exit 1
fi
support=$(CDPATH= cd -- "$(dirname -- "$0")/../Sources/PromptSupport" && pwd)
launcher=${1:-"$support/claude-launch.sh"}
if [ ! -r "$launcher" ]; then
    echo "Claude launcher not found: $launcher" >&2
    exit 1
fi
fixture=$(mktemp -d "${TMPDIR:-/tmp}/banana-notch-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/mock-claude" <<'MOCK'
#!/bin/sh
set -eu
[ "$1" = --settings ]
command=$(printf '%s' "$2" | /usr/bin/jq -er '.hooks.Stop[0].hooks[0].command')
printf '%s\n' '{"hook_event_name":"Stop","background_tasks":[],"session_crons":[]}' | /bin/sh -c "$command"
printf 'Completion event sent for terminal %s\n' "${BANANA_LIMITS_BASE##*/limits-}"
MOCK
chmod 700 "$fixture/mock-claude"
BANANA_COMPLETION_SOURCE=test /bin/sh "$launcher" "$fixture/mock-claude"
