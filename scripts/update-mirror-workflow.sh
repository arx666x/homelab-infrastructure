#!/bin/bash
set -euo pipefail

GITEA_URL="https://git.reckeweg.io"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN env var required}"
WORKFLOW_PATH=".gitea/workflows/mirror-to-sailpoint.yml"

NEW_CONTENT='name: Mirror to SailPoint GitHub

on:
  push:
    branches:
      - '"'"'**'"'"'
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

api() {
  curl -s -H "Authorization: token ${GITEA_TOKEN}" "$@"
}

echo "Fetching repositories..."
REPOS=$(api "${GITEA_URL}/api/v1/user/repos?limit=50" | \
  python3 -c "import sys,json; [print(r['full_name']) for r in json.load(sys.stdin)]")

if [ -z "$REPOS" ]; then
  echo "No repositories found. Check your GITEA_TOKEN."
  exit 1
fi

echo "Repos found:"
echo "$REPOS"
echo ""

for REPO in $REPOS; do
  RESPONSE=$(api "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}")
  SHA=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sha'])" 2>/dev/null || true)

  if [ -z "$SHA" ]; then
    echo "  SKIP ${REPO} — workflow not found"
    continue
  fi

  echo "  UPDATE ${REPO} (sha=${SHA})"

  ENCODED=$(python3 -c "import base64,sys; print(base64.b64encode(open('/dev/stdin').read().encode()).decode())" <<< "$NEW_CONTENT")

  api -X PUT \
    -H "Content-Type: application/json" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}" \
    -d "{
      \"message\": \"fix: replace actions/checkout with pure git mirror (no node required)\",
      \"content\": \"${ENCODED}\",
      \"sha\": \"${SHA}\"
    }" | python3 -c "import sys,json; d=json.load(sys.stdin); print('  OK' if 'content' in d else '  ERROR: '+str(d))"
done

echo ""
echo "Done."
