#!/usr/bin/env bash
# cbf_quant.sh
#
# Usage:
#   ./cbf_quant.sh /path/to/BIDS_dataset
#
# Dependencies:
#   fslmaths, oxasl, python3
#
# This script walks a BIDS dataset, removes NaNs from ASL using fslmaths,
# reads ASL and M0 JSON sidecars with Python, and runs oxasl with the
# extracted timings/options. Outputs are written under each subject/session
# in a "processed" directory. A summary CSV of perfusion metrics is written
# in the dataset root.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <BIDS_ROOT>"
  exit 1
fi

BIDS_ROOT="$(realpath "$1")"

# Check required commands
for cmd in fslmaths oxasl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
done

SUMMARY_CSV="${BIDS_ROOT}/cbf_quant_summary.csv"
echo "subject,session,mean_within_mask,gm_mean,pure_gm_mean,cortical_gm_mean,wm_mean,pure_wm_mean,cerebral_wm_mean" > "$SUMMARY_CSV"

shopt -s nullglob

# Iterate subjects
for subjdir in "$BIDS_ROOT"/sub-*; do
  [ -d "$subjdir" ] || continue
  subj=$(basename "$subjdir")
  echo "================ Processing ${subj} ================"

  # find sessions (if any). If none, process subject-level files
  ses_dirs=()
  for d in "$subjdir"/ses-*; do
    [ -d "$d" ] || continue
    ses_dirs+=("$d")
  done
  if [ ${#ses_dirs[@]} -eq 0 ]; then
    ses_dirs=("$subjdir")
  fi

  for sesdir in "${ses_dirs[@]}"; do
    if [ "$sesdir" = "$subjdir" ]; then
      ses_label="no-session"
      topdir="$subjdir"
    else
      ses_label=$(basename "$sesdir")
      topdir="$sesdir"
    fi

    echo "---- Processing ${subj}/${ses_label} ----"

    # Find ASL NIfTI
    ASL_IN=$(find "$topdir" -type f -path "*/perf/*asl*.nii*" -print -quit || true)
    ASL_JSON=""
    if [ -n "$ASL_IN" ]; then
      if [[ "$ASL_IN" == *.nii.gz ]]; then
        ASL_JSON="${ASL_IN%.nii.gz}.json"
      else
        ASL_JSON="${ASL_IN%.nii}.json"
      fi
    fi

    # Find M0 (broad search)
    M0_IN=$(find "$topdir" -type f \( -path "*/perf/*m0scan*.nii*" -o -path "*/perf/*M0*.nii*" -o -path "*/perf/*M0*.nii.gz" \) -print -quit || true)
    M0_JSON=""
    if [ -n "$M0_IN" ]; then
      if [[ "$M0_IN" == *.nii.gz ]]; then
        M0_JSON="${M0_IN%.nii.gz}.json"
      else
        M0_JSON="${M0_IN%.nii}.json"
      fi
    fi

    # Find structural T1w
    T1_IN=$(find "$topdir" -type f -path "*/anat/*T1w*.nii*" -print -quit || true)

    # Validate presence
    if [ -z "$ASL_IN" ]; then
      echo "WARNING: No ASL nifti found for ${subj}/${ses_label} - skipping"
      continue
    fi
    if [ -z "$ASL_JSON" ] || [ ! -f "$ASL_JSON" ]; then
      echo "WARNING: No ASL JSON sidecar found for ${ASL_IN}. Skipping ${subj}/${ses_label}."
      continue
    fi
    if [ -z "$M0_IN" ]; then
      echo "WARNING: No M0 file found for ${subj}/${ses_label} - skipping"
      continue
    fi
    if [ -z "$T1_IN" ]; then
      echo "WARNING: No T1w file found for ${subj}/${ses_label} - skipping"
      continue
    fi

    PROCDIR="${topdir}/processed"
    mkdir -p "$PROCDIR"

    # -----------------------
    # Parse ASL JSON with Python
    readarray -t JSON_OUT < <(python3 - "$ASL_JSON" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
def first(*keys):
    for k in keys:
        if k in j and j[k] is not None:
            return j[k]
    return None
plds = first("PostLabelingDelay","PostLabelingDelay_s","PLD")
tis  = first("TIs","TIs_s","InversionTimes")
tau  = first("LabelingDuration","LabelDuration")
tr = first("RepetitionTimePreparation","RepetitionTime")
asl_type = first("ArterialSpinLabelingType","ASLType","ASLContext")
def fmt(x):
    if x is None: return "null"
    if isinstance(x,list): return ",".join(str(v) for v in x)
    return str(x)
print(fmt(plds))
print(fmt(tis))
print(fmt(tau))
print(fmt(tr))
print(fmt(asl_type if asl_type is not None else "unknown"))
PY
)
    PLDS_RAW="${JSON_OUT[0]}"
    TIS_RAW="${JSON_OUT[1]}"
    TAU_RAW="${JSON_OUT[2]}"
    TR_RAW="${JSON_OUT[3]}"
    ASLTYPE_RAW="${JSON_OUT[4]}"

    PLDS=""; TIS=""; TAU=""; TR_VAL=""
    if [ "${PLDS_RAW:-}" != "null" ] && [ -n "${PLDS_RAW:-}" ]; then PLDS="$(echo "${PLDS_RAW}" | tr -d '[:space:]')"; fi
    if [ "${TIS_RAW:-}" != "null" ] && [ -n "${TIS_RAW:-}" ]; then TIS="$(echo "${TIS_RAW}" | tr -d '[:space:]')"; fi
    if [ "${TAU_RAW:-}" != "null" ] && [ -n "${TAU_RAW:-}" ]; then TAU="${TAU_RAW}"; fi
    if [ "${TR_RAW:-}" != "null" ] && [ -n "${TR_RAW:-}" ]; then TR_VAL="${TR_RAW}"; fi

    # -----------------------
    # Parse M0 JSON for TR
    TR_M0_VAL=""
    if [ -n "$M0_JSON" ] && [ -f "$M0_JSON" ]; then
      TR_M0_VAL=$(python3 - "$M0_JSON" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
tr = j.get("RepetitionTimePreparation") or j.get("RepetitionTime")
print(tr if tr is not None else "null")
PY
)
      [ "$TR_M0_VAL" = "null" ] && TR_M0_VAL=""
    fi

    # If neither PLDs nor TIs present, skip
    if [ -z "$PLDS" ] && [ -z "$TIS" ]; then
      echo "ERROR: Neither PLDs nor TIs found in JSON (${ASL_JSON}). Skipping ${subj}/${ses_label}."
      continue
    fi

    # --- Step: remove NaNs ---
    ASL_NONAN="${PROCDIR}/asl_nonan.nii.gz"
    echo "Removing NaNs: ${ASL_IN} -> ${ASL_NONAN}"
    fslmaths "$ASL_IN" -nan "$ASL_NONAN"
    if [ ! -f "$ASL_NONAN" ]; then
      echo "ERROR: Failed to create ${ASL_NONAN}. Skipping."
      continue
    fi

    # Build oxasl args
    OXASL_ARGS=(-i "$ASL_NONAN" --ibf=tis)

    # Determine iaf
    IAF="tc" # default
    ASLCONTEXT_TSV=$(find "$(dirname "$ASL_IN")" -maxdepth 1 -name "*aslcontext.tsv" -print -quit)
    if [ -n "$ASLCONTEXT_TSV" ] && [ -f "$ASLCONTEXT_TSV" ]; then
      FIRST_LINE=$(awk 'NR==2 {print tolower($1)}' "$ASLCONTEXT_TSV")
      if [[ "$FIRST_LINE" == "control" ]]; then
        IAF="ct"
      elif [[ "$FIRST_LINE" == "label" ]]; then
        IAF="tc"
      fi
    fi
    OXASL_ARGS+=(--iaf "$IAF")

    asltype_lc=$(echo "$ASLTYPE_RAW" | tr '[:upper:]' '[:lower:]' 2>/dev/null || true)
    if [[ "$asltype_lc" == "casl" || "$asltype_lc" == "pcasl" ]]; then
      OXASL_ARGS+=(--casl)
    fi

    if [ -n "$PLDS" ]; then OXASL_ARGS+=(--plds "${PLDS}"); fi
    if [ -n "$TIS" ]; then OXASL_ARGS+=(--tis "${TIS}"); fi
    if [ -n "$TAU" ]; then OXASL_ARGS+=(--tau "${TAU}"); fi
    # Prefer TR from M0 JSON
    if [ -n "$TR_M0_VAL" ]; then
      OXASL_ARGS+=(--tr "${TR_M0_VAL}")
    elif [ -n "$TR_VAL" ]; then
      OXASL_ARGS+=(--tr "${TR_VAL}")
    fi

    OXASL_ARGS+=(--calib "$M0_IN" --calib-method=voxelwise)
    OXASL_ARGS+=(--struc "$T1_IN")
    OXASL_ARGS+=(--mc)
    OXASL_ARGS+=(-o "$PROCDIR")
    OXASL_ARGS+=(--save-input --save-preproc --save-quantification \
                 --save-calib --save-reg --save-asl-masks --save-struct-rois)
    OXASL_ARGS+=(--overwrite)

    echo "Running oxasl for ${subj}/${ses_label}:"
    echo "  oxasl ${OXASL_ARGS[*]}"
    if oxasl "${OXASL_ARGS[@]}"; then
      REPORT_FILE=$(find "$PROCDIR" -type f \( -name "perfusion_voxelwise_standard.rst" -o -name "perfusion_voxelwise_standard.rst.txt" \) | head -n 1)
      if [ -n "$REPORT_FILE" ] && [ -f "$REPORT_FILE" ]; then
        readarray -t METRICS < <(grep -E "Mean within mask|GM mean,|Pure GM mean|Cortical GM mean|WM mean,|Pure WM mean|Cerebral WM mean" "$REPORT_FILE" | awk -F',' '{print $2}' | sed 's/ ml.*//')
        if [ "${#METRICS[@]}" -eq 7 ]; then
          echo "${subj},${ses_label},${METRICS[0]},${METRICS[1]},${METRICS[2]},${METRICS[3]},${METRICS[4]},${METRICS[5]},${METRICS[6]}" >> "$SUMMARY_CSV"
        else
          echo "WARNING: Could not parse metrics for ${subj}/${ses_label}"
          echo "${subj},${ses_label},NA,NA,NA,NA,NA,NA,NA" >> "$SUMMARY_CSV"
        fi
      else
        echo "WARNING: Report file not found for ${subj}/${ses_label}"
        echo "${subj},${ses_label},NA,NA,NA,NA,NA,NA,NA" >> "$SUMMARY_CSV"
      fi
    else
      echo "oxasl failed for ${subj}/${ses_label}"
      echo "${subj},${ses_label},FAIL,FAIL,FAIL,FAIL,FAIL,FAIL,FAIL" >> "$SUMMARY_CSV"
    fi

  done
done

echo "All done. Summary CSV: $SUMMARY_CSV"
