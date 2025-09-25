#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# BIDS dataset checker and minimal fixer
#
# Usage: ./check_bids.sh /path/to/dataset
#
# What it does:
#   1. Converts DICOM → NIfTI+JSON (dcm2niix), places them in BIDS subfolders
#   2. Deletes DICOM files after conversion
#   3. Runs BIDS validator (deno run jsr:@bids/validator)
#   4. Prints errors and adds suggested fixes
#
# Requirements:
#   - dcm2niix
#   - deno (for bids-validator)
# ---------------------------------------------------------------------------

err(){ echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }

if [ $# -ne 1 ]; then
  err "Usage: $0 /path/to/dataset"
fi

DATASET_ROOT="$1"
[ -d "$DATASET_ROOT" ] || err "Dataset folder not found: $DATASET_ROOT"

# 1. Convert DICOMs to NIfTI if present
info "Checking for DICOM files in $DATASET_ROOT ..."
dicoms=$(find "$DATASET_ROOT" -type f \( -iname "*.dcm" -o -iname "*.IMA" \) | head -n 1 || true)
if [ -n "$dicoms" ]; then
  info "Found DICOM files. Converting with dcm2niix ..."
  for dcm_dir in $(find "$DATASET_ROOT" -type d); do
    if ls "$dcm_dir"/*.{dcm,IMA} >/dev/null 2>&1; then
      subj=$(basename "$(dirname "$dcm_dir")")
      mkdir -p "$DATASET_ROOT/$subj/anat" "$DATASET_ROOT/$subj/perf" "$DATASET_ROOT/$subj/fmap"

      # Run dcm2niix
      dcm2niix -b y -z y -o "$dcm_dir" "$dcm_dir" >/dev/null 2>&1 || warn "dcm2niix failed in $dcm_dir"

      # Move outputs into rough BIDS subfolders
      for nii in "$dcm_dir"/*.nii.gz; do
        base=$(basename "$nii")
        if echo "$base" | grep -qi "t1"; then
          mv "$nii" "$DATASET_ROOT/$subj/anat/${subj}_T1w.nii.gz"
          [ -f "${nii%.nii.gz}.json" ] && mv "${nii%.nii.gz}.json" "$DATASET_ROOT/$subj/anat/${subj}_T1w.json"
        elif echo "$base" | grep -Eqi "asl|perf"; then
          mv "$nii" "$DATASET_ROOT/$subj/perf/${subj}_asl.nii.gz"
          [ -f "${nii%.nii.gz}.json" ] && mv "${nii%.nii.gz}.json" "$DATASET_ROOT/$subj/perf/${subj}_asl.json"
        elif echo "$base" | grep -qi "fieldmap"; then
          mv "$nii" "$DATASET_ROOT/$subj/fmap/${subj}_fieldmap.nii.gz"
          [ -f "${nii%.nii.gz}.json" ] && mv "${nii%.nii.gz}.json" "$DATASET_ROOT/$subj/fmap/${subj}_fieldmap.json"
        else
          warn "Unclassified file: $nii (leaving in place)"
        fi
      done

      # Delete original DICOMs
      rm -f "$dcm_dir"/*.{dcm,IMA} || true
    fi
  done
  info "DICOM conversion complete. DICOM files removed."
else
  info "No DICOM files found — assuming NIfTI already present."
fi

# 2. Run BIDS validator
info "Running BIDS validator ..."
deno run -ERWN jsr:@bids/validator "$DATASET_ROOT" --ignoreWarnings > "${DATASET_ROOT}/bids_validator.log" 2>&1 || true

# 3. Parse validator log and print errors + suggested fixes
if grep -q "ERROR" "${DATASET_ROOT}/bids_validator.log"; then
  warn "Dataset has BIDS validation errors:"
  grep "ERROR" "${DATASET_ROOT}/bids_validator.log"

  echo ""
  echo "=== Suggested Fixes ==="
  while IFS= read -r line; do
    if echo "$line" | grep -q "Missing"; then
      echo "➡ Add required JSON sidecars (with acquisition parameters)."
    elif echo "$line" | grep -q "Filename"; then
      echo "➡ Rename files to follow BIDS naming rules (sub-<ID>[_ses-<ID>]_modality.nii.gz)."
    elif echo "$line" | grep -q "json"; then
      echo "➡ Ensure JSON files exist and contain mandatory metadata."
    elif echo "$line" | grep -q "NIfTI"; then
      echo "➡ Check NIfTI headers (dims, TR, voxel size) and correct them."
    else
      echo "➡ General BIDS issue: $line"
    fi
  done < <(grep "ERROR" "${DATASET_ROOT}/bids_validator.log")
else
  info "✔ Dataset is BIDS valid!"
fi
