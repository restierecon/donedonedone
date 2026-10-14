#!/bin/bash

usage() {
  echo "usage: test-workers.sh [--mb <MiB per worker>] [--max <workers>] [--share <gates running>] [--reserve <MiB>] [--explain]" >&2
  exit 2
}

per_worker_mb=1024 max="" share=1 reserve_mb="${GATE_WORKERS_RESERVE_MB:-1024}" explain=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mb) per_worker_mb="$2"; shift 2 ;;
    --max) max="$2"; shift 2 ;;
    --share) share="$2"; shift 2 ;;
    --reserve) reserve_mb="$2"; shift 2 ;;
    --explain) explain=1; shift ;;
    *) usage ;;
  esac
done
for v in "$per_worker_mb" "$share" "$reserve_mb" ${max:+"$max"}; do
  case "$v" in ''|*[!0-9]*) usage ;; esac
done
if [ "$per_worker_mb" -lt 1 ] || [ "$share" -lt 1 ]; then usage; fi

PROC="${TEST_WORKERS_PROC:-/proc}"
CGROUP="${TEST_WORKERS_CGROUP:-/sys/fs/cgroup}"

read_num() {
  local v
  [ -r "$1" ] || return 1
  v=$(tr -d ' \r\n' < "$1")
  case "$v" in ''|*[!0-9-]*) return 1 ;; esac
  printf '%s\n' "$v"
}

cpu_count() {
  local n
  n=$(nproc 2>/dev/null) \
    || n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) \
    || n=$(sysctl -n hw.ncpu 2>/dev/null) \
    || n="${NUMBER_OF_PROCESSORS:-1}"
  case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
  printf '%s\n' "$n"
}

cgroup_paths() {
  local controller="$1" line path
  [ -r "$PROC/self/cgroup" ] || { echo /; return; }
  while IFS= read -r line; do
    case "$line" in
      0::*) [ "$controller" = v2 ] && path="${line#0::}" ;;
      *:*"$controller"*:*) [ "$controller" != v2 ] && path="${line#*:*:}" ;;
    esac
  done < "$PROC/self/cgroup"
  path="${path:-/}"
  while :; do
    printf '%s\n' "$path"
    [ "$path" = / ] && break
    path="${path%/*}"; path="${path:-/}"
  done
}

cpu_quota() {
  local best="" p q period n
  for p in $(cgroup_paths v2); do
    [ -r "$CGROUP$p/cpu.max" ] || continue
    read -r q period < "$CGROUP$p/cpu.max"
    case "$q$period" in *[!0-9]*|'') continue ;; esac
    n=$(( (q + period - 1) / period ))
    { [ -z "$best" ] || [ "$n" -lt "$best" ]; } && best=$n
  done
  for p in $(cgroup_paths cpu); do
    q=$(read_num "$CGROUP/cpu$p/cpu.cfs_quota_us") || q=$(read_num "$CGROUP/cpu,cpuacct$p/cpu.cfs_quota_us") || continue
    period=$(read_num "$CGROUP/cpu$p/cpu.cfs_period_us") || period=$(read_num "$CGROUP/cpu,cpuacct$p/cpu.cfs_period_us") || continue
    [ "$q" -gt 0 ] || continue
    [ "$period" -gt 0 ] || continue
    n=$(( (q + period - 1) / period ))
    { [ -z "$best" ] || [ "$n" -lt "$best" ]; } && best=$n
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

meminfo_kb() {
  awk -v key="$1:" '$1 == key { print $2; exit }' "$PROC/meminfo" 2>/dev/null
}

mem_total_kb="" mem_free_kb=""
consider() {
  local total="$1" free="$2"
  [ "$total" -gt 0 ] 2>/dev/null || return 0
  [ "$free" -lt 0 ] && free=0
  { [ -z "$mem_total_kb" ] || [ "$total" -lt "$mem_total_kb" ]; } && mem_total_kb=$total
  { [ -z "$mem_free_kb" ] || [ "$free" -lt "$mem_free_kb" ]; } && mem_free_kb=$free
  return 0
}

sysctl_num() {
  local v
  v=$(sysctl -n "$1" 2>/dev/null | tr -d ' \r\n')
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

linux_mem() {
  local avail p limit used inactive unlimited_kb=$(( 1 << 42 ))
  if [ -r "$PROC/meminfo" ]; then
    avail=$(meminfo_kb MemAvailable)
    [ -n "$avail" ] || avail=$(meminfo_kb MemFree)
    consider "$(meminfo_kb MemTotal)" "${avail:-0}"
  fi
  for p in $(cgroup_paths v2); do
    [ -r "$CGROUP$p/memory.max" ] || continue
    limit=$(tr -d ' \r\n' < "$CGROUP$p/memory.max")
    case "$limit" in ''|max|*[!0-9]*) continue ;; esac
    used=$(read_num "$CGROUP$p/memory.current") || used=0
    inactive=$(awk '$1 == "inactive_file" { print $2; exit }' "$CGROUP$p/memory.stat" 2>/dev/null)
    consider $(( limit / 1024 )) $(( (limit - used + ${inactive:-0}) / 1024 ))
  done
  for p in $(cgroup_paths memory); do
    limit=$(read_num "$CGROUP/memory$p/memory.limit_in_bytes") || continue
    [ $(( limit / 1024 )) -lt "$unlimited_kb" ] || continue
    used=$(read_num "$CGROUP/memory$p/memory.usage_in_bytes") || used=0
    inactive=$(awk '$1 == "total_inactive_file" { print $2; exit }' "$CGROUP/memory$p/memory.stat" 2>/dev/null)
    consider $(( limit / 1024 )) $(( (limit - used + ${inactive:-0}) / 1024 ))
  done
}

darwin_mem() {
  local total page pages
  total=$(sysctl_num hw.memsize) || return 0
  page=$(sysctl_num hw.pagesize) || page=4096
  pages=$(vm_stat 2>/dev/null | awk '/^Pages (free|inactive):/ { gsub(/\./, "", $NF); n += $NF } END { print n + 0 }')
  consider $(( total / 1024 )) $(( pages * page / 1024 ))
}

bsd_mem() {
  local total page free inactive cache
  total=$(sysctl_num hw.physmem) || return 0
  page=$(sysctl_num hw.pagesize) || page=4096
  free=$(sysctl_num vm.stats.vm.v_free_count) || return 0
  inactive=$(sysctl_num vm.stats.vm.v_inactive_count) || inactive=0
  cache=$(sysctl_num vm.stats.vm.v_cache_count) || cache=0
  consider $(( total / 1024 )) $(( (free + inactive + cache) * page / 1024 ))
}

windows_mem() {
  local out total free
  if [ -r "$PROC/meminfo" ]; then
    consider "$(meminfo_kb MemTotal)" "$(meminfo_kb MemFree)"
    return 0
  fi
  # shellcheck disable=SC2016
  out=$(powershell.exe -NoProfile -NonInteractive -Command \
    '$o = Get-CimInstance Win32_OperatingSystem; "$($o.TotalVisibleMemorySize) $($o.FreePhysicalMemory)"' 2>/dev/null | tr -d '\r')
  read -r total free <<< "$out"
  case "${total:-}${free:-}" in ''|*[!0-9]*) return 0 ;; esac
  consider "$total" "$free"
}

os="${TEST_WORKERS_OS:-$(uname -s 2>/dev/null)}"
case "$os" in
  Darwin) darwin_mem ;;
  FreeBSD|DragonFly) bsd_mem ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) windows_mem ;;
  *) linux_mem ;;
esac

cpus=$(cpu_count)
case "$os" in
  Linux|'') quota=$(cpu_quota) && [ "$quota" -lt "$cpus" ] && cpus=$quota ;;
esac
by_cpu=$(( cpus / share ))

reserve_kb=$(( reserve_mb * 1024 ))
per_kb=$(( per_worker_mb * 1024 ))
if [ -n "$mem_total_kb" ]; then
  fair_kb=$(( (mem_total_kb - reserve_kb) / share ))
  free_kb=$(( mem_free_kb - reserve_kb ))
  budget_kb=$(( fair_kb < free_kb ? fair_kb : free_kb ))
  by_mem=$(( budget_kb / per_kb ))
  mem_note="$(( mem_free_kb / 1024 )) MiB free of $(( mem_total_kb / 1024 ))"
else
  by_mem=$(( (cpus + 1) / 2 / share ))
  mem_note="memory unknown, half the CPUs"
fi

workers=$(( by_cpu < by_mem ? by_cpu : by_mem ))
[ -n "$max" ] && [ "$max" -ge 1 ] && [ "$workers" -gt "$max" ] && workers=$max
[ "$workers" -lt 1 ] && workers=1

if [ "$explain" -eq 1 ]; then
  echo "$workers ($cpus CPUs, $mem_note, ${per_worker_mb} MiB/worker, $share gate(s) running)"
else
  echo "$workers"
fi
