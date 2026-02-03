#!/usr/bin/env bash
# vps-disk-latency-bench.sh
# Latency-focused fio benchmark for VPS environments.
# Safe defaults: uses a single test file, modest size, no package installs.
# Requires: fio, dd, awk, sed, date

set -euo pipefail

FILE_DIR="${FILE_DIR:-/var/tmp}"           # needs FILE_SIZE_GB free space
FILE_SIZE_GB="${FILE_SIZE_GB:-2}"          # keep modest for small instances
RUNTIME_SEC="${RUNTIME_SEC:-30}"           # per-job runtime
WARMUP_SEC="${WARMUP_SEC:-5}"
IODEPTHS="${IODEPTHS:-1 2 4}"              # low queue depth matters most
BS_LIST="${BS_LIST:-4k 8k}"                # small-block reality
MIX_LIST="${MIX_LIST:-70 50}"              # 70/30 and 50/50 read/write mixes
JOBS_LIST="${JOBS_LIST:-1 2}"              # light concurrency
ENGINE="${ENGINE:-libaio}"                 # Linux native (io_uring also works on newer kernels)
DIRECT="${DIRECT:-1}"                      # bypass page cache
OUTPUT_DIR="${OUTPUT_DIR:-./bench_out}"
HOSTTAG="${HOSTTAG:-$(hostname -f 2>/dev/null || hostname)}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

TESTFILE="${FILE_DIR}/fio-bench-${TS}.dat"
OUT_JSON="${OUTPUT_DIR}/fio-${HOSTTAG}-${TS}.json"
OUT_TXT="${OUTPUT_DIR}/fio-${HOSTTAG}-${TS}.txt"

mkdir -p "$OUTPUT_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need fio
need dd
need awk
need sed
need date

fio_supports() {
  fio --help 2>/dev/null | grep -q -- "$1"
}

# fio option compatibility:
# Some fio versions support --clat_percentiles, older ones used --lat_percentiles.
PERCENT_OPT=""
if fio_supports "clat_percentiles"; then
  PERCENT_OPT="--clat_percentiles=1"
elif fio_supports "lat_percentiles"; then
  PERCENT_OPT="--lat_percentiles=1"
else
  PERCENT_OPT=""  # no percentiles available
fi

PERCENT_LIST_OPT=""
if fio_supports "percentile_list"; then
  PERCENT_LIST_OPT="--percentile_list=50:90:95:99:99.9:99.99"
fi

echo "== VPS Disk Latency Bench =="
echo "Host: ${HOSTTAG}"
echo "Test file: ${TESTFILE}"
echo "File size: ${FILE_SIZE_GB} GiB"
echo "Runtime: ${RUNTIME_SEC}s (warmup ${WARMUP_SEC}s)"
echo "Output JSON: ${OUT_JSON}"
echo "Output TXT:  ${OUT_TXT}"
echo

echo "Preparing test file..."
if dd if=/dev/zero of="$TESTFILE" bs=1M count=$((FILE_SIZE_GB*1024)) conv=fsync status=none 2>/dev/null; then
  :
else
  echo "dd with conv=fsync failed; trying without fsync..."
  dd if=/dev/zero of="$TESTFILE" bs=1M count=$((FILE_SIZE_GB*1024)) status=none
  sync
fi
echo "Done."
echo

run_fio () {
  local name="$1" rw="$2" rwmixread="$3" bs="$4" iodepth="$5" numjobs="$6"

  fio --name="$name" \
      --filename="$TESTFILE" \
      --size="${FILE_SIZE_GB}G" \
      --time_based=1 --runtime="$RUNTIME_SEC" --ramp_time="$WARMUP_SEC" \
      --ioengine="$ENGINE" --direct="$DIRECT" \
      --rw="$rw" --rwmixread="$rwmixread" \
      --bs="$bs" --iodepth="$iodepth" --numjobs="$numjobs" \
      --group_reporting=1 \
      --random_generator=tausworthe64 \
      --norandommap=1 \
      --randrepeat=0 \
      --invalidate=1 \
      ${PERCENT_OPT:+$PERCENT_OPT} \
      ${PERCENT_LIST_OPT:+$PERCENT_LIST_OPT} \
      --output-format=json
}

# Build one JSON array containing each fio JSON object.
echo "[" > "$OUT_JSON"
first=1

log_line () { printf "%s\n" "$*" | tee -a "$OUT_TXT" >/dev/null; }

log_line "## Summary"
log_line "Host: $HOSTTAG"
log_line "UTC:  $TS"
log_line "File: $TESTFILE (${FILE_SIZE_GB}GiB)"
log_line ""

ns_to_ms () { awk -v ns="${1:-0}" 'BEGIN{ if(ns==""){ns=0}; printf "%.3f", (ns/1000000) }'; }

echo "Running tests..."
for bs in $BS_LIST; do
  for mix in $MIX_LIST; do
    for depth in $IODEPTHS; do
      for jobs in $JOBS_LIST; do
        name="randrw_${mix}read_${bs}_qd${depth}_jobs${jobs}"
        echo "  - $name"
        json="$(run_fio "$name" randrw "$mix" "$bs" "$depth" "$jobs")"

        if [ "$first" -eq 1 ]; then
          first=0
        else
          echo "," >> "$OUT_JSON"
        fi
        echo "$json" >> "$OUT_JSON"

        # Basic extraction (best-effort) for a compact text line: IOPS + avg clat + p99.9 clat
        r_iops="$(echo "$json" | awk -F'[:,}]' '/"read" *: *{/{f=1} f&&/"iops"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
        w_iops="$(echo "$json" | awk -F'[:,}]' '/"write" *: *{/{f=1} f&&/"iops"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"

        r_clat_ns="$(echo "$json" | awk -F'[:,}]' '/"read" *: *{/{f=1} f&&/"clat_ns"/{c=1} c&&/"mean"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
        w_clat_ns="$(echo "$json" | awk -F'[:,}]' '/"write" *: *{/{f=1} f&&/"clat_ns"/{c=1} c&&/"mean"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"

        r_p999_ns="$(echo "$json" | awk -F'[:,}]' '/"read" *: *{/{f=1} f&&/"clat_ns"/{c=1} c&&/"percentile"/{p=1} p&&/"99.900000"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
        w_p999_ns="$(echo "$json" | awk -F'[:,}]' '/"write" *: *{/{f=1} f&&/"clat_ns"/{c=1} c&&/"percentile"/{p=1} p&&/"99.900000"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"

        r_clat_ms="$(ns_to_ms "$r_clat_ns")"
        w_clat_ms="$(ns_to_ms "$w_clat_ns")"
        r_p999_ms="$(ns_to_ms "$r_p999_ns")"
        w_p999_ms="$(ns_to_ms "$w_p999_ns")"

        log_line "$name  | read IOPS: ${r_iops:-?}  avg(ms): ${r_clat_ms:-?}  p99.9(ms): ${r_p999_ms:-?}  || write IOPS: ${w_iops:-?}  avg(ms): ${w_clat_ms:-?}  p99.9(ms): ${w_p999_ms:-?}"
      done
    done
  done
done

echo "]" >> "$OUT_JSON"
echo

echo "Cleaning up test file..."
rm -f "$TESTFILE" || true
sync || true

echo
echo "Done."
echo "Text summary: $OUT_TXT"
echo "Raw JSON:     $OUT_JSON"
