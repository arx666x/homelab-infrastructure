#!/bin/bash
set -euo pipefail

GITEA_URL="https://git.reckeweg.io"
GITEA_TOKEN="${GITEA_TOKEN:?GITEA_TOKEN env var required}"
GITEA_USER="achim"
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

# Alle Repos des Users abrufen
echo "Fetching repositories..."
REPOS=$(curl -sf -H "Authorization: token ${GITEA_TOKEN}" \
  "${GITEA_URL}/api/v1/repos/search?limit=50&uid=$(
    curl -sf -H "Authorization: token ${GITEA_TOKEN}" \
      "${GITEA_URL}/api/v1/users/${GITEA_USER}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"
  )" | python3 -c "import sys,json; [print(r['full_name']) for r in json.load(sys.stdin)['data']]")

echo "Found repos:"
echo "$REPOS"
echo ""

for REPO in $REPOS; do
  # Prüfen ob Workflow-Datei existiert
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "  SKIP ${REPO} — workflow not found"
    continue
  fi

  echo "  UPDATE ${REPO}"

  # SHA der aktuellen Datei holen (für Update erforderlich)
  SHA=$(curl -sf -H "Authorization: token ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")

  ENCODED=$(python3 -c "import base64, sys; print(base64.b64encode(sys.argv[1].encode()).decode())" "$NEW_CONTENT")

  curl -sf -X PUT \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITEA_URL}/api/v1/repos/${REPO}/contents/${WORKFLOW_PATH}" \
    -d "{
      \"message\": \"fix: replace actions/checkout with pure git mirror (no node required)\",
      \"content\": \"${ENCODED}\",
      \"sha\": \"${SHA}\"
    }" > /dev/null

  echo "  OK ${REPO}"
done

echo ""
echo "Done."
