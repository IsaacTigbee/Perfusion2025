#!/usr/bin/env bash
# run_bids_asl_pipeline.sh
# Walk a BIDS dataset, remove NaNs from ASL using fslmaths, read ASL and M0 JSON sidecars with Python,
# build per-run YAML summary and run oxasl with extracted timings/options.
#
# Usage:
#   ./run_bids_asl_pipeline.sh /path/to/BIDS_root
#
# Requirements: fslmaths, oxasl, python3
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
    # determine a label for yaml naming
    if [ "$sesdir" = "$subjdir" ]; then
      ses_label="no-session"
      topdir="$subjdir"
    else
      ses_label=$(basename "$sesdir")
      topdir="$sesdir"
    fi

    echo "---- Processing ${subj}/${ses_label} ----"

    # Find ASL NIfTI (perf/)
    ASL_IN=$(find "$topdir" -type f -path "*/perf/*asl*.nii*" -print -quit || true)
    ASL_JSON=""
    if [ -n "$ASL_IN" ]; then
      if [[ "$ASL_IN" == *.nii.gz ]]; then
        ASL_JSON="${ASL_IN%.nii.gz}.json"
      else
        ASL_JSON="${ASL_IN%.nii}.json"
      fi
    fi

    # Find M0
    M0_IN=$(find "$topdir" -type f \( -path "*/perf/*m0scan*.nii*" -o -path "*/perf/*M0*.nii*" -o -path "*/perf/*M0*.nii.gz" \) -print -quit || true)
    M0_JSON=""
    if [ -n "$M0_IN" ]; then
      if [[ "$M0_IN" == *.nii.gz ]]; then
        M0_JSON="${M0_IN%.nii.gz}.json"
      else
        M0_JSON="${M0_IN%.nii}.json"
      fi
    fi

    # Structural T1w
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
p=sys.argv[1]
j=json.load(open(p))
def first(*keys):
    for k in keys:
        if k in j and j[k] is not None:
            return j[k]
    return None
plds = first("PostLabelingDelay","PostLabelingDelay_s","PLD")
tis  = first("TIs","TIs_s","InversionTimes")
tau  = first("LabelingDuration","LabelDuration")
slice_t = first("SliceTiming")
tr = first("RepetitionTimePreparation","RepetitionTime")
asltype = first("ArterialSpinLabelingType","ASLType","ASLContext")
def fmt(x):
    if x is None: return "null"
    if isinstance(x,list): return ",".join(str(v) for v in x)
    return str(x)
slicedt_ms = "null"
try:
    if slice_t and isinstance(slice_t,list) and len(slice_t)>=2:
        sdt = (float(slice_t[1]) - float(slice_t[0])) * 1000.0
        slicedt_ms = str(sdt)
except Exception:
    slicedt_ms = "null"
print(fmt(plds))
print(fmt(tis))
print(fmt(tau))
print(slicedt_ms)
print(fmt(tr))
print(fmt(asltype if asltype is not None else "unknown"))
PY
)

    PLDS_RAW="${JSON_OUT[0]}"
    TIS_RAW="${JSON_OUT[1]}"
    TAU_RAW="${JSON_OUT[2]}"
    SLICEDT_MS_RAW="${JSON_OUT[3]}"
    TR_RAW="${JSON_OUT[4]}"
    ASLTYPE_RAW="${JSON_OUT[5]}"

    PLDS=""; TIS=""; TAU=""; SLICEDT_MS=""; TR_VAL=""
    if [ "${PLDS_RAW:-}" != "null" ] && [ -n "${PLDS_RAW:-}" ]; then PLDS="$(echo "${PLDS_RAW}" | tr -d '[:space:]')"; fi
    if [ "${TIS_RAW:-}" != "null" ] && [ -n "${TIS_RAW:-}" ]; then TIS="$(echo "${TIS_RAW}" | tr -d '[:space:]')"; fi
    if [ "${TAU_RAW:-}" != "null" ] && [ -n "${TAU_RAW:-}" ]; then TAU="${TAU_RAW}"; fi
    if [ "${SLICEDT_MS_RAW:-}" != "null" ] && [ -n "${SLICEDT_MS_RAW:-}" ]; then SLICEDT_MS="${SLICEDT_MS_RAW}"; fi
    if [ "${TR_RAW:-}" != "null" ] && [ -n "${TR_RAW:-}" ]; then TR_VAL="${TR_RAW}"; fi

    # Compute slice dt in seconds
    SLICEDT_SEC=""
    if [ -n "$SLICEDT_MS" ]; then
      SLICEDT_SEC=$(awk "BEGIN{printf \"%.6f\", ${SLICEDT_MS}/1000}")
    fi

    # -----------------------
    # Parse M0 JSON (TR only)
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

    # --- Step: remove NaNs with fslmaths ---
    ASL_NONAN="${PROCDIR}/asl_nonan.nii.gz"
    echo "Removing NaNs: ${ASL_IN} -> ${ASL_NONAN}"
    fslmaths "$ASL_IN" -nan "$ASL_NONAN"

    if [ ! -f "$ASL_NONAN" ]; then
      echo "ERROR: Failed to create ${ASL_NONAN}. Skipping."
      continue
    fi

    # Build oxasl args
    OXASL_ARGS=(-i "$ASL_NONAN")

    IAF="tc"
    asltype_lc=$(echo "$ASLTYPE_RAW" | tr '[:upper:]' '[:lower:]' 2>/dev/null || true)
    if [[ "$asltype_lc" == *"diff"* ]]; then IAF="diff"; fi
    OXASL_ARGS+=(--iaf="$IAF" --ibf=rpt)

    if [ -n "$PLDS" ]; then OXASL_ARGS+=(--plds "${PLDS}"); fi
    if [ -n "$TIS" ]; then OXASL_ARGS+=(--tis "${TIS}"); fi
    if [ -n "$TAU" ]; then OXASL_ARGS+=(--tau "${TAU}"); fi
    if [ -n "$SLICEDT_SEC" ]; then OXASL_ARGS+=(--slicedt "${SLICEDT_SEC}"); fi
    if [ -n "$TR_VAL" ]; then OXASL_ARGS+=(--tr "${TR_VAL}"); fi
    if [ -n "$TR_M0_VAL" ]; then OXASL_ARGS+=(--tr "${TR_M0_VAL}"); fi

    OXASL_ARGS+=(--calib "$M0_IN" --calib-method=voxelwise --calib-aslreg)
    OXASL_ARGS+=(--struc "$T1_IN")
    OXASL_ARGS+=(--mc --fixbat --fixbolus --pvcorr)
    OXASL_ARGS+=(-o "$PROCDIR")
    OXASL_ARGS+=(--save-input --save-preproc --save-corrected --save-quantification \
                 --save-calib --save-reg --save-asl-masks --save-struct-rois --save-all)
    OXASL_ARGS+=(--overwrite)

    # YAML summary
    YAML_OUT="${PROCDIR}/oxasl_config_${subj}_${ses_label}.yaml"
    cat > "$YAML_OUT" <<EOF
subject: ${subj}
session: ${ses_label}
asl_nifti: ${ASL_IN}
asl_json: ${ASL_JSON}
m0_nifti: ${M0_IN}
m0_json: ${M0_JSON:-null}
t1w_nifti: ${T1_IN}
plds: ${PLDS:-null}
tis: ${TIS:-null}
tau: ${TAU:-null}
slicedt_ms: ${SLICEDT_MS:-null}
slicedt_sec_for_oxasl: ${SLICEDT_SEC:-null}
tr_asl: ${TR_VAL:-null}
tr_m0: ${TR_M0_VAL:-null}
iaf_assumed: ${IAF}
oxasl_args: >
  $(printf "%s " "${OXASL_ARGS[@]}")
EOF

    echo "Wrote YAML summary: ${YAML_OUT}"

    # Run oxasl
    echo "Running oxasl for ${subj}/${ses_label}:"
    echo "  oxasl ${OXASL_ARGS[*]}"
    oxasl "${OXASL_ARGS[@]}"

    echo "Finished ${subj}/${ses_label}. Outputs in ${PROCDIR}"
    echo
  done
done

echo "All done."