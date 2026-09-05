#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="$script_dir/pseudo_screensaver.swift"
cache_dir="${POWER_MODE_PSEUDO_CACHE_DIR:-$HOME/Library/Caches/power-mode}"
binary="$cache_dir/pseudo-screensaver"
pid_file="$cache_dir/pseudo-screensaver.pid"
idle_file="$cache_dir/pseudo-screensaver.idle-seconds"
runner_file="$cache_dir/pseudo-screensaver.runner"
stop_file="$cache_dir/pseudo-screensaver.stop"
log_file="$cache_dir/pseudo-screensaver.log"
brightness_state_file="$cache_dir/pseudo-screensaver.brightness-state"
launchctl_binary="${POWER_MODE_LAUNCHCTL:-/bin/launchctl}"
legacy_launchd_label="${POWER_MODE_PSEUDO_LEGACY_LAUNCHD_LABEL:-com.kazuhideoki.power-mode-activate}"

usage() {
  cat <<'EOF'
Usage: pseudo_screensaver_control.sh start [idle-seconds]
       pseudo_screensaver_control.sh stop
       pseudo_screensaver_control.sh status
       pseudo_screensaver_control.sh build
       pseudo_screensaver_control.sh rebuild
       pseudo_screensaver_control.sh refresh [idle-seconds]
EOF
}

read_pid() {
  if [ -f "$pid_file" ]; then
    sed -n '1p' "$pid_file"
  fi
}

is_running() {
  local pid
  pid="$(read_pid)"
  case "$pid" in
  '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

wait_for_exit() {
  local pid="$1"
  local attempts="$2"
  local _attempt

  for ((_attempt = 0; _attempt < attempts; _attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

stop_legacy_launchd_job() {
  [ -n "$legacy_launchd_label" ] || return 0
  [ -x "$launchctl_binary" ] || return 0

  if "$launchctl_binary" list "$legacy_launchd_label" >/dev/null 2>&1; then
    "$launchctl_binary" remove "$legacy_launchd_label"
  fi
}

m1ddc_binary() {
  if [ -n "${POWER_MODE_M1DDC:-}" ] && [ -x "$POWER_MODE_M1DDC" ]; then
    printf '%s\n' "$POWER_MODE_M1DDC"
  elif [ -x /opt/homebrew/bin/m1ddc ]; then
    printf '%s\n' /opt/homebrew/bin/m1ddc
  elif [ -x /usr/local/bin/m1ddc ]; then
    printf '%s\n' /usr/local/bin/m1ddc
  fi
}

restore_external_brightness() {
  [ -f "$brightness_state_file" ] || return 0

  local m1ddc
  local selector
  local uuid
  local brightness
  local extra
  local failed_state_file
  local total_entries=0
  local failed_entries=0

  m1ddc="$(m1ddc_binary)"
  if [ -z "$m1ddc" ]; then
    echo "Warning: External display brightness restore requires m1ddc; continuing." >&2
    return 0
  fi

  failed_state_file="${brightness_state_file}.tmp.$$"
  rm -f "$failed_state_file"
  : >"$failed_state_file"

  while read -r selector brightness extra; do
    total_entries=$((total_entries + 1))
    case "$selector" in
    uuid=*) uuid="${selector#uuid=}" ;;
    *)
      rm -f "$failed_state_file"
      echo "Warning: Invalid brightness restore state: $brightness_state_file; continuing." >&2
      return 0
      ;;
    esac
    case "$uuid" in
    '' | *[!0-9A-Fa-f-]*)
      rm -f "$failed_state_file"
      echo "Warning: Invalid brightness restore state: $brightness_state_file; continuing." >&2
      return 0
      ;;
    esac
    case "$brightness" in
    '' | *[!0-9]*)
      rm -f "$failed_state_file"
      echo "Warning: Invalid brightness restore state: $brightness_state_file; continuing." >&2
      return 0
      ;;
    esac
    if [ -n "$extra" ] || [ "$brightness" -gt 100 ]; then
      rm -f "$failed_state_file"
      echo "Warning: Invalid brightness restore state: $brightness_state_file; continuing." >&2
      return 0
    fi
    if ! "$m1ddc" display "$selector" set luminance "$brightness" \
      >/dev/null 2>&1; then
      failed_entries=$((failed_entries + 1))
      printf '%s %s\n' "$selector" "$brightness" >>"$failed_state_file"
    fi
  done <"$brightness_state_file"

  if [ "$failed_entries" -eq 0 ]; then
    rm -f "$brightness_state_file" "$failed_state_file"
    return 0
  fi

  if [ "$total_entries" -eq 1 ] &&
    "$m1ddc" set luminance 50 >/dev/null 2>&1; then
    rm -f "$brightness_state_file" "$failed_state_file"
    echo "Restored the default external display brightness to 50%." >&2
    return 0
  fi

  mv "$failed_state_file" "$brightness_state_file"
  echo "Warning: Failed to restore external display brightness; continuing." >&2
  return 0
}

build_binary() {
  local force="${1:-0}"
  local compiler_log
  local fallback_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk"
  local fallback_target
  fallback_target="$(uname -m)-apple-macosx15.0"
  mkdir -p "$cache_dir"

  if [ "$force" -eq 0 ] && [ -x "$binary" ] && [ "$binary" -nt "$source_file" ]; then
    return 0
  fi

  local temporary_binary
  temporary_binary="$cache_dir/pseudo-screensaver.build.$$"
  compiler_log="$cache_dir/pseudo-screensaver.build.$$.log"
  trap 'rm -f "$cache_dir/pseudo-screensaver.build.$$" "$cache_dir/pseudo-screensaver.build.$$.log"' EXIT
  mkdir -p "$cache_dir/module-cache"
  if swiftc \
    -O \
    -parse-as-library \
    -module-cache-path "$cache_dir/module-cache" \
    -framework AppKit \
    -framework CoreGraphics \
    "$source_file" \
    -o "$temporary_binary" 2>"$compiler_log"; then
    :
  elif [ -d "$fallback_sdk" ] && swiftc \
    -sdk "$fallback_sdk" \
    -target "$fallback_target" \
    -O \
    -parse-as-library \
    -module-cache-path "$cache_dir/module-cache" \
    -framework AppKit \
    -framework CoreGraphics \
    "$source_file" \
    -o "$temporary_binary" 2>>"$compiler_log"; then
    :
  else
    cat "$compiler_log" >&2
    rm -f "$compiler_log"
    return 1
  fi
  rm -f "$compiler_log"
  mv "$temporary_binary" "$binary"
  trap - EXIT
}

refresh_app() {
  local idle_seconds="${1:-}"

  if [ -z "$idle_seconds" ]; then
    idle_seconds="$(sed -n '1p' "$idle_file" 2>/dev/null || true)"
    idle_seconds="${idle_seconds:-300}"
  fi

  stop_app
  build_binary 1
  start_app "$idle_seconds"
}

start_app() {
  local idle_seconds="${1:-300}"
  case "$idle_seconds" in
  '' | *[!0-9]* | 0)
    echo "idle-seconds は1以上の整数で指定してください: $idle_seconds" >&2
    exit 1
    ;;
  esac

  stop_legacy_launchd_job
  if is_running && [ "$binary" -nt "$source_file" ]; then
    if [ "$(sed -n '1p' "$idle_file" 2>/dev/null || true)" = "$idle_seconds" ] &&
      [ "$(sed -n '1p' "$runner_file" 2>/dev/null || true)" = "caffeinate" ]; then
      echo "Pseudo screen saver is already running (PID $(read_pid))."
      return 0
    fi
  fi
  if is_running; then
    stop_app
  fi

  restore_external_brightness
  build_binary
  rm -f "$pid_file" "$stop_file"
  nohup /usr/bin/caffeinate -dims "$binary" \
    --idle-seconds "$idle_seconds" \
    --stop-file "$stop_file" \
    --brightness-state-file "$brightness_state_file" \
    >>"$log_file" 2>&1 </dev/null 9>&- &
  local pid=$!
  printf '%s\n' "$pid" >"$pid_file"
  printf '%s\n' "$idle_seconds" >"$idle_file"
  printf '%s\n' "caffeinate" >"$runner_file"

  local _attempt
  sleep 0.2
  for _attempt in 1 2 3 4 5; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "Pseudo screen saver started (PID $pid, idle ${idle_seconds}s)."
      return 0
    fi
    sleep 0.2
  done

  rm -f "$pid_file" "$idle_file" "$runner_file"
  echo "Pseudo screen saver failed to start. See: $log_file" >&2
  exit 1
}

stop_app() {
  local pid

  stop_legacy_launchd_job
  if ! is_running; then
    restore_external_brightness
    rm -f "$pid_file" "$idle_file" "$runner_file" "$stop_file"
    echo "Pseudo screen saver is not running."
    return 0
  fi

  pid="$(read_pid)"
  : >"$stop_file"
  if ! wait_for_exit "$pid" 25; then
    kill "$pid" 2>/dev/null || true
    if ! wait_for_exit "$pid" 10; then
      echo "Pseudo screen saver failed to stop (PID $pid)." >&2
      exit 1
    fi
  fi
  restore_external_brightness
  rm -f "$pid_file" "$idle_file" "$runner_file" "$stop_file"
  echo "Pseudo screen saver stopped."
}

print_status() {
  if is_running; then
    echo "running (PID $(read_pid))"
  else
    echo "stopped"
  fi
}

case "${1:-}" in
start)
  start_app "${2:-300}"
  ;;
stop)
  stop_app
  ;;
status)
  print_status
  ;;
build)
  build_binary
  echo "Built: $binary"
  ;;
rebuild)
  build_binary 1
  echo "Rebuilt: $binary"
  ;;
refresh)
  refresh_app "${2:-}"
  ;;
-h | --help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
