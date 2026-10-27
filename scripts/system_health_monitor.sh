#!/usr/bin/env bash

set -u
set -o pipefail

CPU_THRESHOLD=${CPU_THRESHOLD:-80}
MEMORY_THRESHOLD=${MEMORY_THRESHOLD:-80}
DISK_THRESHOLD=${DISK_THRESHOLD:-80}
DISK_PATH=${DISK_PATH:-/}
LOG_FILE=${LOG_FILE:-}
INTERVAL=${INTERVAL:-60}
REPEAT=false
TEST_ALERTS=false

usage() {
	cat <<'EOF'
Usage: system_health_monitor.sh [options]

Options:
  --cpu-threshold N       Alert above N percent CPU (default: 80)
  --memory-threshold N    Alert above N percent memory (default: 80)
  --disk-threshold N      Alert above N percent disk usage (default: 80)
  --disk-path PATH        Filesystem path to check (default: /)
  --log-file PATH         Append output to this file as well as the console
  --repeat                Continue monitoring until interrupted
  --interval SECONDS      Delay between passes (default: 60)
  --test-alerts           Simulate threshold breaches without stressing the host
  -h, --help              Show this help

Environment equivalents: CPU_THRESHOLD, MEMORY_THRESHOLD, DISK_THRESHOLD,
DISK_PATH, LOG_FILE, INTERVAL.
EOF
}

fail() {
	printf 'ERROR: %s\n' "$1" >&2
	exit 2
}

while (($#)); do
	case "$1" in
		--cpu-threshold) (($# >= 2)) || fail "missing value for $1"; CPU_THRESHOLD=$2; shift 2 ;;
		--memory-threshold) (($# >= 2)) || fail "missing value for $1"; MEMORY_THRESHOLD=$2; shift 2 ;;
		--disk-threshold) (($# >= 2)) || fail "missing value for $1"; DISK_THRESHOLD=$2; shift 2 ;;
		--disk-path) (($# >= 2)) || fail "missing value for $1"; DISK_PATH=$2; shift 2 ;;
		--log-file) (($# >= 2)) || fail "missing value for $1"; LOG_FILE=$2; shift 2 ;;
		--interval) (($# >= 2)) || fail "missing value for $1"; INTERVAL=$2; shift 2 ;;
		--repeat) REPEAT=true; shift ;;
		--test-alerts) TEST_ALERTS=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) fail "unknown option: $1" ;;
	esac
done

valid_percent() {
	[[ "$1" =~ ^([0-9]{1,2}|100)(\.[0-9]+)?$ ]]
}

valid_percent "$CPU_THRESHOLD" || fail "CPU threshold must be between 0 and 100"
valid_percent "$MEMORY_THRESHOLD" || fail "memory threshold must be between 0 and 100"
valid_percent "$DISK_THRESHOLD" || fail "disk threshold must be between 0 and 100"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || fail "interval must be a positive whole number of seconds"

[[ "$(uname -s 2>/dev/null || true)" == Linux ]] || fail "this monitor supports Linux only (use WSL 2 or Ubuntu on Windows)"
[[ -r /proc/stat && -r /proc/meminfo ]] || fail "Linux /proc/stat and /proc/meminfo are required"

for command_name in awk date df ps sleep; do
	command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
[[ -d "$DISK_PATH" ]] || fail "disk path does not exist: $DISK_PATH"

log_line() {
	printf '%s\n' "$1"
	if [[ -n "$LOG_FILE" ]]; then
		printf '%s\n' "$1" >> "$LOG_FILE" || fail "cannot append to log file: $LOG_FILE"
	fi
}

cpu_counters() {
	awk '$1 == "cpu" { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print total, idle; exit }' /proc/stat
}

check_pass() {
	local total_before idle_before total_after idle_after cpu_usage
	local memory_usage disk_usage process_count problem=false timestamp line
	read -r total_before idle_before < <(cpu_counters)
	if [[ -z "${total_before:-}" || -z "${idle_before:-}" ]]; then
		log_line "ERROR: could not read initial CPU counters"
		return 1
	fi
	sleep 1
	read -r total_after idle_after < <(cpu_counters)
	if [[ -z "${total_after:-}" || -z "${idle_after:-}" ]]; then
		log_line "ERROR: could not read CPU counters after sampling"
		return 1
	fi

	if [[ "$TEST_ALERTS" == true ]]; then
		cpu_usage=100
		memory_usage=100
		disk_usage=100
	else
		cpu_usage=$(awk -v t1="$total_before" -v i1="$idle_before" -v t2="$total_after" -v i2="$idle_after" 'BEGIN { dt=t2-t1; di=i2-i1; if (dt <= 0 || di < 0 || di > dt) exit 1; printf "%.1f", 100*(dt-di)/dt }') || {
			log_line "ERROR: could not calculate CPU usage"
			return 1
		}
		memory_usage=$(awk '
			/^MemTotal:/ { total=$2 }
			/^MemAvailable:/ { available=$2 }
			END { if (total <= 0 || available < 0) exit 1; printf "%.1f", 100*(total-available)/total }
		' /proc/meminfo) || {
			log_line "ERROR: could not calculate memory usage"
			return 1
		}
		disk_usage=$(df -P "$DISK_PATH" | awk 'NR == 2 { sub(/%$/, "", $5); print $5 }') || {
			log_line "ERROR: could not measure disk usage at $DISK_PATH"
			return 1
		}
		if [[ ! "$disk_usage" =~ ^[0-9]+$ ]]; then
			log_line "ERROR: invalid disk usage result for $DISK_PATH"
			return 1
		fi
	fi
	process_count=$(ps -e --no-headers | awk 'END { print NR+0 }') || {
		log_line "ERROR: could not count running processes"
		return 1
	}
	timestamp=$(date --iso-8601=seconds) || {
		log_line "ERROR: could not read the current time"
		return 1
	}

	line="[$timestamp] CPU ${cpu_usage}% (threshold ${CPU_THRESHOLD}%) | Memory ${memory_usage}% (threshold ${MEMORY_THRESHOLD}%) | Disk ${disk_usage}% on ${DISK_PATH} (threshold ${DISK_THRESHOLD}%) | Processes ${process_count}"
	log_line "$line"

	if awk -v value="$cpu_usage" -v threshold="$CPU_THRESHOLD" 'BEGIN { exit !(value > threshold) }'; then
		log_line "[$timestamp] ALERT: CPU usage ${cpu_usage}% exceeds ${CPU_THRESHOLD}%"
		problem=true
	fi
	if awk -v value="$memory_usage" -v threshold="$MEMORY_THRESHOLD" 'BEGIN { exit !(value > threshold) }'; then
		log_line "[$timestamp] ALERT: memory usage ${memory_usage}% exceeds ${MEMORY_THRESHOLD}%"
		problem=true
	fi
	if awk -v value="$disk_usage" -v threshold="$DISK_THRESHOLD" 'BEGIN { exit !(value > threshold) }'; then
		log_line "[$timestamp] ALERT: disk usage ${disk_usage}% exceeds ${DISK_THRESHOLD}%"
		problem=true
	fi
	[[ "$problem" == false ]]
}

overall_status=0
while true; do
	if ! check_pass; then
		overall_status=1
	fi
	[[ "$REPEAT" == true ]] || break
	sleep "$INTERVAL"
done

exit "$overall_status"
