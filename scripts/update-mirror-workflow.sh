#!/bin/bash
set -euo pipefail

GITEA_URL="https://git.reckeweg.io"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN env var required}"
WORKFLOW_PATH=".gitea/workflows/mirror-to-sailpoint.yml"

NEW_WORKFLOW='name: Mirror to SailPoint GitHub

on:
  push:
    branches:
      - "**"
  delete: {}

jobs:
  mirror:
    runs-on: ubuntu-latest
    steps:
      - name: Mirror to SailPoint GitHub
        env:
          SAILPOINT_TOKEN: ${{ secrets.SAILPOINT_GITHUB_TOKEN }}
          GITEA_TOKEN: ${{ secrets.GITEA_TOKEN }}
          REPO_NAME: ${{ gitea.repository }}
          SERVER_URL: ${{ gitea.server_url }}
        run: |
          SHORT_NAME="${REPO_NAME##*/}"
          git clone --mirror \
            "https://gitea-actions:${GITEA_TOKEN}@${SERVER_URL#https://}/${REPO_NAME}.git" repo
          cd repo
          git push --mirror \
            "https://x-access-token:${SAILPOINT_TOKEN}@github.com/achim-reckeweg-sp/${SHORT_NAME}.git"
'

# Raw API response for debugging
RAW=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/user/repos?limit=50")

if [ -z "$RAW" ]; then
  echo "ERROR: curl returned empty response. Check network/URL."
  exit 1
fi

# Check if valid JSON
echo "$RAW" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null || {
  echo "ERROR: API returned non-JSON:"
  echo "$RAW" | head -5
  exit 1
}

REPOS=$(echo "$RAW" | python3 -c "
import sys, json
repos = json.load(sys.stdin)
if isinstance(repos, list):
    for r in repos:
        print(r['full_name'])
else:
    print('Unexpected response:', repos, file=sys.stderr)
    sys.exit(1)
")

if [ -z "$REPOS" ]; then
  echo "No repositories found."
  exit 0
fi

echo "Repos found:"
echo "$REPOS"
echo ""

ENCODED=$(python3 -c "
import base64, sys
content = sys.stdin.read()
print(base64.b64encode(content.encode()).decode())
" <<< "$NEW_WORKFLOW")

for REPO in $REPOS; do
  RESPONSE=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}")

  SHA=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('sha', ''))
except:
    print('')
" 2>/dev/null)

  if [ -z "$SHA" ]; then
    echo "  SKIP ${REPO} — workflow not found"
    continue
  fi

  echo "  UPDATE ${REPO}"

  RESULT=$(curl -s -X PUT \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}" \
    -d "{\"message\":\"fix: replace actions/checkout with pure git mirror (no node required)\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}")

  echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'content' in d:
        print('  OK')
    else:
        print('  ERROR:', d.get('message', str(d)))
except Exception as e:
    print('  ERROR parsing response:', e)
"
done

echo ""
echo "Done."
