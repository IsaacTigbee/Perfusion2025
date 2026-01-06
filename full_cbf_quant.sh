#!/usr/bin/env bash
# full_cbf_quant.sh
#
# Usage:
#   ./full_cbf_quant.sh /path/to/BIDS_dataset
#
# Dependencies:
#   fslmaths, oxasl, python3, python3-nibabel (recommended for M0 derivation), awk, sed, sort, join, find
#
# Behaviour highlights:
# - Finds ASL anywhere under each subject/session (case-insensitive)
# - Uses subject JSON if present, otherwise searches dataset-level JSON for PLD/TI/etc
# - Handles multi-PLD lists
# - If no explicit M0:
#     - tries aslcontext.tsv
#     - else tries automatic control detection (2-cluster on per-volume mean intensity)
#     - else falls back to alternating-even volumes heuristic
# - Merges participants.tsv into final CSV
# - Conservatively skips subject if reliable M0 cannot be derived

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <BIDS_ROOT>"
  exit 1
fi
BIDS_ROOT="$(realpath "$1")"

# Check required commands
for cmd in fslmaths oxasl python3 awk sed sort join find; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
done

# Check python nibabel availability for deriving M0
PY_NIB_AVAILABLE=$(python3 - <<'PY' 2>/dev/null || true
try:
    import nibabel as nib
    print("yes")
except Exception:
    pass
PY
)
if [ "$PY_NIB_AVAILABLE" != "yes" ]; then
  echo "WARNING: python3-nibabel not available. Automatic M0 derivation requires nibabel."
fi

SUMMARY_CSV="${BIDS_ROOT}/cbf_quant_summary.csv"
echo "subject,session,mean_within_mask,gm_mean,pure_gm_mean,cortical_gm_mean,wm_mean,pure_wm_mean,cerebral_wm_mean" > "$SUMMARY_CSV"

shopt -s nullglob

# dataset-level JSON finder (returns first JSON containing any relevant keys)
find_dataset_json() {
  python3 - "$BIDS_ROOT" <<'PY'
import sys,json,os
root=sys.argv[1]
keys = ["PostLabelingDelay","PostLabelingDelay_s","PLD","InitialPostLabelDelay",
        "TIs","TIs_s","InversionTimes",
        "LabelingDuration","LabelDuration",
        "RepetitionTimePreparation","RepetitionTime",
        "ArterialSpinLabelingType","ASLType","ASLContext",
        "M0RepetitionTime","M0RepetitionTimePreparation","M0TR"]
c=[]
for dp,dirs,files in os.walk(root):
    for f in files:
        if f.lower().endswith('.json'):
            c.append(os.path.join(dp,f))
c = sorted(c, key=lambda p: p.count(os.sep))
for p in c:
    try:
        j=json.load(open(p))
    except Exception:
        continue
    for k in keys:
        if k in j:
            print(p)
            sys.exit(0)
PY
}

# iterate subjects
for subjdir in "$BIDS_ROOT"/sub-*; do
  [ -d "$subjdir" ] || continue
  subj=$(basename "$subjdir")
  echo "================ Processing ${subj} ================"

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
      ses_label="no-session"; topdir="$subjdir"
    else
      ses_label=$(basename "$sesdir"); topdir="$sesdir"
    fi
    echo "---- Processing ${subj}/${ses_label} ----"

    # find ASL (case-insensitive, anywhere under topdir)
    ASL_IN=$(find "$topdir" -type f -iname "*asl*.nii*" -print -quit || true)
    ASL_JSON=""
    if [ -n "$ASL_IN" ]; then
      # try common sibling JSON names robustly
      if [[ "$ASL_IN" == *.nii.gz ]]; then
        if [ -f "${ASL_IN%.nii.gz}.json" ]; then
          ASL_JSON="${ASL_IN%.nii.gz}.json"
        elif [ -f "${ASL_IN}.json" ]; then
          ASL_JSON="${ASL_IN}.json"
        elif [ -f "${ASL_IN%.nii}.json" ]; then
          ASL_JSON="${ASL_IN%.nii}.json"
        fi
      else
        if [ -f "${ASL_IN%.nii}.json" ]; then
          ASL_JSON="${ASL_IN%.nii}.json"
        elif [ -f "${ASL_IN}.json" ]; then
          ASL_JSON="${ASL_IN}.json"
        fi
      fi
    fi

    # find M0 (case-insensitive)
    M0_IN=$(find "$topdir" -type f \( -iname "*m0scan*.nii*" -o -iname "*m0*.nii*" \) -print -quit || true)
    M0_JSON=""
    if [ -n "$M0_IN" ]; then
      if [[ "$M0_IN" == *.nii.gz && -f "${M0_IN%.nii.gz}.json" ]]; then
        M0_JSON="${M0_IN%.nii.gz}.json"
      elif [ -f "${M0_IN}.json" ]; then
        M0_JSON="${M0_IN}.json"
      fi
    fi

    # find T1w
    T1_IN=$(find "$topdir" -type f -iname "*T1w*.nii*" -path "*/anat/*" -print -quit || true)
    if [ -z "$T1_IN" ]; then
      T1_IN=$(find "$topdir" -type f -iname "*T1w*.nii*" -print -quit || true)
    fi

    if [ -z "$ASL_IN" ]; then
      echo "WARNING: No ASL nifti found for ${subj}/${ses_label} - skipping"
      continue
    fi

    # pick JSON: subject/session or dataset-level
    ASL_JSON_USED="$ASL_JSON"
    if [ -z "$ASL_JSON_USED" ] || [ ! -f "$ASL_JSON_USED" ]; then
      echo "INFO: No subject/session ASL JSON found for ${ASL_IN}. Searching for dataset-level JSON..."
      DATASET_JSON=$(find_dataset_json)
      if [ -n "$DATASET_JSON" ]; then
        echo "INFO: Using dataset-level JSON: ${DATASET_JSON}"
        ASL_JSON_USED="$DATASET_JSON"
      else
        echo "WARNING: No ASL JSON found at subject/session or dataset level for ${ASL_IN}."
      fi
    fi

    PROCDIR="${topdir}/processed"; mkdir -p "$PROCDIR"

    # --- parse JSON (single-line tab-separated) ---
    read -r PLDS_RAW TIS_RAW TAU_RAW TR_RAW ASLTYPE_RAW M0TR_RAW <<< "$(python3 - "$ASL_JSON_USED" <<'PY'
import json,sys,os
j={}
path=None
if len(sys.argv)>1:
    path=sys.argv[1]
if path and os.path.isfile(path):
    try:
        j=json.load(open(path))
    except Exception:
        j={}
def first(*keys):
    for k in keys:
        if k in j and j[k] is not None:
            v=j[k]
            if isinstance(v,dict):
                for kk in ("value","Value","val","Val"):
                    if kk in v:
                        return v[kk]
            return v
    return None
plds = first("PostLabelingDelay","PostLabelingDelay_s","PLD","InitialPostLabelDelay")
tis  = first("TIs","TIs_s","InversionTimes")
tau  = first("LabelingDuration","LabelDuration")
tr = first("RepetitionTimePreparation","RepetitionTime")
asl_type = first("ArterialSpinLabelingType","ASLType","ASLContext","LabelingType")
m0tr = first("M0RepetitionTime","M0RepetitionTimePreparation","M0TR")
def fmt(x):
    if x is None:
        return "null"
    if isinstance(x, list):
        return ",".join(str(v) for v in x)
    return str(x)
print("\t".join([fmt(plds), fmt(tis), fmt(tau), fmt(tr), fmt(asl_type if asl_type is not None else "unknown"), fmt(m0tr)]))
PY
)"

    PLDS=""; TIS=""; TAU=""; TR_VAL=""; M0TR_VAL=""
    if [ "${PLDS_RAW:-}" != "null" ] && [ -n "${PLDS_RAW:-}" ]; then PLDS="$(echo "${PLDS_RAW}" | tr -d '[:space:]')"; fi
    if [ "${TIS_RAW:-}" != "null" ] && [ -n "${TIS_RAW:-}" ]; then TIS="$(echo "${TIS_RAW}" | tr -d '[:space:]')"; fi
    if [ "${TAU_RAW:-}" != "null" ] && [ -n "${TAU_RAW:-}" ]; then TAU="${TAU_RAW}"; fi
    if [ "${TR_RAW:-}" != "null" ] && [ -n "${TR_RAW:-}" ]; then TR_VAL="${TR_RAW}"; fi
    if [ "${M0TR_RAW:-}" != "null" ] && [ -n "${M0TR_RAW:-}" ]; then M0TR_VAL="${M0TR_RAW}"; fi

    # ensure we have PLD or TIs
    if [ -z "$PLDS" ] && [ -z "$TIS" ]; then
      echo "ERROR: Neither PLDs nor TIs found in JSON (${ASL_JSON_USED}). Skipping ${subj}/${ses_label}."
      continue
    fi

    # remove NaNs in ASL
    ASL_NONAN="${PROCDIR}/asl_nonan.nii.gz"
    echo "Removing NaNs: ${ASL_IN} -> ${ASL_NONAN}"
    fslmaths "$ASL_IN" -nan "$ASL_NONAN"
    if [ ! -f "$ASL_NONAN" ]; then
      echo "ERROR: Failed to create ${ASL_NONAN}. Skipping."
      continue
    fi

    # If no M0 found, attempt derivation:
    if [ -z "$M0_IN" ]; then
      echo "INFO: No explicit M0 file found for ${subj}/${ses_label}."
      # first try aslcontext.tsv if present
      ASLCONTEXT_TSV=$(find "$(dirname "$ASL_IN")" -maxdepth 1 -name "*aslcontext.tsv" -print -quit)
      if [ -n "$ASLCONTEXT_TSV" ] && [ -f "$ASLCONTEXT_TSV" ]; then
        echo "INFO: Using aslcontext.tsv to pick control volumes: ${ASLCONTEXT_TSV}"
        M0_DERIVED="${PROCDIR}/m0_from_controls.nii.gz"
        if [ "$PY_NIB_AVAILABLE" = "yes" ]; then
          python3 - "$ASL_NONAN" "$ASLCONTEXT_TSV" "$M0_DERIVED" <<'PY'
import sys, numpy as np
try:
    import nibabel as nib
except Exception:
    print("PY_ERR:no_nib"); sys.exit(2)
asl,ctx,out=sys.argv[1],sys.argv[2],sys.argv[3]
lines=[l.strip() for l in open(ctx) if l.strip()]
start=0
if len(lines)>0 and any(c.isalpha() for c in lines[0].split()): start=1
ctrl_indices=[]
for i,l in enumerate(lines[start:], start=0):
    cols=l.split()
    if len(cols)==0: continue
    v=cols[0].lower()
    if 'control' in v or v in ('c','ctl'):
        ctrl_indices.append(i)
if len(ctrl_indices)==0:
    # try alternative parsing
    for i,l in enumerate(lines):
        if i==0: continue
        cols=[c.strip().lower() for c in l.split()]
        if len(cols)>0 and 'control' in cols[0]:
            ctrl_indices.append(i-1)
img=nib.load(asl)
data=img.get_fdata()
if data.ndim<4: print("PY_ERR:not_4d"); sys.exit(3)
nvol=data.shape[3]
ctrl_indices=[i for i in ctrl_indices if 0<=i<nvol]
if len(ctrl_indices)==0:
    ctrl_indices=list(range(0,nvol,2))
ctrl_data=data[:,:,:,ctrl_indices]
m0=np.nanmean(ctrl_data,axis=3)
nib.save(nib.Nifti1Image(m0,img.affine,img.header), out)
print("PY_OK")
PY
          if [ -f "$M0_DERIVED" ]; then
            echo "INFO: Derived M0 saved to $M0_DERIVED"
            M0_IN="$M0_DERIVED"; M0_JSON=""
          else
            echo "WARNING: Failed to derive M0 using aslcontext.tsv."
          fi
        else
          echo "WARNING: nibabel not installed; cannot derive M0 from aslcontext.tsv."
        fi
      else
        # No aslcontext.tsv: try automatic detection using per-volume intensity clustering
        echo "INFO: No aslcontext.tsv; attempting automatic control detection via intensity clustering..."
        M0_DERIVED="${PROCDIR}/m0_from_controls.nii.gz"
        if [ "$PY_NIB_AVAILABLE" = "yes" ]; then
          python3 - "$ASL_NONAN" "$M0_DERIVED" <<'PY'
import sys, numpy as np
try:
    import nibabel as nib
except Exception:
    print("PY_ERR:no_nib"); sys.exit(2)
asl,out=sys.argv[1],sys.argv[2]
img=nib.load(asl)
data=img.get_fdata()
if data.ndim<4:
    print("PY_ERR:not_4d"); sys.exit(3)
nvol=data.shape[3]
# compute global mean intensity per volume
means = data.reshape(-1, nvol).mean(axis=0)
# simple 2-means clustering (initialize with min/max)
c1, c2 = float(means.min()), float(means.max())
for _ in range(20):
    grp1 = [i for i,m in enumerate(means) if abs(m-c1) <= abs(m-c2)]
    grp2 = [i for i,m in enumerate(means) if abs(m-c2) <  abs(m-c1)]
    if len(grp1)>0:
        nc1 = float(means[grp1].mean())
    else:
        nc1 = c1
    if len(grp2)>0:
        nc2 = float(means[grp2].mean())
    else:
        nc2 = c2
    if abs(nc1-c1)<1e-6 and abs(nc2-c2)<1e-6:
        break
    c1, c2 = nc1, nc2
# decide which cluster is control (higher mean intensity)
if c1 >= c2:
    control_idx = [i for i,m in enumerate(means) if abs(m-c1) <= abs(m-c2)]
else:
    control_idx = [i for i,m in enumerate(means) if abs(m-c2) <  abs(m-c1)]
# sanity check cluster sizes
if len(control_idx) == 0 or len(control_idx) > nvol-1:
    # fallback to even indices heuristic
    control_idx = list(range(0,nvol,2))
# compute mean across control volumes
ctrl_data = data[:,:,:,control_idx]
m0 = np.nanmean(ctrl_data, axis=3)
nib.save(nib.Nifti1Image(m0, img.affine, img.header), out)
print("PY_OK:clustered", len(control_idx))
PY
          rc=$?
          if [ $rc -eq 0 ] && [ -f "$M0_DERIVED" ]; then
            echo "INFO: Derived M0 (auto) saved to $M0_DERIVED"
            M0_IN="$M0_DERIVED"; M0_JSON=""
          else
            echo "WARNING: Automatic control detection failed; will attempt alternating heuristic..."
            # attempt alternating even volumes
            if [ "$PY_NIB_AVAILABLE" = "yes" ]; then
              python3 - "$ASL_NONAN" "$M0_DERIVED" <<'PY'
import sys
try:
    import nibabel as nib, numpy as np
except Exception:
    print("PY_ERR:no_nib"); sys.exit(2)
asl,out=sys.argv[1],sys.argv[2]
img=nib.load(asl); data=img.get_fdata()
if data.ndim<4:
    print("PY_ERR:not_4d"); sys.exit(3)
nvol=data.shape[3]
ctrl_idx=list(range(0,nvol,2))
m0 = np.nanmean(data[:,:,:,ctrl_idx], axis=3)
nib.save(nib.Nifti1Image(m0, img.affine, img.header), out)
print("PY_OK:even")
PY
              if [ -f "$M0_DERIVED" ]; then
                echo "INFO: Derived M0 (even-indices) saved to $M0_DERIVED"
                M0_IN="$M0_DERIVED"; M0_JSON=""
              else
                echo "WARNING: Even-index derivation failed."
              fi
            else
              echo "WARNING: nibabel not available for fallback derivation."
            fi
          fi
        else
          echo "WARNING: nibabel not installed; cannot attempt automatic M0 derivation."
        fi
      fi
    fi

    # if still no M0, skip (preserve safe behavior)
    if [ -z "$M0_IN" ]; then
      echo "WARNING: No M0 available for ${subj}/${ses_label} - skipping"
      continue
    fi

    if [ -z "$T1_IN" ]; then
      echo "WARNING: No T1w found for ${subj}/${ses_label} - skipping"
      continue
    fi

    # build oxasl args
    OXASL_ARGS=(-i "$ASL_NONAN" --ibf=tis)
    ##########################################
    # ΔM (already-subtracted) detection
    ##########################################

    IS_DIFF=false

    # Condition A: check if ASL is 3D (dim4 == 1)
    ASL_DIM4=$(fslval "$ASL_NONAN" dim4)
    if [ "$ASL_DIM4" -eq 1 ]; then
    IS_DIFF=true
    else
    # Condition B: check aslcontext.tsv for only "deltam"
    ASLCONTEXT_TSV=$(find "$(dirname "$ASL_IN")" -maxdepth 1 -name "*aslcontext.tsv" -print -quit)
    if [ -n "$ASLCONTEXT_TSV" ] && [ -f "$ASLCONTEXT_TSV" ]; then
        CTX_UNIQUE=$(awk 'NR>1 {print tolower($1)}' "$ASLCONTEXT_TSV" | sort -u)
        if echo "$CTX_UNIQUE" | grep -qx "deltam"; then
        IS_DIFF=true
        fi
    fi
    fi

    # Apply OXASL flags
    if [ "$IS_DIFF" = true ]; then
    echo "INFO: Detected ALREADY SUBTRACTED ΔM ASL – using --iaf=diff --diff"
    OXASL_ARGS+=(--iaf=diff)
    else
    # For 4D ASL Data
    IAF="tc"
    ASLCONTEXT_TSV=$(find "$(dirname "$ASL_IN")" -maxdepth 1 -name "*aslcontext.tsv" -print -quit)
    if [ -n "$ASLCONTEXT_TSV" ] && [ -f "$ASLCONTEXT_TSV" ]; then
        FIRST_LINE=$(awk 'NR==2 {print tolower($1)}' "$ASLCONTEXT_TSV" 2>/dev/null || true)
        if [[ "$FIRST_LINE" == "control" ]]; then
        IAF="ct"
        elif [[ "$FIRST_LINE" == "label" ]]; then
        IAF="tc"
        fi
    fi
    OXASL_ARGS+=(--iaf "$IAF")
    fi
    ##########################################


    # --- robust ASL type detection (set --casl for pcASL/CASL) ---
    # Common textual patterns we treat as "continuous" style: pcasl, pseudo(-)continuous, casl, continuous
    ASL_DETECT_STR="$(printf '%s\n' "${ASLTYPE_RAW:-}" | tr '[:upper:]' '[:lower:]' || true)"
    SET_CASL=false
    ASL_DETECT_REASON="ASLTYPE_RAW"

    if [ -n "$ASL_DETECT_STR" ]; then
      if printf '%s\n' "$ASL_DETECT_STR" | grep -Eq 'pcasl|pseudo[-_ ]?continuous|pseudo|casl|continuous'; then
        SET_CASL=true
      fi
    fi

    # If not found in the extracted value, grep the JSON sidecar(s) for keywords.
    # (ASL_JSON_USED may be empty; DATASET_JSON is set earlier if found)
    if [ "$SET_CASL" = false ]; then
      for j in "$ASL_JSON_USED" "${DATASET_JSON:-}"; do
        [ -n "$j" ] || continue
        [ -f "$j" ] || continue
        if grep -iEq 'pcasl|pseudo[-_ ]?continuous|pseudo|casl|continuous' "$j"; then
          SET_CASL=true
          ASL_DETECT_REASON="$j"
          break
        fi
      done
    fi

    if [ "$SET_CASL" = true ]; then
      OXASL_ARGS+=(--casl)
      echo "INFO: ASL type detected as CASL/pcASL (set --casl). Reason: ${ASL_DETECT_REASON}"
    else
      echo "INFO: ASL type not detected as CASL/pcASL (leaving default; likely PASL or unknown)"
    fi
    # --- end detection ---


    if [ -n "$PLDS" ]; then OXASL_ARGS+=(--plds "${PLDS}"); fi
    if [ -n "$TIS" ]; then OXASL_ARGS+=(--tis "${TIS}"); fi
    if [ -n "$TAU" ]; then OXASL_ARGS+=(--tau "${TAU}"); fi

    # TR preference
    TR_M0_VAL=""
    if [ -n "$M0_JSON" ] && [ -f "$M0_JSON" ]; then
      TR_M0_VAL=$(python3 - "$M0_JSON" <<'PY'
import json,sys
try:
    j=json.load(open(sys.argv[1]))
    tr = j.get("RepetitionTimePreparation") or j.get("RepetitionTime")
    if tr is None:
        tr = j.get("M0RepetitionTime") or j.get("M0RepetitionTimePreparation") or j.get("M0TR")
    print(tr if tr is not None else "null")
except Exception:
    print("null")
PY
)
      [ "$TR_M0_VAL" = "null" ] && TR_M0_VAL=""
    elif [ -n "${M0TR_VAL:-}" ]; then
      TR_M0_VAL="$M0TR_VAL"
    fi

    if [ -n "$TR_M0_VAL" ]; then
      OXASL_ARGS+=(--tr "${TR_M0_VAL}")
    elif [ -n "$TR_VAL" ]; then
      OXASL_ARGS+=(--tr "${TR_VAL}")
    fi

    OXASL_ARGS+=(--calib "$M0_IN" --calib-method=voxelwise)
    OXASL_ARGS+=(--struc "$T1_IN")
    OXASL_ARGS+=(--mc)
    OXASL_ARGS+=(-o "$PROCDIR")
    OXASL_ARGS+=(--save-input --save-preproc --save-quantification --save-calib --save-reg --save-asl-masks --save-struct-rois)
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

# merge participants.tsv into summary csv
PARTS_TSV="${BIDS_ROOT}/participants.tsv"
if [ -f "$PARTS_TSV" ]; then
  echo "INFO: Merging participants.tsv into summary CSV..."
  python3 - "$PARTS_TSV" "$SUMMARY_CSV" "${BIDS_ROOT}/cbf_quant_summary_with_participants.csv" <<'PY'
import sys,csv
parts_tsv=sys.argv[1]; summary_csv=sys.argv[2]; out_csv=sys.argv[3]
parts=[]
with open(parts_tsv,'r', newline='') as f:
    reader=csv.DictReader(f, delimiter='\t')
    parts=list(reader)
parts_by_id={}
id_field=None
if parts:
    for fn in reader.fieldnames:
        if fn.lower() in ('participant_id','participant'):
            id_field=fn; break
    if id_field is None:
        id_field=reader.fieldnames[0]
    for row in parts:
        parts_by_id[row[id_field]] = row

with open(summary_csv,'r', newline='') as f:
    sreader=csv.DictReader(f)
    srows=list(sreader)
s_fieldnames = sreader.fieldnames or []

extra_fields=[]
if parts:
    for k in parts[0].keys():
        if k!=id_field:
            extra_fields.append(k)
out_fields = s_fieldnames + extra_fields

with open(out_csv,'w', newline='') as fo:
    writer=csv.DictWriter(fo, fieldnames=out_fields)
    writer.writeheader()
    for r in srows:
        subj = r.get('subject') or r.get('participant_id') or ''
        p = parts_by_id.get(subj)
        if p is None:
            if subj.startswith('sub-'):
                p = parts_by_id.get(subj)
            else:
                p = parts_by_id.get('sub-'+subj)
        outrow=dict(r)
        if p:
            for ef in extra_fields:
                outrow[ef]=p.get(ef,'')
        else:
            for ef in extra_fields:
                outrow[ef]=''
        writer.writerow(outrow)
print("Merged file written to", out_csv)
PY
  if [ $? -eq 0 ]; then
    echo "Participants merged: ${BIDS_ROOT}/cbf_quant_summary_with_participants.csv"
  else
    echo "WARNING: Failed to merge participants.tsv with summary CSV."
  fi
else
  echo "INFO: No participants.tsv found at dataset root. Skipping merge."
fi

echo "All done. Summary CSV: $SUMMARY_CSV"
if [ -f "${BIDS_ROOT}/cbf_quant_summary_with_participants.csv" ]; then
  echo "Merged summary with participants: ${BIDS_ROOT}/cbf_quant_summary_with_participants.csv"
fi
