#!/usr/bin/env bash
# =============================================================================
# upload-workshop-assets.sh
# =============================================================================
# Publishes the participant assets to the S3 bucket the IDE and the Hyper-V host
# read from:
#
#   assets/workshop/  ->  s3://<bucket>/<prefix>workshop/  ->  ~/workshop in the IDE
#                                                          ->  cloud-init seeds of the two VMs
#
# WHY THIS IS A SEPARATE STEP: eks-hybrid-code-editor.yaml seeds ~/workshop from
# the bucket, and SKIPS that step silently when the bucket is empty or not passed.
# eks-hybrid-hyperv-host.yaml reads the VM seeds from the same place and fails at
# CreateVMs without them. Nothing uploads them for you: run this before you deploy
# the IDE stack.
#
# USAGE
#   ./scripts/upload-workshop-assets.sh <bucket> [region] [aws-profile] [prefix]
#
#   VERIFY_ONLY=1 ./scripts/upload-workshop-assets.sh <bucket> [region] ...
#     checks the local files and what is already in the bucket, without uploading.
#
# SUPPORTED ENVIRONMENT: bash 3.2+ on macOS or Linux, or AWS CloudShell.
#
# What it guarantees, in order:
#   1. the 12 expected files exist locally, none is empty, the user-data seeds are
#      at least 200 bytes, and nothing else is under assets/workshop/ (no AWS call yet)
#   2. the bucket is not public (get-bucket-policy-status IsPublic=true aborts)
#   3. aws s3 sync --delete --exact-timestamps
#   4. the bucket holds exactly the 12 keys, each with the local size and, under
#      SSE-S3, the local MD5 as its ETag
# Exit code 0 only when all of that holds. Any divergence exits 1 naming the key.
# =============================================================================
set -euo pipefail

BUCKET="${1:-}"
REGION="${2:-us-east-1}"
PROFILE="${3:-}"
PREFIX="${4:-}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"

if [[ -z "$BUCKET" ]]; then
  echo "ERROR: bucket name required." >&2
  echo "usage: $0 <bucket> [region] [aws-profile] [prefix]" >&2
  exit 1
fi

# set -u aborts on "${arr[@]}" when the array is empty, so guard the expansion.
PROFILE_ARG=()
[[ -n "$PROFILE" ]] && PROFILE_ARG=(--profile "$PROFILE")
aws_() { aws "$@" --region "$REGION" ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"}; }

file_md5 () { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
              elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
              else openssl dgst -md5 "$1" | awk '{print $NF}'; fi; }
file_size () { wc -c < "$1" | tr -d ' '; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/assets/workshop"
DEST_PREFIX="${PREFIX}workshop/"

EXPECTED=(
  dashboards/hybrid-nodes.json
  manifests/image-prepuller.yaml
  manifests/inference-burstable.yaml
  manifests/inference-gpu.yaml
  manifests/inference-onprem.yaml
  manifests/inference-service-lb.yaml
  manifests/onprem-monitoring.yaml
  scripts/preflight-check.sh
  seeds/meta-data-1
  seeds/meta-data-2
  seeds/user-data-1.yaml
  seeds/user-data-2.yaml
)
TOTAL=${#EXPECTED[@]}

is_expected () {
  local e
  for e in "${EXPECTED[@]}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

# --- 1. Local files: present, not empty, seeds big enough, nothing unexpected --
errors=0
for rel in "${EXPECTED[@]}"; do
  f="${SRC}/${rel}"
  if [[ ! -s "$f" ]]; then
    echo "ERROR: missing or empty: assets/workshop/${rel}" >&2; errors=1; continue
  fi
  case "$rel" in
    seeds/user-data-*)
      n=$(file_size "$f")
      if [[ "$n" -lt 200 ]]; then
        echo "ERROR: assets/workshop/${rel} is ${n} bytes; the Hyper-V host rejects a seed under 200 bytes" >&2
        errors=1
      fi ;;
  esac
done
while IFS= read -r f; do
  rel="${f#"${SRC}"/}"
  is_expected "$rel" || { echo "ERROR: unexpected file assets/workshop/${rel} (remove it, it would be uploaded)" >&2; errors=1; }
done < <(find "$SRC" -type f)
[[ "$errors" -eq 0 ]] || { echo "Aborted before any AWS call." >&2; exit 1; }
echo "Local: ${TOTAL}/${TOTAL} files present under assets/workshop/"

if [[ "$VERIFY_ONLY" != "1" ]]; then
  # --- 2. Fail closed on exposure --------------------------------------------
  if status_out=$(aws_ s3api get-bucket-policy-status --bucket "$BUCKET" \
        --query 'PolicyStatus.IsPublic' --output text 2>&1); then
    if [[ "$status_out" == "True" || "$status_out" == "true" ]]; then
      echo "ERROR: s3://${BUCKET} has a public bucket policy (IsPublic=true). Refusing to upload." >&2
      exit 1
    fi
  elif [[ "$status_out" != *NoSuchBucketPolicy* ]]; then
    echo "ERROR: cannot read the policy status of s3://${BUCKET}: ${status_out}" >&2
    exit 1
  fi

  # --- 3. Upload -------------------------------------------------------------
  echo "Publishing assets/workshop/ to s3://${BUCKET}/${DEST_PREFIX}"
  aws_ s3 sync "${SRC}/" "s3://${BUCKET}/${DEST_PREFIX}" --delete --exact-timestamps
fi

# --- 4. Assert what is in the bucket -------------------------------------------
keys=$(aws_ s3api list-objects-v2 --bucket "$BUCKET" --prefix "$DEST_PREFIX" \
        --query 'Contents[].Key' --output text)
rc=0
remote_n=0
for k in $keys; do
  [[ "$k" == "None" ]] && continue
  remote_n=$((remote_n + 1))
  is_expected "${k#"$DEST_PREFIX"}" || { echo "ERROR: unexpected object s3://${BUCKET}/${k}" >&2; rc=1; }
done

first_sse=""
verified=0
for rel in "${EXPECTED[@]}"; do
  key="${DEST_PREFIX}${rel}"
  if ! meta=$(aws_ s3api head-object --bucket "$BUCKET" --key "$key" \
        --query '[ContentLength,ETag,ServerSideEncryption]' --output text 2>/dev/null); then
    echo "ERROR: missing in the bucket: ${key}" >&2; rc=1; continue
  fi
  read -r remote_size etag sse <<< "$meta"
  etag="${etag//\"/}"
  [[ -n "$first_sse" ]] || first_sse="$sse"
  local_size=$(file_size "${SRC}/${rel}")
  if [[ "$remote_size" != "$local_size" ]]; then
    echo "ERROR: size mismatch for ${key}: bucket ${remote_size}, local ${local_size}" >&2; rc=1; continue
  fi
  if [[ "$sse" == "AES256" ]]; then
    local_md5=$(file_md5 "${SRC}/${rel}")
    if [[ "$etag" != "$local_md5" ]]; then
      echo "ERROR: content mismatch for ${key}: ETag ${etag}, local MD5 ${local_md5}" >&2; rc=1; continue
    fi
  else
    echo "WARN: ETag not comparable under ${sse} for ${key}"
  fi
  verified=$((verified + 1))
done

if [[ "$remote_n" -ne "$TOTAL" ]]; then
  echo "ERROR: s3://${BUCKET}/${DEST_PREFIX} holds ${remote_n} objects, expected ${TOTAL}" >&2
  rc=1
fi

echo "SSE: ${first_sse:-unknown}"
if [[ "$rc" -ne 0 ]]; then
  echo "FAILED: ${verified}/${TOTAL} objects verified under s3://${BUCKET}/${DEST_PREFIX}" >&2
  exit 1
fi
echo "OK: ${verified}/${TOTAL} objects verified under s3://${BUCKET}/${DEST_PREFIX}"
