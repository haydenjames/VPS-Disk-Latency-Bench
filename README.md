# VPS Disk Latency Bench (fio)

Latency-focused disk benchmarks for VPS environments.

This runs small-block mixed random I/O at low queue depths and light concurrency, then prints a simple text summary plus raw JSON.

## Why latency, not IOPS?

Most VPS workloads (web servers, databases, applications) operate at queue depth 1-2 with single-threaded I/O. High IOPS numbers from synthetic benchmarks at qd32+ don't reflect real-world performance. This script tests what actually matters: **p99.9 latency at low queue depth**.

## Requirements

- `fio`
- `dd`, `awk`, `sed`, `date`

## Quick run
```bash
chmod +x vps-disk-latency-bench.sh
./vps-disk-latency-bench.sh
```

## Output

The script creates two files in `./bench_out/`:
- `.txt` - Human-readable summary with IOPS, avg latency, and p99.9 latency
- `.json` - Raw fio output for detailed analysis

## What to look for

Focus on **p99.9 latency** in the `4k_qd1_jobs1` tests. For NVMe storage, you should see values under 0.3ms. Higher values suggest noisy neighbors, rate limiting, or oversubscribed storage.

## License

MIT
