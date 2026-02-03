#!/usr/bin/env bash
# bench-io.sh
# Latency-focused fio benchmarks for Linux VPS/systems.
# fio randrw sweep for disks (4k/8k, qd 1/2/4, jobs 1/2, 70/30 and 50/50).
# Outputs: JSON (raw fio output) and a text summary for quick review.
# Requires: fio, dd, awk, grep, hostname, date. Optional: jq, bc, tput.
#
# GitHub: https://github.com/haydenjames/VPS-Disk-Latency-Bench/

set -uo pipefail

# ============================================================================
# Configuration (override via environment variables)
# ============================================================================
FILE_DIR="${FILE_DIR:-/var/tmp}"           # needs FILE_SIZE_GB free space
FILE_SIZE_GB="${FILE_SIZE_GB:-2}"          # keep modest for small instances
RUNTIME_SEC="${RUNTIME_SEC:-30}"           # per-job runtime
WARMUP_SEC="${WARMUP_SEC:-5}"
IODEPTHS="${IODEPTHS:-1 2 4}"              # low queue depth matters most
BS_LIST="${BS_LIST:-4k 8k}"                # small-block reality
MIX_LIST="${MIX_LIST:-70 50}"              # 70/30 and 50/50 read/write mixes
JOBS_LIST="${JOBS_LIST:-1 2}"              # light concurrency
ENGINE="${ENGINE:-libaio}"                 # Linux native (io_uring also works)
DIRECT="${DIRECT:-1}"                      # bypass page cache
OUTPUT_DIR="${OUTPUT_DIR:-./bench_out}"
HOSTTAG="${HOSTTAG:-$(hostname -f 2>/dev/null || hostname)}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

TESTFILE="${FILE_DIR}/fio-bench-${TS}.dat"
OUT_JSON="${OUTPUT_DIR}/fio-${HOSTTAG}-${TS}.json"
OUT_TXT="${OUTPUT_DIR}/fio-${HOSTTAG}-${TS}.txt"

# ============================================================================
# Colors and formatting
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Detect if terminal supports colors
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    USE_COLOR=1
else
    USE_COLOR=0
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ============================================================================
# Helper functions
# ============================================================================
mkdir -p "$OUTPUT_DIR"

need() { 
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}Error: Missing required command: $1${NC}" >&2
        exit 1
    fi
}

need fio
need dd
need awk
need sed
need date

fio_supports() {
    fio --help 2>/dev/null | grep -q -- "$1" && return 0 || return 1
}

ns_to_ms() { 
    awk -v ns="${1:-0}" 'BEGIN{ if(ns=="" || ns==0){ns=0}; printf "%.3f", (ns/1000000) }'
}

# Check if bc is available for color coding
HAS_BC=0
if command -v bc &>/dev/null; then
    HAS_BC=1
fi

# Compare floating point numbers (returns 0 if $1 < $2)
float_lt() {
    if [[ $HAS_BC -eq 1 ]]; then
        [[ $(echo "$1 < $2" | bc -l 2>/dev/null) -eq 1 ]]
    else
        # Fallback: multiply by 1000 and compare as integers
        local a=$(awk -v n="$1" 'BEGIN{printf "%d", n * 1000}')
        local b=$(awk -v n="$2" 'BEGIN{printf "%d", n * 1000}')
        [[ $a -lt $b ]]
    fi
}

# ============================================================================
# fio option compatibility
# ============================================================================
PERCENT_OPT=""
if fio_supports "clat_percentiles"; then
    PERCENT_OPT="--clat_percentiles=1"
elif fio_supports "lat_percentiles"; then
    PERCENT_OPT="--lat_percentiles=1"
fi

PERCENT_LIST_OPT=""
if fio_supports "percentile_list"; then
    PERCENT_LIST_OPT="--percentile_list=50:90:95:99:99.9:99.99"
fi

# ============================================================================
# Print header
# ============================================================================
print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║             VPS Disk Latency Benchmark - Latency-Focused Testing          ║"
    echo "║         https://github.com/haydenjames/VPS-Disk-Latency-Bench             ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_config() {
    echo -e "${BOLD}Configuration:${NC}"
    echo "  Host:       ${HOSTTAG}"
    echo "  Timestamp:  ${TS}"
    echo "  Test file:  ${TESTFILE}"
    echo "  File size:  ${FILE_SIZE_GB} GiB"
    echo "  Runtime:    ${RUNTIME_SEC}s per test (+ ${WARMUP_SEC}s warmup)"
    echo "  I/O Engine: ${ENGINE}"
    echo "  Direct I/O: ${DIRECT}"
    echo ""
    echo -e "${BOLD}Output files:${NC}"
    echo "  Summary:    ${OUT_TXT}"
    echo "  Raw JSON:   ${OUT_JSON}"
    echo ""
}

# ============================================================================
# Run fio benchmark
# ============================================================================
run_fio() {
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
        --output-format=json 2>/dev/null
}

# ============================================================================
# Results storage
# ============================================================================
declare -a RESULTS_NAME=()
declare -a RESULTS_R_IOPS=()
declare -a RESULTS_R_AVG=()
declare -a RESULTS_R_P999=()
declare -a RESULTS_W_IOPS=()
declare -a RESULTS_W_AVG=()
declare -a RESULTS_W_P999=()

# ============================================================================
# Main execution
# ============================================================================
print_header
print_config

# Prepare test file
echo -e "${BOLD}Preparing test file...${NC}"
if dd if=/dev/zero of="$TESTFILE" bs=1M count=$((FILE_SIZE_GB*1024)) conv=fsync status=progress 2>/dev/null; then
    :
elif dd if=/dev/zero of="$TESTFILE" bs=1M count=$((FILE_SIZE_GB*1024)) conv=fsync status=none 2>/dev/null; then
    :
else
    echo "dd with conv=fsync failed; trying without fsync..."
    dd if=/dev/zero of="$TESTFILE" bs=1M count=$((FILE_SIZE_GB*1024)) status=none 2>/dev/null
    sync
fi
echo -e "${GREEN}Test file ready.${NC}"
echo ""

# Initialize JSON output
echo "[" > "$OUT_JSON"
first=1

# Initialize TXT output with header
{
    echo "==============================================================================="
    echo "                    VPS Disk Latency Benchmark Results"
    echo "==============================================================================="
    echo ""
    echo "Host:       ${HOSTTAG}"
    echo "Timestamp:  ${TS} (UTC)"
    echo "Test File:  ${TESTFILE} (${FILE_SIZE_GB} GiB)"
    echo "Runtime:    ${RUNTIME_SEC}s per test (+ ${WARMUP_SEC}s warmup)"
    echo "I/O Engine: ${ENGINE}"
    echo "Direct I/O: ${DIRECT}"
    echo ""
    echo "==============================================================================="
    echo ""
} > "$OUT_TXT"

# Count total tests for progress
total_tests=0
for bs in $BS_LIST; do
    for mix in $MIX_LIST; do
        for depth in $IODEPTHS; do
            for jobs in $JOBS_LIST; do
                ((total_tests++)) || true
            done
        done
    done
done

current_test=0

echo -e "${BOLD}Running ${total_tests} benchmark tests...${NC}"
echo ""

for bs in $BS_LIST; do
    for mix in $MIX_LIST; do
        for depth in $IODEPTHS; do
            for jobs in $JOBS_LIST; do
                ((current_test++)) || true
                name="randrw_${mix}read_${bs}_qd${depth}_jobs${jobs}"
                
                # Progress indicator
                echo -ne "\r  [${current_test}/${total_tests}] Running: ${name}...                    "
                
                json="$(run_fio "$name" randrw "$mix" "$bs" "$depth" "$jobs")"

                if [ "$first" -eq 1 ]; then
                    first=0
                else
                    echo "," >> "$OUT_JSON"
                fi
                echo "$json" >> "$OUT_JSON"

                # Extract metrics from JSON using more robust parsing
                r_iops="$(echo "$json" | awk '/"read".*:.*\{/,/\}/' | awk -F: '/"iops"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
                w_iops="$(echo "$json" | awk '/"write".*:.*\{/,/\}/' | awk -F: '/"iops"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"

                # Get clat mean
                r_clat_ns="$(echo "$json" | awk '/"read"/,/"write"/' | awk '/"clat_ns"/,/\}/' | awk -F: '/"mean"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
                w_clat_ns="$(echo "$json" | awk '/"write"/,/}]}/' | awk '/"clat_ns"/,/\}/' | awk -F: '/"mean"/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"

                # Get p99.9 percentile
                r_p999_ns="$(echo "$json" | awk '/"read"/,/"write"/' | awk '/"percentile"/,/\}/' | awk -F: '/"99.900000"/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
                w_p999_ns="$(echo "$json" | awk '/"write"/,/}]}/' | awk '/"percentile"/,/\}/' | awk -F: '/"99.900000"/{gsub(/[^0-9]/,"",$2); print $2; exit}')"

                r_clat_ms="$(ns_to_ms "$r_clat_ns")"
                w_clat_ms="$(ns_to_ms "$w_clat_ns")"
                r_p999_ms="$(ns_to_ms "$r_p999_ns")"
                w_p999_ms="$(ns_to_ms "$w_p999_ns")"

                # Store results for final table
                RESULTS_NAME+=("$name")
                RESULTS_R_IOPS+=("${r_iops:-0}")
                RESULTS_R_AVG+=("${r_clat_ms:-0.000}")
                RESULTS_R_P999+=("${r_p999_ms:-0.000}")
                RESULTS_W_IOPS+=("${w_iops:-0}")
                RESULTS_W_AVG+=("${w_clat_ms:-0.000}")
                RESULTS_W_P999+=("${w_p999_ms:-0.000}")

            done
        done
    done
done

echo "]" >> "$OUT_JSON"
echo ""
echo ""

# ============================================================================
# Cleanup
# ============================================================================
echo -e "${BOLD}Cleaning up test file...${NC}"
rm -f "$TESTFILE" 2>/dev/null || true
sync 2>/dev/null || true
echo -e "${GREEN}Done.${NC}"
echo ""

# ============================================================================
# Print formatted results table
# ============================================================================
print_results_table() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                           BENCHMARK RESULTS                                                        ║"
    echo "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣"
    echo -e "${NC}"
    
    # Table header
    printf "${BOLD}%-32s │ %12s %10s %10s │ %12s %10s %10s${NC}\n" \
        "Test Name" "Read IOPS" "Avg (ms)" "p99.9" "Write IOPS" "Avg (ms)" "p99.9"
    echo "─────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────"
    
    for i in "${!RESULTS_NAME[@]}"; do
        local name="${RESULTS_NAME[$i]}"
        local r_iops="${RESULTS_R_IOPS[$i]}"
        local r_avg="${RESULTS_R_AVG[$i]}"
        local r_p999="${RESULTS_R_P999[$i]}"
        local w_iops="${RESULTS_W_IOPS[$i]}"
        local w_avg="${RESULTS_W_AVG[$i]}"
        local w_p999="${RESULTS_W_P999[$i]}"
        
        # Format IOPS with thousand separators
        r_iops_fmt=$(printf "%'.0f" "${r_iops%.*}" 2>/dev/null || echo "$r_iops")
        w_iops_fmt=$(printf "%'.0f" "${w_iops%.*}" 2>/dev/null || echo "$w_iops")
        
        # Color code p99.9 latency
        local r_p999_color="" w_p999_color=""
        if [[ $USE_COLOR -eq 1 ]]; then
            if float_lt "$r_p999" "0.3"; then
                r_p999_color="${GREEN}"
            elif float_lt "$r_p999" "0.5"; then
                r_p999_color="${YELLOW}"
            else
                r_p999_color="${RED}"
            fi
            
            if float_lt "$w_p999" "0.3"; then
                w_p999_color="${GREEN}"
            elif float_lt "$w_p999" "0.5"; then
                w_p999_color="${YELLOW}"
            else
                w_p999_color="${RED}"
            fi
        fi
        
        printf "%-32s │ %12s %10s ${r_p999_color}%10s${NC} │ %12s %10s ${w_p999_color}%10s${NC}\n" \
            "$name" "$r_iops_fmt" "$r_avg" "$r_p999" "$w_iops_fmt" "$w_avg" "$w_p999"
    done
    
    echo "─────────────────────────────────┴─────────────────────────────────────┴─────────────────────────────────────"
    echo ""
}

print_summary_stats() {
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                              KEY METRICS (qd1_jobs1)${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Find qd1_jobs1 70/30 results (typically index 0 for 4k)
    for i in "${!RESULTS_NAME[@]}"; do
        if [[ "${RESULTS_NAME[$i]}" == *"4k_qd1_jobs1"* ]] && [[ "${RESULTS_NAME[$i]}" == *"70read"* ]]; then
            local r_p999="${RESULTS_R_P999[$i]}"
            local w_p999="${RESULTS_W_P999[$i]}"
            local r_iops="${RESULTS_R_IOPS[$i]}"
            local w_iops="${RESULTS_W_IOPS[$i]}"
            
            r_iops_fmt=$(printf "%'.0f" "${r_iops%.*}" 2>/dev/null || echo "$r_iops")
            w_iops_fmt=$(printf "%'.0f" "${w_iops%.*}" 2>/dev/null || echo "$w_iops")
            
            echo -e "  ${BOLD}4K Random Read/Write (70/30) at Queue Depth 1:${NC}"
            echo ""
            
            # Read p99.9 assessment
            echo -n "    Read  p99.9 Latency:  ${r_p999} ms  "
            if float_lt "$r_p999" "0.3"; then
                echo -e "${GREEN}✓ Excellent (NVMe-class)${NC}"
            elif float_lt "$r_p999" "0.5"; then
                echo -e "${YELLOW}◐ Acceptable${NC}"
            else
                echo -e "${RED}✗ Poor (not NVMe-class responsiveness)${NC}"
            fi
            
            # Write p99.9 assessment
            echo -n "    Write p99.9 Latency:  ${w_p999} ms  "
            if float_lt "$w_p999" "0.3"; then
                echo -e "${GREEN}✓ Excellent (NVMe-class)${NC}"
            elif float_lt "$w_p999" "0.5"; then
                echo -e "${YELLOW}◐ Acceptable${NC}"
            else
                echo -e "${RED}✗ Poor (not NVMe-class responsiveness)${NC}"
            fi
            
            echo ""
            echo "    Read  IOPS: ${r_iops_fmt}"
            echo "    Write IOPS: ${w_iops_fmt}"
            echo ""
            break
        fi
    done
    
    echo -e "${BOLD}  Latency Thresholds:${NC}"
    echo -e "    ${GREEN}< 0.3ms${NC}  = Excellent (true NVMe-class performance)"
    echo -e "    ${YELLOW}< 0.5ms${NC}  = Acceptable"
    echo -e "    ${RED}>= 0.5ms${NC} = Poor (likely throttled, shared, or not true NVMe)"
    echo ""
}

# Print to terminal
print_results_table
print_summary_stats

# ============================================================================
# Write formatted results to TXT file
# ============================================================================
{
    echo "DETAILED RESULTS"
    echo "==============================================================================="
    echo ""
    printf "%-32s | %12s %10s %10s | %12s %10s %10s\n" \
        "Test Name" "Read IOPS" "Avg (ms)" "p99.9" "Write IOPS" "Avg (ms)" "p99.9"
    echo "─────────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────"
    
    for i in "${!RESULTS_NAME[@]}"; do
        r_iops_fmt=$(printf "%'.0f" "${RESULTS_R_IOPS[$i]%.*}" 2>/dev/null || echo "${RESULTS_R_IOPS[$i]}")
        w_iops_fmt=$(printf "%'.0f" "${RESULTS_W_IOPS[$i]%.*}" 2>/dev/null || echo "${RESULTS_W_IOPS[$i]}")
        
        printf "%-32s | %12s %10s %10s | %12s %10s %10s\n" \
            "${RESULTS_NAME[$i]}" \
            "$r_iops_fmt" "${RESULTS_R_AVG[$i]}" "${RESULTS_R_P999[$i]}" \
            "$w_iops_fmt" "${RESULTS_W_AVG[$i]}" "${RESULTS_W_P999[$i]}"
    done
    
    echo "─────────────────────────────────┴─────────────────────────────────────┴─────────────────────────────────────"
    echo ""
    echo ""
    echo "KEY METRICS (qd1_jobs1 - Most Realistic Workload)"
    echo "==============================================================================="
    echo ""
    
    for i in "${!RESULTS_NAME[@]}"; do
        if [[ "${RESULTS_NAME[$i]}" == *"4k_qd1_jobs1"* ]] && [[ "${RESULTS_NAME[$i]}" == *"70read"* ]]; then
            r_iops_fmt=$(printf "%'.0f" "${RESULTS_R_IOPS[$i]%.*}" 2>/dev/null || echo "${RESULTS_R_IOPS[$i]}")
            w_iops_fmt=$(printf "%'.0f" "${RESULTS_W_IOPS[$i]%.*}" 2>/dev/null || echo "${RESULTS_W_IOPS[$i]}")
            
            echo "4K Random Read/Write (70/30) at Queue Depth 1:"
            echo ""
            echo "  Read  p99.9 Latency:  ${RESULTS_R_P999[$i]} ms"
            echo "  Write p99.9 Latency:  ${RESULTS_W_P999[$i]} ms"
            echo "  Read  IOPS:           ${r_iops_fmt}"
            echo "  Write IOPS:           ${w_iops_fmt}"
            echo ""
            
            # Assessment
            echo "Assessment:"
            r_p999="${RESULTS_R_P999[$i]}"
            w_p999="${RESULTS_W_P999[$i]}"
            
            if float_lt "$r_p999" "0.3"; then
                echo "  Read:  EXCELLENT - True NVMe-class latency"
            elif float_lt "$r_p999" "0.5"; then
                echo "  Read:  ACCEPTABLE - Reasonable latency"
            else
                echo "  Read:  POOR - Not NVMe-class responsiveness (>0.3ms threshold)"
            fi
            
            if float_lt "$w_p999" "0.3"; then
                echo "  Write: EXCELLENT - True NVMe-class latency"
            elif float_lt "$w_p999" "0.5"; then
                echo "  Write: ACCEPTABLE - Reasonable latency"
            else
                echo "  Write: POOR - Not NVMe-class responsiveness (>0.3ms threshold)"
            fi
            break
        fi
    done
    
    echo ""
    echo ""
    echo "LATENCY THRESHOLDS"
    echo "==============================================================================="
    echo "  < 0.3ms  = Excellent (true NVMe-class performance)"
    echo "  < 0.5ms  = Acceptable"
    echo "  >= 0.5ms = Poor (likely throttled, shared, or not true NVMe)"
    echo ""
    echo ""
    echo "RAW DATA"
    echo "==============================================================================="
    echo ""
    
    for i in "${!RESULTS_NAME[@]}"; do
        printf "%s | read IOPS: %s avg(ms): %s p99.9(ms): %s || write IOPS: %s avg(ms): %s p99.9(ms): %s\n" \
            "${RESULTS_NAME[$i]}" \
            "${RESULTS_R_IOPS[$i]}" "${RESULTS_R_AVG[$i]}" "${RESULTS_R_P999[$i]}" \
            "${RESULTS_W_IOPS[$i]}" "${RESULTS_W_AVG[$i]}" "${RESULTS_W_P999[$i]}"
    done
    
} >> "$OUT_TXT"

# ============================================================================
# Final output
# ============================================================================
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                                 OUTPUT FILES${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Text Summary:${NC}  ${OUT_TXT}"
echo -e "  ${BOLD}Raw JSON:${NC}      ${OUT_JSON}"
echo ""
echo -e "  View results:  ${CYAN}cat ${OUT_TXT}${NC}"
echo -e "  Parse JSON:    ${CYAN}cat ${OUT_JSON} | jq .${NC}"
echo ""
echo -e "${GREEN}Benchmark complete!${NC}"
echo ""
