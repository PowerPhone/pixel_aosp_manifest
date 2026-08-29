#!/usr/bin/env bash

# Require the full Android shell before a stock-runtime audit. A fresh Pixel
# can enumerate as an authorized-looking `device` while Setup Wizard exposes
# only its restricted Trade-In Mode service. Keep this diagnostic read-only:
# discard both command outputs because getstatus can contain hardware IDs.
cubs_require_normal_stock_adb_shell() {
  local adb_path=$1 serial=$2

  [[ -n "$adb_path" && -n "$serial" && "$serial" != -* && \
     ! "$serial" =~ [[:space:]] ]] || \
    die "invalid ADB selection for the normal-shell preflight"

  if timeout 20 "$adb_path" -s "$serial" shell -T -x true \
      >/dev/null 2>&1; then
    return 0
  fi

  if timeout 20 "$adb_path" -s "$serial" shell tradeinmode getstatus \
      >/dev/null 2>&1; then
    die "Android is in the restricted Trade-In Mode foyer; finish Setup Wizard on the phone, then enable normal USB debugging, authorize this host, and retry"
  fi

  die "the selected ADB transport cannot open a normal shell; finish Setup Wizard on the phone, then enable normal USB debugging, authorize this host, and retry"
}
