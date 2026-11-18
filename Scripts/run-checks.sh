#!/bin/bash
# Compiles and runs the standalone checks in Tests/ that need no Xcode build products.
# Usage: Scripts/run-checks.sh [check-name ...]   (default: all listed below)
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d "${TMPDIR:-/tmp}/banana-checks.XXXXXX")
trap 'rm -rf "$out"' EXIT

zstd_include=Vendor/BananaZstd/Sources/BananaZstd/include
zstd_object="$out/zstddeclib.o"

# Not run here: checks that link SwiftTerm from the Xcode build (AutomationTerminal,
# PersistentTerminal, TerminalComposition, ThemeMarketplace), APIKeyStore (uses the
# keychain), AutomationInputWait, WorkspacePerformance (a benchmark), and
# ActivityBoard and SSHKeyGeneration, whose source lists no longer compile on their own.
#
# name|sources (the check file is added automatically)|extra swiftc flags
checks=(
  "ActivityGridChecks|Sources/ActivityBoards.swift|"
  "ClaudeCompletionChecks|Sources/ClaudeCompletion.swift|"
  "PersistentPaneChecks|Sources/PersistentTerminal.swift|"
  "TerminalStatusPollerChecks|Sources/PersistentTerminal.swift|"
  "PromptEngineChecks|Sources/PromptEngine.swift|"
  "TerminalSlotChecks|Sources/TerminalSlots.swift|"
  "ExtensionCatalogChecks|Sources/ExtensionCatalog.swift|zstd"
)

selected=(${1+"$@"})
failed=()
for entry in "${checks[@]}"; do
  IFS='|' read -r name sources extra <<<"$entry"
  if ((${#selected[@]})) && [[ ! " ${selected[*]-} " == *" $name "* ]]; then continue; fi
  flags=()
  if [[ $extra == zstd ]]; then
    [[ -f $zstd_object ]] || clang -c -O2 -I "$zstd_include" Vendor/BananaZstd/Sources/BananaZstd/zstddeclib.c -o "$zstd_object"
    flags=(-I "$zstd_include" "$zstd_object")
  fi
  echo "::group::$name"
  # shellcheck disable=SC2086
  if swiftc -parse-as-library ${flags[@]+"${flags[@]}"} $sources "Tests/$name.swift" -o "$out/$name" && "$out/$name"; then
    echo "::endgroup::"
    echo "PASS $name"
  else
    echo "::endgroup::"
    echo "FAIL $name"
    failed+=("$name")
  fi
done

echo "::group::claude_completion_checks.py"
if python3 Tests/claude_completion_checks.py; then echo "::endgroup::"; echo "PASS claude_completion_checks.py"
else echo "::endgroup::"; echo "FAIL claude_completion_checks.py"; failed+=(claude_completion_checks.py); fi

if ((${#failed[@]})); then
  echo "Failed: ${failed[*]}"
  exit 1
fi
echo "All checks passed."
