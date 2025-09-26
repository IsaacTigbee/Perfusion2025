#!/usr/bin/env bash
# BIDS QC Helper Script
#
# Usage: ./datastructure.sh /path/to/dataset
#
# 1. Checks for DICOM files → converts to NIfTI (dcm2niix) and removes DICOMs.
# 2. Ensures dataset_description.json exists (creates minimal if missing).
# 3. Runs BIDS validator using deno.
# 4. Parses validator output and shows actionable fixes per error.
#
# Dependencies:
#   - dcm2niix in PATH
#   - deno in PATH (conda install -c conda-forge deno)

set -euo pipefail

err(){ echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/dataset"
  exit 1
fi

DATASET="$1"
[ -d "$DATASET" ] || err "Dataset directory not found: $DATASET"

# Step 1: Convert DICOMs → NIfTI if any exist
info "Checking for DICOM files in $DATASET ..."
DICOMS=$(find "$DATASET" -type f \( -iname "*.dcm" -o -iname "*.ima" \) | head -n 1 || true)
if [ -n "$DICOMS" ]; then
  info "Found DICOMs — converting with dcm2niix ..."
  dcm2niix -o "$DATASET" "$DATASET" >/dev/null 2>&1 || warn "dcm2niix failed"
  info "Deleting original DICOM files ..."
  find "$DATASET" -type f \( -iname "*.dcm" -o -iname "*.ima" \) -delete
else
  info "No DICOM files found — assuming NIfTI already present."
fi

# Step 2: Ensure dataset_description.json
if [ ! -f "$DATASET/dataset_description.json" ]; then
  warn "dataset_description.json not found — creating a minimal one."
  cat > "$DATASET/dataset_description.json" <<EOF
{
  "Name": "UntitledDataset",
  "BIDSVersion": "1.8.0"
}
EOF
  info "Created $DATASET/dataset_description.json"
fi

# Step 3: Run BIDS validator
VALIDATOR_LOG="$DATASET/bids_validator.log"
info "Running BIDS validator ..."
if ! deno run -ERWN jsr:@bids/validator "$DATASET" --ignoreWarnings | tee "$VALIDATOR_LOG"; then
  warn "BIDS validator finished with errors."
fi


# Step 4: Parse errors and suggest actionable fixes
if grep -q "\[ERROR\]" "$VALIDATOR_LOG"; then
  warn "Dataset has BIDS validation errors. See log above or in $VALIDATOR_LOG"
  echo ""
  echo "=== Suggested Fixes ==="
  echo ""
  awk '
    /^\s*\[ERROR\]/ {
      # Extract error code
      code=$2
      gsub(/[\[\]]/, "", code)
      print ""
      print $0
      # Print subsequent indented lines until a blank line or "Please visit"
      while (getline > 0) {
        if ($0 ~ /^$/) break
        if ($0 ~ /Please visit/) continue
        if ($0 ~ /^\s+\/.*/) print $0
      }
      # Suggestions
      if (code == "MISSING_DATASET_DESCRIPTION") {
        print "   ➡ Add a dataset_description.json at the root with fields: Name, BIDSVersion."
      } else if (code == "EMPTY_FILE") {
        print "   ➡ Remove empty files or replace with valid content."
      } else if (code == "NOT_INCLUDED") {
        print "   ➡ Rename files to follow BIDS spec or add them to .bidsignore."
      } else if (code == "INVALID_LOCATION") {
        print "   ➡ Move files into the correct BIDS folder (e.g., sub-<ID>/anat/, perf/, fmap/)."
      } else if (code == "JSON_INVALID") {
        print "   ➡ Fix JSON formatting. Run: jq . file.json > /dev/null to validate."
      } else if (code == "ALL_FILENAME_RULES_HAVE_ISSUES") {
        print "   ➡ Check filenames — they match multiple rules. Likely missing modality label (_asl, _T1w, etc)."
      } else if (code == "INTENDED_FOR") {
        print "   ➡ Ensure IntendedFor in JSON points to a valid relative path (e.g., sub-01/perf/sub-01_asl.nii.gz)."
      } else {
        print "   ➡ General BIDS issue: consult https://neurostars.org/tag/bids"
      }
    }
  ' "$VALIDATOR_LOG"
else
  info "✔ Dataset is BIDS valid!"
fi
