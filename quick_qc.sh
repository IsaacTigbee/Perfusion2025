#!/usr/bin/env bash

# Usage:
# ./quick_qc.sh sub-01_asl.nii.gz sub-01_asl.json sub-01_m0scan.nii.gz sub-01_m0scan.json c-l | l-c

ASL=$1
JSON_ASL=$2
M0=$3
JSON_M0=$4
ORDER=$5   # either "c-l" or "l-c"

# --- Helper: extract JSON values using Python (no jq required) ---
json_get () {
  python3 -c "import json,sys;
with open(sys.argv[2]) as f:
    data=json.load(f)
val=data.get(sys.argv[1],'MISSING')
if isinstance(val,list): print(','.join(map(str,val)))
else: print(val)" $1 $2
}

# Subject name & report filename
subj_name=$(basename "$ASL" | cut -d'_' -f1)
OUTDIR="${subj_name}_qcoutput"
mkdir -p "$OUTDIR"
REPORT_HTML="${OUTDIR}/${subj_name}_qcreport.html"

# Start HTML report
echo "<html><body><h2>ASL QC Report: $subj_name</h2><pre>" > "$REPORT_HTML"

############################
# --- ASL QC ---
############################
dims_asl=$(fslval "$ASL" dim1)x$(fslval "$ASL" dim2)x$(fslval "$ASL" dim3)x$(fslval "$ASL" dim4)
vox_asl=$(fslval "$ASL" pixdim1)x$(fslval "$ASL" pixdim2)x$(fslval "$ASL" pixdim3)
tr_asl=$(fslval "$ASL" pixdim4)
scl_slope=$(fslval "$ASL" scl_slope)
scl_inter=$(fslval "$ASL" scl_inter)
forms_asl=$(fslhd "$ASL" | awk '/form_code/ {printf "%s:%s,", $1, $2} END{print ""}' | sed 's/,$//')

echo ">> ASL NIfTI Checks" >> "$REPORT_HTML"
echo "Dimensions: $dims_asl" >> "$REPORT_HTML"
echo "Voxel size (mm): $vox_asl" >> "$REPORT_HTML"
echo "TR (s) from NIfTI: $tr_asl" >> "$REPORT_HTML"
echo "Scaling factors: $scl_slope,$scl_inter" >> "$REPORT_HTML"
echo "qform/sform codes: $forms_asl" >> "$REPORT_HTML"
echo "" >> "$REPORT_HTML"

############################
# --- M0 QC ---
############################
dims_m0=$(fslval "$M0" dim1)x$(fslval "$M0" dim2)x$(fslval "$M0" dim3)x$(fslval "$M0" dim4)
vox_m0=$(fslval "$M0" pixdim1)x$(fslval "$M0" pixdim2)x$(fslval "$M0" pixdim3)
scl_slope_m0=$(fslval "$M0" scl_slope)
scl_inter_m0=$(fslval "$M0" scl_inter)
forms_m0=$(fslhd "$M0" | awk '/form_code/ {printf "%s:%s,", $1, $2} END{print ""}' | sed 's/,$//')

echo ">> M0 NIfTI Checks" >> "$REPORT_HTML"
echo "Dimensions: $dims_m0" >> "$REPORT_HTML"
echo "Voxel size (mm): $vox_m0" >> "$REPORT_HTML"
echo "Scaling factors: $scl_slope_m0,$scl_inter_m0" >> "$REPORT_HTML"
echo "qform/sform codes: $forms_m0" >> "$REPORT_HTML"
echo "" >> "$REPORT_HTML"

############################
# --- Cross-check ASL vs M0 ---
############################
echo ">> Cross-Check ASL vs M0" >> "$REPORT_HTML"

asl_dim1=$(fslval "$ASL" dim1)
asl_dim2=$(fslval "$ASL" dim2)
asl_dim3=$(fslval "$ASL" dim3)
asl_dim4=$(fslval "$ASL" dim4)

m0_dim1=$(fslval "$M0" dim1)
m0_dim2=$(fslval "$M0" dim2)
m0_dim3=$(fslval "$M0" dim3)
m0_dim4=$(fslval "$M0" dim4)

if [ "$asl_dim1" -eq "$m0_dim1" ] && [ "$asl_dim2" -eq "$m0_dim2" ] && [ "$asl_dim3" -eq "$m0_dim3" ]; then
  echo "<span style='color:green'>✔ First 3 dims match between ASL and M0</span>" >> "$REPORT_HTML"
else
  echo "<span style='color:red'>⚠ First 3 dims differ: ASL=${asl_dim1}x${asl_dim2}x${asl_dim3} vs M0=${m0_dim1}x${m0_dim2}x${m0_dim3}</span>" >> "$REPORT_HTML"
fi

if [ "$asl_dim4" -gt 1 ] && [ "$m0_dim4" -eq 1 ]; then
  echo "<span style='color:green'>✔ ASL is 4D (multi-volume), M0 is 3D (dim4=1)</span>" >> "$REPORT_HTML"
else
  echo "<span style='color:red'>⚠ Unexpected 4th dimension: ASL=$asl_dim4, M0=$m0_dim4</span>" >> "$REPORT_HTML"
fi
echo "" >> "$REPORT_HTML"

############################
# --- ΔM / M0 Ratio QC ---
############################
fslsplit "$ASL" "$OUTDIR/aslvol" -t
nvols=$(fslval "$ASL" dim4)

rm -f "$OUTDIR"/diff*.nii.gz "$OUTDIR"/deltaM*.nii.gz

idx=0
while [ $idx -lt $nvols ]; do
  next=$((idx+1))
  if [ $next -lt $nvols ]; then
    even=$(printf "$OUTDIR/aslvol%04d.nii.gz" $idx)
    odd=$(printf "$OUTDIR/aslvol%04d.nii.gz" $next)
    out=$(printf "$OUTDIR/diff%04d" $idx)

    if [ "$ORDER" == "c-l" ]; then
      fslmaths "$even" -sub "$odd" "$out"
    elif [ "$ORDER" == "l-c" ]; then
      fslmaths "$odd" -sub "$even" "$out"
    fi
  fi
  idx=$((idx+2))
done

if ls "$OUTDIR"/diff*.nii.gz 1> /dev/null 2>&1; then
  fslmerge -t "$OUTDIR/deltaM" "$OUTDIR"/diff*.nii.gz
  fslmaths "$OUTDIR/deltaM" -Tmean "$OUTDIR/deltaM_mean"
  mean_asl=$(fslstats "$OUTDIR/deltaM_mean" -M)
else
  echo "<span style='color:red'>⚠ No ΔM volumes created – falling back to raw ASL mean</span>" >> "$REPORT_HTML"
  mean_asl=$(fslstats "$ASL" -M)
fi

mean_m0=$(fslstats "$M0" -M)

echo ">> ΔM / M0 Signal Check" >> "$REPORT_HTML"
echo "Mean ΔM intensity: $mean_asl" >> "$REPORT_HTML"
echo "Mean M0 intensity: $mean_m0" >> "$REPORT_HTML"

if (( $(echo "$mean_m0 > 0" | bc -l) )); then
  ratio=$(echo "$mean_asl / $mean_m0" | bc -l)
  ratio_fmt=$(printf "%.3f" "$ratio")
  ratio_pct=$(echo "$ratio * 100" | bc -l)
  ratio_pct_fmt=$(printf "%.1f" "$ratio_pct")

  if (( $(echo "$ratio < 0.001" | bc -l) )); then
    echo "<span style='color:red'>⚠ ΔM/M0 ratio extremely low ($ratio_fmt = ${ratio_pct_fmt}%)</span>" >> "$REPORT_HTML"
  elif (( $(echo "$ratio > 0.05" | bc -l) )); then
    echo "<span style='color:red'>⚠ ΔM/M0 ratio very high ($ratio_fmt = ${ratio_pct_fmt}%)</span>" >> "$REPORT_HTML"
  else
    echo "<span style='color:green'>✔ ΔM/M0 ratio within plausible range ($ratio_fmt = ${ratio_pct_fmt}%)</span>" >> "$REPORT_HTML"
  fi
else
  echo "<span style='color:red'>⚠ ERROR: M0 mean intensity is zero</span>" >> "$REPORT_HTML"
fi
echo "" >> "$REPORT_HTML"

############################
# --- SNR Checks ---
############################
echo ">> SNR Checks" >> "$REPORT_HTML"

bet "$M0" "$OUTDIR/m0_brain" -m -f 0.3 > /dev/null 2>&1
bet "$ASL" "$OUTDIR/asl_brain" -m -f 0.3 > /dev/null 2>&1

mean_m0_brain=$(fslstats "$M0" -k "$OUTDIR/m0_brain_mask" -M)
std_m0_brain=$(fslstats "$M0" -k "$OUTDIR/m0_brain_mask" -S)
snr_m0=$(echo "$mean_m0_brain / $std_m0_brain" | bc -l)

mean_asl_brain=$(fslstats "$ASL" -k "$OUTDIR/asl_brain_mask" -M)
std_asl_brain=$(fslstats "$ASL" -k "$OUTDIR/asl_brain_mask" -S)
snr_asl=$(echo "$mean_asl_brain / $std_asl_brain" | bc -l)

echo "M0 SNR ≈ $snr_m0" >> "$REPORT_HTML"
echo "ASL SNR ≈ $snr_asl" >> "$REPORT_HTML"

############################
# --- Close HTML ---
############################
echo "</pre></body></html>" >> "$REPORT_HTML"
echo "✔️ HTML QC report saved as $REPORT_HTML"
for file in ${OUTDIR}/*.nii.gz
    do
        rm ${file} 
    done