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
ARCHIVES_URL="$BASE_URL/archives/"

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

# Fetch and parse archive links
echo "Fetching archive links..."
ARCHIVE_LINKS="$(mktemp)"
HTML_CONTENT=$(curl -sSL "$ARCHIVES_URL")
echo "$HTML_CONTENT" | \
  grep -Eo "downloads/releases/archives/[a-zA-Z0-9./?=_%:-]*\.zip" | \
  jq -R . | jq -s . | jq 'map("https://windows.php.net/" + .)' > "$ARCHIVE_LINKS"


# Convert archive URLs into objects categorized by filename patterns
echo "Processing archive links..."
jq -r '.[]' "$ARCHIVE_LINKS" | while read -r url; do
  filename=$(basename "$url")

  # Identify type by pattern
  case "$filename" in
    *debug-pack*.zip)  kind="debug_pack" ;;
    *devel-pack*.zip)  kind="devel_pack" ;;
    *test-pack*.zip)   kind="test_pack" ;;
    *src*.zip)         kind="source" ;;
    php-*.zip)         kind="zip" ;;
    *) continue ;;
  esac

  version=$(echo "$filename" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

  [[ -z "$version" ]] && continue

  if [ "$kind" == "debug_pack" -o "$kind" == "devel_pack" -o "$kind" == "zip" ]; then
  
    arch=$(echo "$filename" | grep -Eo '(-nts)?-Win32(-([a-zA-Z0-9]+)-(x86|x64))?' | head -1)
    arch=$(echo "${arch,,}" | sed 's/-win32//g')
    arch=$(echo "${arch:1}")

    [[ -z "$arch" ]] && continue

    jq \
      --arg version "$version" \
      --arg build "$arch" \
      --arg kind "$kind" \
      --arg path "$filename" \
      --arg url "$url" \
      '
      .[$version][$build][$kind] = {
        path: $path,
        url: $url,
        sha256: null
      }
      ' "$TMP_JSON" > "${TMP_JSON}.new"
  else

    if [ "$kind" == "source" -o "$kind" == "test_pack" ]; then

      jq \
      --arg version "$version" \
      --arg kind "$kind" \
      --arg path "$filename" \
      --arg url "$url" \
      '
      .[$version][$kind] = {
        path: $path,
        url: $url
      }
      ' "$TMP_JSON" > "${TMP_JSON}.new"

    fi
  fi

  mv "${TMP_JSON}.new" "$TMP_JSON"
done

# --------------------------------------------
# Transform to Lampman registry format
# --------------------------------------------
echo "Transforming releases data to Lampman registry format..."
FINAL_JSON="$(mktemp)"
jq -n \
  --arg desc "Official PHP Lampman Registry for Windows" \
  --arg base "$BASE_URL" \
  --slurpfile data "$TMP_JSON" '
{
  "Version": "latest",
  "Description": $desc,
  "LastRequest": null,
  "Services": {
    "php": (
      $data[0]
      | to_entries
      | map(
          .value
          | to_entries
          | map(select(.key | test("^(nts-|ts-)?([a-zA-Z0-9]+)-(x86|x64)$"; "i"))
              | {
                  (.value.zip.path[:-4]): {
                    "Url": (.value.zip.url // ($base + "/" + .value.zip.path)),
                    "Verified": (.value.zip.url != null),
                    "Tags": (if .value.zip.url? then ["archive", "prod"] else ["release", "prod"] end),
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
                      "dev": { "Configuration": null, "Requirements": null },
                      "prod": { "Configuration": null, "Requirements": null }
                    }
                  }
                } 

                + (if .value.debug_pack? then                         # 2) DEBUG PACK
                    {
                      (.value.debug_pack.path[:-4]): {
                        "Url": (.value.debug_pack.url // ($base + "/" + .value.debug_pack.path)),
                        "Verified": (.value.debug_pack.url != null),
                        "Tags": (if .value.debug_pack.url? then ["archive", "debug"] else ["release", "debug"] end),
                        "ExtractTo": null,
                        "Checksum": { "SHA256": .value.debug_pack.sha256 },
                        "Processes": [],
                        "Profiles": null
                      }
                    }
                  else {} end)

                + (if .value.devel_pack? then                         # 3) DEVEL PACK
                    {
                      (.value.devel_pack.path[:-4]): {
                        "Url":      (.value.devel_pack.url // ($base + "/" + .value.devel_pack.path)),
                        "Verified": (.value.devel_pack.url != null),
                        "Tags": (if .value.devel_pack.url? then ["archive", "devel"] else ["release", "devel"] end),
                        "ExtractTo": null,
                        "Checksum": { "SHA256": .value.devel_pack.sha256 },
                        "Processes": [],
                        "Profiles": null
                      }
                    }
                  else {} end)
            )
            + map(select(.key | test("^(source|test_pack)$"; "i"))
                | {
                    (.value.path[:-4]): {
                      "Url": (.value.url // ($base + "/" + .value.path)),
                      "Verified": (.value.url != null),
                      "Tags": (if .key == "source" then ["source"] else ["test"] end),
                      "ExtractTo": null,
                      "Checksum": { "SHA256": .value.sha256 },
                      "Processes": [],
                      "Profiles": null
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
.Services.php
| to_entries[]
| select(.value.Verified == false)
| .value.Url
' "$FINAL_JSON" | while read -r url; do

  echo "Checking: $url"

  if check_url "$url"; then
    echo "OK: $url"

    # Mark as Verified = true
    jq --arg url "$url" '
      .Services.php |= with_entries(
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
    jq "del(.Services.php[] | select(.Url == \"$url\"))" "${FINAL_JSON}" > "${FINAL_JSON}.tmp"

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