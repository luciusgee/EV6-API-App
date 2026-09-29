#!/usr/bin/env bash
# Makes sure each extension bundle ID (widgets, Watch app) is registered and has an App Store
# provisioning profile, and saves the profiles where `xcode-project use-profiles` finds them.
# Runs on Codemagic with the App Store Connect API key from the integration; never needs a person
# in the Apple Developer portal. Usage: scripts/ensure-profiles.sh com.example.app.widgets ...
set -euo pipefail

asc() { app-store-connect "$@" --json; }
ids() { python3 -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; print(" ".join(x["id"] for x in d))'; }

CERTS=$(asc certificates list --type DISTRIBUTION IOS_DISTRIBUTION | ids)
if [ -z "$CERTS" ]; then
  echo "No distribution certificate in the team." >&2
  exit 1
fi

for BUNDLE in "$@"; do
  RESOURCE=$(asc bundle-ids list --bundle-id-identifier "$BUNDLE" --strict-match-identifier | ids)
  if [ -z "$RESOURCE" ]; then
    echo "Registering $BUNDLE"
    RESOURCE=$(asc bundle-ids create "$BUNDLE" --platform IOS | ids)
  fi
  ACTIVE=$(asc bundle-ids profiles --bundle-ids "$RESOURCE" --type IOS_APP_STORE --state ACTIVE | ids)
  if [ -z "$ACTIVE" ]; then
    echo "Creating an App Store profile for $BUNDLE"
    # shellcheck disable=SC2086
    app-store-connect profiles create "$RESOURCE" --type IOS_APP_STORE \
      --certificate-ids $CERTS --name "$BUNDLE App Store $(date +%Y%m%d%H%M)" --save
  else
    app-store-connect bundle-ids profiles --bundle-ids "$RESOURCE" --type IOS_APP_STORE --state ACTIVE --save
  fi
done
