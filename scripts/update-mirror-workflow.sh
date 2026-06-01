#!/bin/bash

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

echo "Step 1: Fetching repo list from ${GITEA_URL}..."
RAW=$(curl -s --max-time 10 \
  -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/user/repos?limit=50")
CURL_EXIT=$?

echo "curl exit code: ${CURL_EXIT}"
echo "Response length: ${#RAW} bytes"
echo "Response preview: ${RAW:0:200}"
echo ""

if [ $CURL_EXIT -ne 0 ]; then
  echo "ERROR: curl failed with exit code ${CURL_EXIT}"
  exit 1
fi

if [ -z "$RAW" ]; then
  echo "ERROR: empty response"
  exit 1
fi

echo "Step 2: Parsing repo list..."
REPOS=$(echo "$RAW" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for r in data:
            print(r['full_name'])
    else:
        print('ERROR: unexpected JSON structure:', type(data).__name__, file=sys.stderr)
        sys.exit(1)
except json.JSONDecodeError as e:
    print('ERROR: invalid JSON:', e, file=sys.stderr)
    sys.exit(1)
")

if [ -z "$REPOS" ]; then
  echo "No repositories found."
  exit 0
fi

echo "Repos:"
echo "$REPOS"
echo ""

ENCODED=$(python3 -c "
import base64, sys
print(base64.b64encode(sys.stdin.read().encode()).decode())
" <<< "$NEW_WORKFLOW")

for REPO in $REPOS; do
  echo "Checking ${REPO}..."
  RESPONSE=$(curl -s --max-time 10 \
    -H "Authorization: token ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}")

  SHA=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('sha', ''))
except:
    print('')
")

  if [ -z "$SHA" ]; then
    echo "  SKIP — workflow not found"
    continue
  fi

  echo "  Updating (sha=${SHA})..."
  RESULT=$(curl -s --max-time 10 -X PUT \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}" \
    -d "{\"message\":\"fix: replace actions/checkout with pure git mirror (no node required)\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}")

  echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('  OK' if 'content' in d else '  ERROR: ' + d.get('message', str(d)))
except Exception as e:
    print('  ERROR:', e)
"
done

echo "Done."
