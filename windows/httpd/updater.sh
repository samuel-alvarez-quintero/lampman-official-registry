#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Lampman Apache HTTP Server Registry Updater for Windows builds
# --------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$ROOT_DIR/registry.json"
TMP_JSON="$(mktemp)"
BASE_URL="https://www.apachelounge.com"
DOWNLOAD_URL="$BASE_URL/download/"
USER_AGENT="Lampman-RegistryBot/1.0 (+https://github.com/lampman-cli/Lampman)"

# Initialize registry file if missing
[[ -f "$REGISTRY_FILE" ]] || echo "{}" > "$REGISTRY_FILE"

# Initialize temporal json file if missing
echo "{}" > "$TMP_JSON"

# --------------------------------------------
# Function: HEAD request check
# --------------------------------------------
check_url() {
  local url="$1"
  local status
  status=$(curl -A "$USER_AGENT" -s -o /dev/null -w "%{http_code}" -I "$url")
  [[ "$status" == "200" ]]
}

# Fetch and parse links
echo "Fetching links..."
DOWNLOAD_LINKS="$(mktemp)"
HTML_CONTENT=$(curl -A "$USER_AGENT" -sSL "$DOWNLOAD_URL")
echo "$HTML_CONTENT" | \
  grep -Eo "/download/([a-zA-Z0-9\-]+)/binaries/([a-zA-Z0-9.=_-]+)\.zip" | \
  jq -R . | jq -s . | jq --arg base "$BASE_URL" 'map($base + .)' | jq '. |= unique' > "$DOWNLOAD_LINKS"

# Convert URLs into objects categorized by filename patterns
echo "Processing links..."
jq -r '.[]' "$DOWNLOAD_LINKS" | while read -r url; do
  filename=$(basename "$url")

  version=$(echo "$filename" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

  [[ -z "$version" ]] && continue
  
  arch=$(echo "$filename" | grep -Eo '(w|W)in(32|64)-([a-zA-Z0-9\-]+)' | head -1)
  arch=$(echo "${arch,,}")
  filename=$(echo "${filename,,}")

  [[ -z "$arch" ]] && continue

  jq \
    --arg version "$version" \
    --arg path "$filename" \
    --arg build "$arch" \
    --arg url "$url" \
    '
    .[$version][$build] = {
      path: $path,
      url: $url,
      sha256: null
    }
    ' "$TMP_JSON" > "${TMP_JSON}.new"

  mv "${TMP_JSON}.new" "$TMP_JSON"
done

# --------------------------------------------
# Transform to Lampman registry format
# --------------------------------------------
echo "Transforming releases data to Lampman registry format..."
FINAL_JSON="$(mktemp)"
jq -n \
  --arg desc "Official Apache HTTP Server Lampman Registry for Windows" \
  --arg base "$BASE_URL" \
  --slurpfile data "$TMP_JSON" '
{
  "Version": "latest",
  "Description": $desc,
  "LastRequest": null,
  "Services": {
    "httpd": (
      $data[0]
      | to_entries
      | map(
          .value
          | to_entries
          | map(select(.key | test("^(w|W)in(32|64)-([a-zA-Z0-9-]+)$"; "i"))
              | {
                  (.value.path[:-4]): {
                    "Url": .value.url,
                    "Verified": (.value.url != null),
                    "Tags": ["release", "prod"],
                    "ExtractTo": null,
                    "Checksum": { "SHA256": .value.sha256 }
                  }
                }
            )
          | add
        )
      | add
    )
  }
}' > "$FINAL_JSON"

# --------------------------------------------
# Validate URLs before finalizing
# --------------------------------------------
# Process ONLY entries where Verified == false

jq -r '
.Services.httpd
| to_entries[]
| select(.value.Verified == false)
| .value.Url
' "$FINAL_JSON" | while read -r url; do

  echo "Checking: $url"

  if check_url "$url"; then
    echo "OK: $url"

    # Mark as Verified = true
    jq --arg url "$url" '
      .Services.httpd |= with_entries(
        if .value.Url == $url then
          .value.Verified = true
        else
          .
        end
      )
    ' "$FINAL_JSON" > "${FINAL_JSON}.tmp"

    mv "${FINAL_JSON}.tmp" "$FINAL_JSON"

  else
    echo "FAILED: $url (removing entry)"

    # Delete entry entirely
    jq "del(.Services.httpd[] | select(.Url == \"$url\"))" "${FINAL_JSON}" > "${FINAL_JSON}.tmp"

    mv "${FINAL_JSON}.tmp" "$FINAL_JSON"
  fi

done


# --------------------------------------------
# Write to registry.json
# --------------------------------------------
mv "$FINAL_JSON" "$REGISTRY_FILE"
rm -f $TMP_JSON
rm -f $FINAL_JSON

echo "Registry updated successfully."