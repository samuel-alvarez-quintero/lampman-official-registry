#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Lampman PHP Registry Updater for Windows builds
# --------------------------------------------

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$ROOT_DIR/registry.json"
TMP_JSON="$(mktemp)"
BASE_URL="https://windows.php.net/downloads/releases"

echo "Fetching PHP releases.json from $BASE_URL"
curl -sSL "$BASE_URL/releases.json" -o "$TMP_JSON"

# Initialize registry files if missing
[[ -f "$REGISTRY_FILE" ]] || echo "{}" > "$REGISTRY_FILE"

# --------------------------------------------
# Transform to Lampman registry format
# --------------------------------------------
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
              select(.key | test("^(ts|nts)-(vc15|vs16|vs17)-(x86|x64)$"; "i"))
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
}' > "${TMP_JSON}.lampman"

# Merge result into existing registry.json
jq -s '.[0] * .[1]' "$REGISTRY_FILE" "${TMP_JSON}.lampman" > "${REGISTRY_FILE}.new"
mv "${REGISTRY_FILE}.new" "$REGISTRY_FILE"

rm -f "$TMP_JSON" "${TMP_JSON}.lampman"
echo "Updated Lampman PHP registry successfully."
