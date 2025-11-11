#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Lampman PHP Registry Updater for Windows builds
# --------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$ROOT_DIR/registry.json"
TMP_JSON="$(mktemp)"
BASE_URL="https://windows.php.net/downloads/releases"
RELEASES_URL="$BASE_URL/releases.json"

echo "Fetching PHP releases.json from $RELEASES_URL"
curl -sSL "$RELEASES_URL" -o "$TMP_JSON"

# Initialize registry files if missing
[[ -f "$REGISTRY_FILE" ]] || echo "{}" > "$REGISTRY_FILE"

# --------------------------------------------
# Function: HEAD request check
# --------------------------------------------
check_url() {
  local url="$1"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -I "$url")
  [[ "$status" == "200" ]]
}

# --------------------------------------------
# Transform to Lampman registry format
# --------------------------------------------
echo "Transforming releases data to Lampman registry format..."
FINAL_JSON="$(mktemp)"
jq -n \
  --arg desc "Official PHP Lampman Registry for Windows" \
  --arg base "$BASE_URL" \
  --argjson data "$(jq '.' "$TMP_JSON")" '
{
  "Version": "latest",
  "Description": $desc,
  "LastRequest": null,
  "Services": {
    "php": (
      $data
      | to_entries
      | map(
          .value
          | to_entries
          | map(
              select(.key | test("^(nts|ts)-(vc15|vs16|vs17)-(x86|x64)$"; "i"))
              | {
                  (.value.zip.path[:-4]): {
                    "Url": ($base + "/" + .value.zip.path),
                    "ExtractTo": null,
                    "Checksum": { "SHA256": .value.zip.sha256 },
                    "Processes": [
                      {
                        "Name": "php.exe",
                        "Version": .value.version,
                        "ExePath": ".",
                        "Args": null,
                        "isExtention": false,
                        "ItDependsOn": null,
                        "MustBeDemonizing": false,
                        "AvailableToPathEnvVar": true
                      }
                    ],
                    "Profiles": {
                      "dev": {"Configuration": null,"Requirements": null},
                      "prod": {"Configuration": null,"Requirements": null}
                    }
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
echo "Validating download URLs..."
jq -r '.Services.php[]?.Url' "${FINAL_JSON}" | while read -r url; do
  if ! check_url "$url"; then
    echo "Warning: $url not reachable, removing..."
    jq "del(.Services.php[] | select(.Url==\"$url\"))" "${FINAL_JSON}" > "${FINAL_JSON}.tmp"
    mv "${FINAL_JSON}.tmp" "${FINAL_JSON}"
  fi
done

# --------------------------------------------
# Write to registry.json
# --------------------------------------------
mv "$FINAL_JSON" "$REGISTRY_FILE"
rm -f "$TMP_JSON"

echo "Registry updated successfully."