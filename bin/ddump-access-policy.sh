#!/bin/bash

# Shared new-import authorization boundary. This file is sourced by ddump.sh.
# It has no ingest, helper-termination, file-mutation, or eject capability.

ddump_access_gate_binary() {
  local candidate
  if [[ -n "${DDUMP_ACCESS_GATE_BIN:-}" && -x "${DDUMP_ACCESS_GATE_BIN}" ]]; then
    printf '%s' "$DDUMP_ACCESS_GATE_BIN"
    return 0
  fi
  for candidate in \
    "${HOME}/Applications/DDump.app/Contents/Resources/Helpers/DDumpAccessGate" \
    "/Applications/DDump.app/Contents/Resources/Helpers/DDumpAccessGate"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

ddump_authorize_new_import() {
  if [[ "${PAID_ACCESS_ENFORCEMENT:-0}" != "1" ]]; then
    DDUMP_ACCESS_DECISION="legacy_allowed"
    export DDUMP_ACCESS_DECISION
    return 0
  fi

  local identity_dir entitlement_dir token_file account_file installation_file installation_key_hash_file gate output rc
  identity_dir="${STATE_DIR}/identity"
  entitlement_dir="${STATE_DIR}/entitlements"
  token_file="${entitlement_dir}/current.entitlement"
  account_file="${identity_dir}/account_id"
  installation_file="${identity_dir}/installation_id"
  installation_key_hash_file="${identity_dir}/installation_public_key_sha256"

  if [[ -z "${ENTITLEMENT_PUBLIC_KEYS:-}" ]]; then
    DDUMP_ACCESS_DECISION="indeterminate_public_key_missing"
    export DDUMP_ACCESS_DECISION
    return 1
  fi
  gate="$(ddump_access_gate_binary 2>/dev/null || true)"
  if [[ -z "$gate" ]]; then
    DDUMP_ACCESS_DECISION="indeterminate_verifier_missing"
    export DDUMP_ACCESS_DECISION
    return 1
  fi

  set +e
  output="$($gate verify \
    --token-file "$token_file" \
    --public-keys "$ENTITLEMENT_PUBLIC_KEYS" \
    --account-file "$account_file" \
    --installation-file "$installation_file" \
    --installation-key-hash-file "$installation_key_hash_file" \
    --issuer "${ENTITLEMENT_ISSUER:-https://api.ddump.app}" \
    --audience "${ENTITLEMENT_AUDIENCE:-com.ddump.app}" \
    --environment "${ENTITLEMENT_ENVIRONMENT:-test}" \
    --product-ids "${ENTITLEMENT_PRODUCT_IDS:-ddump_test_monthly,ddump_test_annual}" \
    --minimum-issued-at "${ENTITLEMENT_MINIMUM_ISSUED_AT:-0}" 2>/dev/null)"
  rc=$?
  set -e

  case "$rc" in
    0)
      DDUMP_ACCESS_DECISION="allowed"
      if [[ "$output" == *"refresh_required=1"* ]]; then
        DDUMP_ENTITLEMENT_REFRESH_REQUIRED="1"
      else
        DDUMP_ENTITLEMENT_REFRESH_REQUIRED="0"
      fi
      export DDUMP_ACCESS_DECISION DDUMP_ENTITLEMENT_REFRESH_REQUIRED
      return 0
      ;;
    2)
      DDUMP_ACCESS_DECISION="denied"
      ;;
    *)
      DDUMP_ACCESS_DECISION="indeterminate"
      ;;
  esac
  export DDUMP_ACCESS_DECISION
  return 1
}
