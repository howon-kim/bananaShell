#!/bin/zsh
# Counts 👍 and ❤️ reactions on catalog theme issues and writes
# Sources/PromptSupport/Catalog/likes.json. Each catalog theme can have one
# issue labelled `theme` and titled "[theme] <id>"; the app's "Rate on GitHub"
# button opens it. Run Scripts/theme-catalog.py build afterwards to update the index.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=${1:-howon-kim/bananaShell}
gh api --paginate "repos/$repo/issues?labels=theme&state=all&per_page=100" \
  --jq '.[] | select(.title | startswith("[theme] ")) | {id: (.title | ltrimstr("[theme] ") | ascii_downcase), likes: (.reactions["+1"] + .reactions.heart)}' |
  python3 -I -c '
import json, sys
likes = {}
for line in sys.stdin:
    item = json.loads(line)
    likes[item["id"]] = likes.get(item["id"], 0) + item["likes"]
json.dump(dict(sorted(likes.items())), sys.stdout, indent=2)
print()
' > Sources/PromptSupport/Catalog/likes.json
echo "Updated likes for $(python3 -I -c 'import json; print(len(json.load(open("Sources/PromptSupport/Catalog/likes.json"))))') themes."
