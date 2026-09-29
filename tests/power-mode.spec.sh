#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
power_mode="$repo_root/power-mode"
controller="$repo_root/pseudo_screensaver_control.sh"
nosleep_timeout_helper="$repo_root/nosleep_timeout.sh"

assert_contains() {
  local text="$1"
  local pattern="$2"
  local label="$3"

  if [[ "$text" != *"$pattern"* ]]; then
    printf 'Assertion failed: %s\n' "$label" >&2
    printf 'Missing pattern: %s\n' "$pattern" >&2
    printf 'Actual:\n%s\n' "$text" >&2
    exit 1
  fi
}

assert_not_contains() {
  local text="$1"
  local pattern="$2"
  local label="$3"

  if [[ "$text" == *"$pattern"* ]]; then
    printf 'Assertion failed: %s\n' "$label" >&2
    printf 'Unexpected pattern: %s\n' "$pattern" >&2
    printf 'Actual:\n%s\n' "$text" >&2
    exit 1
  fi
}

temporary_dir="$(mktemp -d)"
POWER_MODE_STATE_DIR="$temporary_dir/state"
export POWER_MODE_STATE_DIR
cleanup() {
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
    "$controller" stop >/dev/null 2>&1 || true
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/fd-inheritance-cache" \
    "$controller" stop >/dev/null 2>&1 || true
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

if [ ! -x "$nosleep_timeout_helper" ]; then
  echo 'Assertion failed: the nosleep timeout helper is not executable' >&2
  exit 1
fi

for retired_mode in remote unsleep; do
  if "$power_mode" "$retired_mode" --dry-run \
    >"$temporary_dir/retired-mode.out" 2>&1; then
    printf 'Assertion failed: retired mode is still accepted: %s\n' \
      "$retired_mode" >&2
    exit 1
  fi
done

POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" "$controller" build >/dev/null
test -x "$temporary_dir/cache/pseudo-screensaver"

rebuild_marker="$temporary_dir/rebuild-marker"
touch "$rebuild_marker"
sleep 1
POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" "$controller" rebuild >/dev/null
if [ ! "$temporary_dir/cache/pseudo-screensaver" -nt "$rebuild_marker" ]; then
  echo 'Assertion failed: rebuild did not replace the cached binary' >&2
  exit 1
fi

fake_launchctl="$temporary_dir/launchctl"
launchctl_trace="$temporary_dir/launchctl.trace"
# shellcheck disable=SC2016
# The generated script expands these variables at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$*" >>"$POWER_MODE_LAUNCHCTL_TRACE"' \
  'exit 0' \
  >"$fake_launchctl"
chmod +x "$fake_launchctl"
POWER_MODE_LAUNCHCTL="$fake_launchctl" \
  POWER_MODE_LAUNCHCTL_TRACE="$launchctl_trace" \
  POWER_MODE_PSEUDO_LEGACY_LAUNCHD_LABEL=com.example.legacy-power-mode \
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
  "$controller" stop >/dev/null
assert_contains \
  "$(<"$launchctl_trace")" \
  'list com.example.legacy-power-mode' \
  'stop checks for an obsolete launchd pseudo-screen-saver job'
assert_contains \
  "$(<"$launchctl_trace")" \
  'remove com.example.legacy-power-mode' \
  'stop removes an obsolete launchd pseudo-screen-saver job'

fake_m1ddc="$temporary_dir/m1ddc"
m1ddc_trace="$temporary_dir/m1ddc.trace"
# shellcheck disable=SC2016
# The generated script expands these variables at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$*" >>"$POWER_MODE_M1DDC_TRACE"' \
  >"$fake_m1ddc"
chmod +x "$fake_m1ddc"
printf '%s\n' 'uuid=11111111-2222-3333-4444-555555555555 50' \
  >"$temporary_dir/cache/pseudo-screensaver.brightness-state"
POWER_MODE_M1DDC="$fake_m1ddc" \
  POWER_MODE_M1DDC_TRACE="$m1ddc_trace" \
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
  "$controller" stop >/dev/null
assert_contains \
  "$(<"$m1ddc_trace")" \
  'display uuid=11111111-2222-3333-4444-555555555555 set luminance 50' \
  'stop restores a persisted external-display brightness value'
if [ -e "$temporary_dir/cache/pseudo-screensaver.brightness-state" ]; then
  echo 'Assertion failed: restored brightness state was not removed' >&2
  exit 1
fi

# shellcheck disable=SC2016
# The generated script expands these variables at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$*" >>"$POWER_MODE_M1DDC_TRACE"' \
  'case "$*" in' \
  '  "display uuid="*) exit 1 ;;' \
  '  "set luminance 50") exit 0 ;;' \
  'esac' \
  'exit 1' \
  >"$fake_m1ddc"
chmod +x "$fake_m1ddc"
: >"$m1ddc_trace"
printf '%s\n' 'uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE 50' \
  >"$temporary_dir/cache/pseudo-screensaver.brightness-state"
fallback_restore_output="$(
  POWER_MODE_M1DDC="$fake_m1ddc" \
    POWER_MODE_M1DDC_TRACE="$m1ddc_trace" \
    POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
    "$controller" stop 2>&1
)"
assert_contains \
  "$(<"$m1ddc_trace")" \
  'display uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE set luminance 50' \
  'restore first tries the persisted external-display UUID'
assert_contains \
  "$(<"$m1ddc_trace")" \
  'set luminance 50' \
  'restore falls back to 50 percent on the default external display'
assert_contains \
  "$fallback_restore_output" \
  'Restored the default external display brightness to 50%.' \
  'restore reports a successful default-display fallback'
if [ -e "$temporary_dir/cache/pseudo-screensaver.brightness-state" ]; then
  echo 'Assertion failed: fallback-restored brightness state was not removed' >&2
  exit 1
fi

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 1' \
  >"$fake_m1ddc"
chmod +x "$fake_m1ddc"
printf '%s\n' 'uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE 50' \
  >"$temporary_dir/cache/pseudo-screensaver.brightness-state"
failed_restore_output="$(
  POWER_MODE_M1DDC="$fake_m1ddc" \
    POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
    "$controller" stop 2>&1
)"
assert_contains \
  "$failed_restore_output" \
  'Warning: Failed to restore external display brightness; continuing.' \
  'a total external-display restore failure does not block mode switching'
if [ ! -e "$temporary_dir/cache/pseudo-screensaver.brightness-state" ]; then
  echo 'Assertion failed: unrestored brightness state was removed' >&2
  exit 1
fi
rm -f "$temporary_dir/cache/pseudo-screensaver.brightness-state"

# shellcheck disable=SC2016
# The generated script expands these variables at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$*" >>"$POWER_MODE_M1DDC_TRACE"' \
  'case "$*" in' \
  '  "display uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE set luminance 50") exit 0 ;;' \
  '  "display uuid=11111111-2222-3333-4444-555555555555 set luminance 50") exit 1 ;;' \
  '  "set luminance 50") exit 0 ;;' \
  'esac' \
  'exit 1' \
  >"$fake_m1ddc"
chmod +x "$fake_m1ddc"
: >"$m1ddc_trace"
printf '%s\n' \
  'uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE 50' \
  'uuid=11111111-2222-3333-4444-555555555555 50' \
  >"$temporary_dir/cache/pseudo-screensaver.brightness-state"
POWER_MODE_M1DDC="$fake_m1ddc" \
  POWER_MODE_M1DDC_TRACE="$m1ddc_trace" \
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
  "$controller" stop >/dev/null 2>&1
assert_not_contains \
  "$(<"$m1ddc_trace")" \
  $'\nset luminance 50' \
  'multiple-display restore does not treat the default display as every failed display'
if [ "$(<"$temporary_dir/cache/pseudo-screensaver.brightness-state")" != \
  'uuid=11111111-2222-3333-4444-555555555555 50' ]; then
  echo 'Assertion failed: multiple-display restore did not retain only failed entries' >&2
  exit 1
fi
rm -f "$temporary_dir/cache/pseudo-screensaver.brightness-state"

printf '%s\n' 'invalid-state' \
  >"$temporary_dir/cache/pseudo-screensaver.brightness-state"
invalid_restore_output="$(
  POWER_MODE_M1DDC="$fake_m1ddc" \
    POWER_MODE_M1DDC_TRACE="$m1ddc_trace" \
    POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
    "$controller" stop 2>&1
)"
assert_contains \
  "$invalid_restore_output" \
  'Warning: Invalid brightness restore state:' \
  'invalid brightness state does not block mode switching'
if [ "$(<"$temporary_dir/cache/pseudo-screensaver.brightness-state")" != \
  'invalid-state' ]; then
  echo 'Assertion failed: invalid brightness state was changed' >&2
  exit 1
fi
rm -f "$temporary_dir/cache/pseudo-screensaver.brightness-state"

controller_trace="$(
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
    bash -x "$controller" start 3600 2>&1
)"
assert_contains \
  "$controller_trace" \
  '/usr/bin/caffeinate -dims' \
  'the pseudo screen saver keeps the Mac awake with caffeinate'
if [ "$(sed -n '1p' "$temporary_dir/cache/pseudo-screensaver.runner")" != "caffeinate" ]; then
  echo 'Assertion failed: the controller did not record the caffeinate runner' >&2
  exit 1
fi
pseudo_screensaver_pid="$(sed -n '1p' "$temporary_dir/cache/pseudo-screensaver.pid")"
POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
  "$controller" stop >/dev/null
if kill -0 "$pseudo_screensaver_pid" 2>/dev/null; then
  echo 'Assertion failed: stop left the pseudo screen saver running' >&2
  exit 1
fi

status_bin="$temporary_dir/status-bin"
mkdir -p "$status_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 0' \
  >"$status_bin/pmset"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo 900' \
  >"$status_bin/defaults"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "if [ \"\$1\" = \"status\" ]; then" \
  '  echo stopped' \
  'fi' \
  >"$status_bin/pseudo-screensaver"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo screenLock is off' \
  >"$status_bin/sysadminctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo SleepDisabled = No' \
  >"$status_bin/ioreg"
chmod +x "$status_bin"/*

status_output="$(
  PATH="$status_bin:$PATH" \
    POWER_MODE_STATE_DIR="$temporary_dir/status-state" \
    PSEUDO_SCREENSAVER_CONTROLLER="$status_bin/pseudo-screensaver" \
    "$power_mode"
)"
assert_contains \
  "$status_output" \
  'Power mode: unknown' \
  'status prints only the detected mode by default'
assert_not_contains \
  "$status_output" \
  'pmset:' \
  'status omits pmset details by default'

status_detail_output="$(
  PATH="$status_bin:$PATH" \
    POWER_MODE_STATE_DIR="$temporary_dir/status-state" \
    PSEUDO_SCREENSAVER_CONTROLLER="$status_bin/pseudo-screensaver" \
    "$power_mode" status --detail
)"
assert_contains \
  "$status_detail_output" \
  'pmset:' \
  'status --detail prints pmset details'
assert_contains \
  "$status_detail_output" \
  'screensaver:' \
  'status --detail prints screen saver details'

if PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" normal --detail --dry-run \
  >"$temporary_dir/invalid-detail-mode.out" 2>&1; then
  echo 'Assertion failed: normal accepted the status-only detail flag' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/invalid-detail-mode.out")" \
  '--detail は status でのみ指定できます。' \
  'the detail flag is rejected outside status mode'

nolock_output="$(
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" nolock --dry-run
)"
assert_contains \
  "$nolock_output" \
  'defaults -currentHost write com.apple.screensaver idleTime -int 0' \
  'nolock disables the macOS screen saver'
assert_contains \
  "$nolock_output" \
  '/bin/echo start 300' \
  'nolock starts the pseudo screen saver after five idle minutes'
assert_not_contains \
  "$nolock_output" \
  'Current status' \
  'nolock dry-run does not print status automatically'
if [[ "$nolock_output" == *'sudo '* ]] ||
  [[ "$nolock_output" == *'askForPassword'* ]] ||
  [[ "$nolock_output" == *'sysadminctl'* ]]; then
  printf 'Assertion failed: nolock still changes privileged or password settings\n%s\n' \
    "$nolock_output" >&2
  exit 1
fi

nolock_override_output="$(
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" nolock --pseudo-screensaver-seconds 42 --dry-run
)"
assert_contains \
  "$nolock_override_output" \
  '/bin/echo start 42' \
  'nolock accepts a pseudo screen saver delay in seconds'

if PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" normal --pseudo-screensaver-seconds 42 --dry-run \
  >"$temporary_dir/invalid-mode.out" 2>&1; then
  echo 'Assertion failed: normal accepted the nolock-only delay flag' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/invalid-mode.out")" \
  '--pseudo-screensaver-seconds は nolock でのみ指定できます。' \
  'the delay flag is rejected outside nolock mode'

if PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" nolock --pseudo-screensaver-seconds= --dry-run \
  >"$temporary_dir/invalid-seconds.out" 2>&1; then
  echo 'Assertion failed: nolock accepted an empty delay' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/invalid-seconds.out")" \
  '--pseudo-screensaver-seconds は 0 以上の整数で指定してください' \
  'an empty delay is rejected'

normal_output="$(
  POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" normal --dry-run
)"
assert_contains \
  "$normal_output" \
  '/bin/echo stop' \
  'normal stops the pseudo screen saver'
assert_not_contains \
  "$normal_output" \
  'Current status' \
  'normal dry-run does not print status automatically'
if [[ "$normal_output" == *'sudo '* ]] ||
  [[ "$normal_output" == *'askForPassword'* ]] ||
  [[ "$normal_output" == *'sysadminctl'* ]]; then
  printf 'Assertion failed: normal still changes privileged or password settings\n%s\n' \
    "$normal_output" >&2
  exit 1
fi

mkdir -p "$temporary_dir/operation-lock/bin"
operation_lock_trace="$temporary_dir/operation-lock.trace"
# shellcheck disable=SC2016
# The generated script expands this variable at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''start\n'\'' >>"$POWER_MODE_OPERATION_LOCK_TRACE"' \
  '/bin/sleep 1' \
  'printf '\''end\n'\'' >>"$POWER_MODE_OPERATION_LOCK_TRACE"' \
  >"$temporary_dir/operation-lock/bin/defaults"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 0' \
  >"$temporary_dir/operation-lock/bin/killall"
chmod +x \
  "$temporary_dir/operation-lock/bin/defaults" \
  "$temporary_dir/operation-lock/bin/killall"
PATH="$temporary_dir/operation-lock/bin:$PATH" \
  POWER_MODE_OPERATION_LOCK_TRACE="$operation_lock_trace" \
  POWER_MODE_STATE_DIR="$temporary_dir/operation-lock/state" \
  PSEUDO_SCREENSAVER_CONTROLLER=/usr/bin/true \
  "$power_mode" normal >/dev/null &
first_operation_pid=$!
while [ ! -s "$operation_lock_trace" ]; do
  sleep 0.05
done
PATH="$temporary_dir/operation-lock/bin:$PATH" \
  POWER_MODE_OPERATION_LOCK_TRACE="$operation_lock_trace" \
  POWER_MODE_STATE_DIR="$temporary_dir/operation-lock/state" \
  PSEUDO_SCREENSAVER_CONTROLLER=/usr/bin/true \
  "$power_mode" normal >/dev/null &
second_operation_pid=$!
wait "$first_operation_pid"
wait "$second_operation_pid"
if [ "$(<"$operation_lock_trace")" != $'start\nend\nstart\nend' ]; then
  printf 'Assertion failed: mode-changing operations were not serialized\n%s\n' \
    "$(<"$operation_lock_trace")" >&2
  exit 1
fi

fd_inheritance_cache="$temporary_dir/fd-inheritance-cache"
fd_inheritance_lock="$temporary_dir/fd-inheritance.lock"
mkdir -p "$fd_inheritance_cache"
# shellcheck disable=SC2016
# The generated script expands these variables at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '' \
  'stop_file=""' \
  'while [ $# -gt 0 ]; do' \
  '  case "$1" in' \
  '  --stop-file)' \
  '    stop_file="$2"' \
  '    shift 2' \
  '    ;;' \
  '  *) shift ;;' \
  '  esac' \
  'done' \
  '' \
  'while [ ! -e "$stop_file" ]; do' \
  '  sleep 0.05' \
  'done' \
  >"$fd_inheritance_cache/pseudo-screensaver"
chmod +x "$fd_inheritance_cache/pseudo-screensaver"
touch -t 209912312359 "$fd_inheritance_cache/pseudo-screensaver"
(
  exec 9>>"$fd_inheritance_lock"
  /usr/bin/lockf 9
  POWER_MODE_PSEUDO_CACHE_DIR="$fd_inheritance_cache" \
    "$controller" start 300 >/dev/null
)
if ! /usr/bin/lockf -t 0 "$fd_inheritance_lock" /usr/bin/true; then
  echo 'Assertion failed: pseudo screen saver inherited the operation lock' >&2
  exit 1
fi
POWER_MODE_PSEUDO_CACHE_DIR="$fd_inheritance_cache" \
  "$controller" stop >/dev/null

if POWER_MODE_STATE_DIR="$temporary_dir/state" \
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" nosleep --dry-run \
  >"$temporary_dir/nosleep-without-duration.out" 2>&1; then
  echo 'Assertion failed: nosleep accepted a missing duration' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/nosleep-without-duration.out")" \
  'nosleep には継続時間（分）が必要です。' \
  'nosleep requires an explicit timeout'

nosleep_output="$(
  POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" nosleep 120 --dry-run
)"
assert_contains \
  "$nosleep_output" \
  '/bin/echo start 300' \
  'nosleep includes the nolock pseudo screen saver behavior'
assert_contains \
  "$nosleep_output" \
  'sudo pmset -a powermode 1' \
  'nosleep enables low power mode'
assert_contains \
  "$nosleep_output" \
  'sudo pmset -a disablesleep 1' \
  'nosleep disables all system sleep'
assert_contains \
  "$nosleep_output" \
  'sudo -b' \
  'nosleep starts its privileged timeout helper'
assert_contains \
  "$nosleep_output" \
  'nosleep_timeout.sh 7200' \
  'nosleep converts the requested minutes for its timeout helper'
assert_contains \
  "$nosleep_output" \
  "$repo_root/power-mode" \
  'nosleep timeout returns through the standalone power-mode entrypoint'

mkdir -p "$temporary_dir/state"
printf '%s\n%s\n' 'test-token' '9999999999' >"$temporary_dir/state/nosleep.state"
mkdir -p "$temporary_dir/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo '\''  "SleepDisabled" = Yes'\''' \
  >"$temporary_dir/bin/ioreg"
chmod +x "$temporary_dir/bin/ioreg"
normal_from_nosleep_output="$(
  PATH="$temporary_dir/bin:$PATH" \
    POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" normal --dry-run
)"
assert_contains \
  "$normal_from_nosleep_output" \
  'sudo pmset -a disablesleep 0 powermode 0' \
  'leaving nosleep restores system sleep and automatic power mode with privileges'

nolock_from_nosleep_output="$(
  PATH="$temporary_dir/bin:$PATH" \
    POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" nolock --dry-run
)"
assert_contains \
  "$nolock_from_nosleep_output" \
  'sudo pmset -a disablesleep 0 powermode 0' \
  'switching from nosleep to nolock restores system sleep and automatic power mode with privileges'

assert_contains \
  "$(<"$nosleep_timeout_helper")" \
  '/usr/bin/pmset -a disablesleep 0 powermode 0' \
  'the nosleep timeout restores system sleep and automatic power mode'
assert_contains \
  "$(<"$nosleep_timeout_helper")" \
  '/usr/bin/lockf 9' \
  'the nosleep timeout serializes expiry with user mode changes'
assert_contains \
  "$(<"$nosleep_timeout_helper")" \
  'POWER_MODE_OPERATION_LOCK_HELD=1' \
  'the timeout normal transition reuses the lock held by its parent'

rm -f "$temporary_dir/state/nosleep.state"
nolock_after_nosleep_output="$(
  POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" nolock --dry-run
)"
assert_not_contains \
  "$nolock_after_nosleep_output" \
  'sudo ' \
  'normal and nolock remain password-free outside nosleep'

setup_output="$(
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" setup --dry-run
)"
assert_contains \
  "$setup_output" \
  'sudo pmset -a sleep 30 displaysleep 20 disksleep 10' \
  'setup applies the normal power settings once'
assert_contains \
  "$setup_output" \
  '/bin/echo stop' \
  'setup leaves the machine in normal mode'
if [[ "$setup_output" == *'askForPassword'* ]] ||
  [[ "$setup_output" == *'sysadminctl'* ]]; then
  printf 'Assertion failed: setup still changes password settings\n%s\n' \
    "$setup_output" >&2
  exit 1
fi

# Exercise startup without changing host power settings. The sudo stub checks
# the descriptor before sudo itself could close it.
mock_bin="$temporary_dir/nosleep-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/sudo" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
-n) exit 0 ;;
-b)
  if ( : >&9 ) 2>/dev/null; then
    echo 'timer inherited FD 9' >&2
    exit 1
  fi
  touch "$TEST_TIMER_STARTED"
  ;;
*) exit 0 ;;
esac
STUB
for command in defaults killall; do
  printf '#!/bin/sh\nexit 0\n' >"$mock_bin/$command"
done
chmod +x "$mock_bin"/*
PATH="$mock_bin:$PATH" TEST_TIMER_STARTED="$temporary_dir/timer-started" \
  POWER_MODE_STATE_DIR="$temporary_dir/start-state" \
  PSEUDO_SCREENSAVER_CONTROLLER=/usr/bin/true \
  "$power_mode" nosleep 1 >/dev/null
test -f "$temporary_dir/timer-started"
/usr/bin/lockf -k -t 0 "$temporary_dir/start-state/operation.lock" /usr/bin/true

# Replace only privileged executable paths in a test copy of the real helper.
# Keep its locking, token validation and control flow intact.
cat >"$mock_bin/launchctl" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'normal\n' >>"$TEST_TRACE"
test -f "$TEST_STATE"
printf '%s\n' "$*" >"$TEST_ARGS"
if [ "${TEST_NORMAL_EXIT:-0}" -ne 0 ]; then
  exit "$TEST_NORMAL_EXIT"
fi
shift 6
exec "$@"
STUB
cat >"$mock_bin/pmset" <<'STUB'
#!/usr/bin/env bash
printf 'enable-sleep\n' >>"$TEST_TRACE"
exit "${TEST_PMSET_EXIT:-0}"
STUB
chmod +x "$mock_bin"/*
sed -e "s|/bin/launchctl|$mock_bin/launchctl|g" \
  -e "s|/usr/bin/pmset|$mock_bin/pmset|g" \
  "$nosleep_timeout_helper" >"$temporary_dir/timeout-test.sh"
export TEST_TRACE="$temporary_dir/timeout.trace"
export TEST_ARGS="$temporary_dir/timeout.args"
export TEST_STATE="$temporary_dir/start-state/nosleep.state"
for scenario in success stale normal-failure pmset-failure; do
  printf 'token\n9999999999\n' >"$TEST_STATE"
  : >"$TEST_TRACE"
  timer_token=token
  normal_exit=0
  pmset_exit=0
  case "$scenario" in
  stale) timer_token=old-token ;;
  normal-failure) normal_exit=1 ;;
  pmset-failure) pmset_exit=1 ;;
  esac
  result=0
  PATH="$mock_bin:$PATH" PSEUDO_SCREENSAVER_CONTROLLER=/usr/bin/true \
    TEST_NORMAL_EXIT="$normal_exit" TEST_PMSET_EXIT="$pmset_exit" \
    bash "$temporary_dir/timeout-test.sh" 0 "$timer_token" "$TEST_STATE" \
    "$(id -u)" "$(id -un)" "$HOME" "$power_mode" || result=$?
  case "$scenario" in
  success)
    test "$result" -eq 0
    test "$(cat "$TEST_TRACE")" = $'normal\nenable-sleep'
    test ! -f "$TEST_STATE"
    assert_contains "$(cat "$TEST_ARGS")" 'sudo -n -u' 'timer requires no interactive sudo'
    assert_contains "$(cat "$TEST_ARGS")" 'POWER_MODE_NOSLEEP_RESTORE_DEFERRED=1' 'normal cleanup defers sleep restoration'
    ;;
  stale)
    test "$result" -eq 0
    test ! -s "$TEST_TRACE"
    test -f "$TEST_STATE"
    ;;
  normal-failure)
    test "$result" -ne 0
    test "$(cat "$TEST_TRACE")" = $'normal\nenable-sleep'
    test -f "$TEST_STATE"
    ;;
  pmset-failure)
    test "$result" -ne 0
    test -f "$TEST_STATE"
    ;;
  esac
done

# Check manual completion messages and rollback using the actual entrypoint.
cat >"$mock_bin/sudo" <<'STUB'
#!/usr/bin/env bash
case "$1" in
-n) shift; exec "$@" ;;
-b) exit 1 ;;
*) exec "$@" ;;
esac
STUB
cat >"$mock_bin/pmset" <<'STUB'
#!/usr/bin/env bash
printf 'pmset %s\n' "$*" >>"$TEST_TRACE"
if [ "$*" = '-a disablesleep 0 powermode 0' ]; then
  exit "${TEST_PMSET_EXIT:-0}"
fi
STUB
cat >"$mock_bin/controller" <<'STUB'
#!/usr/bin/env bash
printf 'controller %s\n' "$*" >>"$TEST_TRACE"
exit "${TEST_CONTROLLER_EXIT:-0}"
STUB
chmod +x "$mock_bin"/*
for manual_mode in normal nolock setup; do
  printf 'token\n9999999999\n' >"$TEST_STATE"
  : >"$TEST_TRACE"
  result=0
  output="$(PATH="$mock_bin:$PATH" POWER_MODE_STATE_DIR="${TEST_STATE%/*}" \
    PSEUDO_SCREENSAVER_CONTROLLER="$mock_bin/controller" TEST_PMSET_EXIT=1 \
    "$power_mode" "$manual_mode" 2>&1)" || result=$?
  test "$result" -ne 0
  test -f "$TEST_STATE"
  assert_not_contains "$output" 'Power mode:' 'failed manual restore does not report success'
done
for controller_exit in 0 1; do
  : >"$TEST_TRACE"
  result=0
  PATH="$mock_bin:$PATH" POWER_MODE_STATE_DIR="${TEST_STATE%/*}" \
    PSEUDO_SCREENSAVER_CONTROLLER="$mock_bin/controller" \
    TEST_CONTROLLER_EXIT=0 TEST_PMSET_EXIT=0 \
    "$power_mode" normal >/dev/null
  : >"$TEST_TRACE"
  # Fail only stop so startup reaches the timer creation failure.
  cat >"$mock_bin/controller" <<'STUB'
#!/usr/bin/env bash
printf 'controller %s\n' "$*" >>"$TEST_TRACE"
if [ "$1" = stop ]; then
  exit "${TEST_CONTROLLER_EXIT:-0}"
fi
STUB
  PATH="$mock_bin:$PATH" POWER_MODE_STATE_DIR="${TEST_STATE%/*}" \
    PSEUDO_SCREENSAVER_CONTROLLER="$mock_bin/controller" \
    TEST_CONTROLLER_EXIT="$controller_exit" TEST_PMSET_EXIT=0 \
    "$power_mode" nosleep 1 >"$temporary_dir/start-failure.out" 2>&1 || result=$?
  test "$result" -ne 0
  test "$(tail -2 "$TEST_TRACE")" = $'controller stop\npmset -a disablesleep 0 powermode 0'
  if [ "$controller_exit" -eq 0 ]; then
    test ! -f "$TEST_STATE"
  else
    test -f "$TEST_STATE"
  fi
done

echo 'power_mode tests passed.'
