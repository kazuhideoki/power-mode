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
# Mode transitions must never unload the real user-session job.
export POWER_MODE_LAUNCHCTL=/usr/bin/false
cleanup() {
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/cache" \
    "$controller" stop >/dev/null 2>&1 || true
  POWER_MODE_PSEUDO_CACHE_DIR="$temporary_dir/fd-inheritance-cache" \
    "$controller" stop >/dev/null 2>&1 || true
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

if [ ! -x "$nosleep_timeout_helper" ]; then
  echo 'Assertion failed: the awake-lid-closed timeout helper is not executable' >&2
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

cat >"$status_bin/pmset" <<'STUB'
#!/usr/bin/env bash
case "$2" in
batt) echo "Now drawing from 'AC Power'" ;;
custom) printf 'AC Power:\n sleep 30\n displaysleep 20\n disksleep 10\n' ;;
esac
STUB
cat >"$status_bin/defaults" <<'STUB'
#!/usr/bin/env bash
echo "${TEST_SCREEN_SAVER_DELAY:-900}"
STUB
cat >"$status_bin/pseudo-screensaver" <<'STUB'
#!/usr/bin/env bash
echo "${TEST_SCREEN_SAVER_STATUS:-stopped}"
STUB
test "$(PATH="$status_bin:$PATH" PSEUDO_SCREENSAVER_CONTROLLER="$status_bin/pseudo-screensaver" \
  "$power_mode" status)" = 'Power mode: auto'
test "$(PATH="$status_bin:$PATH" PSEUDO_SCREENSAVER_CONTROLLER="$status_bin/pseudo-screensaver" \
  TEST_SCREEN_SAVER_DELAY=0 TEST_SCREEN_SAVER_STATUS=running "$power_mode" status)" = 'Power mode: awake-remote'

if PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" auto --detail --dry-run \
  >"$temporary_dir/invalid-detail-mode.out" 2>&1; then
  echo 'Assertion failed: auto accepted the status-only detail flag' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/invalid-detail-mode.out")" \
  '--detail は status でのみ指定できます。' \
  'the detail flag is rejected outside status mode'

nolock_output="$(
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" awake-remote --dry-run
)"
assert_contains \
  "$nolock_output" \
  'defaults -currentHost write com.apple.screensaver idleTime -int 0' \
  'awake-remote disables the macOS screen saver'
assert_contains \
  "$nolock_output" \
  '/bin/echo start 300' \
  'awake-remote starts the pseudo screen saver after five idle minutes'
assert_not_contains \
  "$nolock_output" \
  'Current status' \
  'awake-remote dry-run does not print status automatically'
if [[ "$nolock_output" == *'sudo '* ]] ||
  [[ "$nolock_output" == *'askForPassword'* ]] ||
  [[ "$nolock_output" == *'sysadminctl'* ]]; then
  printf 'Assertion failed: awake-remote still changes privileged or password settings\n%s\n' \
    "$nolock_output" >&2
  exit 1
fi

nolock_override_output="$(
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" awake-remote --pseudo-screensaver-seconds 42 --dry-run
)"
assert_contains \
  "$nolock_override_output" \
  '/bin/echo start 42' \
  'awake-remote accepts a pseudo screen saver delay in seconds'

if PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" auto --pseudo-screensaver-seconds 42 --dry-run \
  >"$temporary_dir/invalid-mode.out" 2>&1; then
  echo 'Assertion failed: auto accepted the awake-remote-only delay flag' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/invalid-mode.out")" \
  '--pseudo-screensaver-seconds は awake-remote でのみ指定できます。' \
  'the delay flag is rejected outside awake-remote mode'

if PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
  "$power_mode" awake-remote --pseudo-screensaver-seconds= --dry-run \
  >"$temporary_dir/invalid-seconds.out" 2>&1; then
  echo 'Assertion failed: awake-remote accepted an empty delay' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/invalid-seconds.out")" \
  '--pseudo-screensaver-seconds は 0 以上の整数で指定してください' \
  'an empty delay is rejected'

normal_output="$(
  POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" auto --dry-run
)"
assert_contains \
  "$normal_output" \
  '/bin/echo stop' \
  'auto stops the pseudo screen saver'
assert_not_contains \
  "$normal_output" \
  'Current status' \
  'auto dry-run does not print status automatically'
if [[ "$normal_output" == *'sudo '* ]] ||
  [[ "$normal_output" == *'askForPassword'* ]] ||
  [[ "$normal_output" == *'sysadminctl'* ]]; then
  printf 'Assertion failed: auto still changes privileged or password settings\n%s\n' \
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
  "$power_mode" auto >/dev/null &
first_operation_pid=$!
while [ ! -s "$operation_lock_trace" ]; do
  sleep 0.05
done
PATH="$temporary_dir/operation-lock/bin:$PATH" \
  POWER_MODE_OPERATION_LOCK_TRACE="$operation_lock_trace" \
  POWER_MODE_STATE_DIR="$temporary_dir/operation-lock/state" \
  PSEUDO_SCREENSAVER_CONTROLLER=/usr/bin/true \
  "$power_mode" auto >/dev/null &
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
  "$power_mode" awake-lid-closed --dry-run \
  >"$temporary_dir/nosleep-without-duration.out" 2>&1; then
  echo 'Assertion failed: awake-lid-closed accepted a missing duration' >&2
  exit 1
fi
assert_contains \
  "$(<"$temporary_dir/nosleep-without-duration.out")" \
  'awake-lid-closed には継続時間（分）が必要です。' \
  'awake-lid-closed requires an explicit timeout'

nosleep_output="$(
  POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" awake-lid-closed 120 --dry-run
)"
assert_contains \
  "$nosleep_output" \
  '/bin/echo start 300' \
  'awake-lid-closed includes the awake-remote pseudo screen saver behavior'
assert_contains \
  "$nosleep_output" \
  'sudo pmset -a powermode 1' \
  'awake-lid-closed enables low power mode'
assert_contains \
  "$nosleep_output" \
  'sudo pmset -a disablesleep 1' \
  'awake-lid-closed disables all system sleep'
assert_contains \
  "$nosleep_output" \
  'sudo -b' \
  'awake-lid-closed starts its privileged timeout helper'
assert_contains \
  "$nosleep_output" \
  'nosleep_timeout.sh 7200' \
  'awake-lid-closed converts the requested minutes for its timeout helper'
assert_contains \
  "$nosleep_output" \
  "$repo_root/power-mode" \
  'awake-lid-closed timeout returns through the standalone power-mode entrypoint'

mkdir -p "$temporary_dir/state"
printf '%s\n%s\n' 'test-token' '9999999999' >"$temporary_dir/state/nosleep.state"
mkdir -p "$temporary_dir/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo '\''  "SleepDisabled" = Yes'\''' \
  >"$temporary_dir/bin/ioreg"
chmod +x "$temporary_dir/bin/ioreg"
lid_closed_status="$(PATH="$temporary_dir/bin:$status_bin:$PATH" \
  PSEUDO_SCREENSAVER_CONTROLLER="$status_bin/pseudo-screensaver" "$power_mode" status --detail)"
assert_contains "$lid_closed_status" 'Power mode: awake-lid-closed' 'status recognizes the existing timed state'
assert_contains "$lid_closed_status" 'awakeLidClosedUntil(epoch):' 'status --detail names the deadline after the mode'

normal_from_nosleep_output="$(
  PATH="$temporary_dir/bin:$PATH" \
    POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" auto --dry-run
)"
assert_contains \
  "$normal_from_nosleep_output" \
  'sudo pmset -a disablesleep 0 powermode 0' \
  'leaving awake-lid-closed restores system sleep and automatic power mode with privileges'

nolock_from_nosleep_output="$(
  PATH="$temporary_dir/bin:$PATH" \
    POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" awake-remote --dry-run
)"
assert_contains \
  "$nolock_from_nosleep_output" \
  'sudo pmset -a disablesleep 0 powermode 0' \
  'switching from awake-lid-closed to awake-remote restores system sleep and automatic power mode with privileges'

assert_contains \
  "$(<"$nosleep_timeout_helper")" \
  '/usr/bin/pmset -a disablesleep 0 powermode 0' \
  'the awake-lid-closed timeout restores system sleep and automatic power mode'
assert_contains \
  "$(<"$nosleep_timeout_helper")" \
  '/usr/bin/lockf 9' \
  'the awake-lid-closed timeout serializes expiry with user mode changes'
assert_contains \
  "$(<"$nosleep_timeout_helper")" \
  'POWER_MODE_OPERATION_LOCK_HELD=1' \
  'the timeout auto transition reuses the lock held by its parent'

rm -f "$temporary_dir/state/nosleep.state"
nolock_after_nosleep_output="$(
  POWER_MODE_STATE_DIR="$temporary_dir/state" \
    PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" awake-remote --dry-run
)"
assert_not_contains \
  "$nolock_after_nosleep_output" \
  'sudo ' \
  'auto and awake-remote remain password-free outside awake-lid-closed'

setup_output="$(
  PSEUDO_SCREENSAVER_CONTROLLER=/bin/echo \
    "$power_mode" setup --dry-run
)"
assert_contains \
  "$setup_output" \
  'sudo pmset -a sleep 30 displaysleep 20 disksleep 10' \
  'setup applies the standard power settings once'
assert_contains \
  "$setup_output" \
  '/bin/echo stop' \
  'setup leaves the machine in auto mode'
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
  "$power_mode" awake-lid-closed 1 >/dev/null
test -f "$temporary_dir/timer-started"
/usr/bin/lockf -k -t 0 "$temporary_dir/start-state/operation.lock" /usr/bin/true

# Replace only privileged executable paths in a test copy of the real helper.
# Keep its locking, token validation and control flow intact.
cat >"$mock_bin/launchctl" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'auto\n' >>"$TEST_TRACE"
test -f "$TEST_STATE"
printf '%s\n' "$*" >"$TEST_ARGS"
if [ "${TEST_AUTO_EXIT:-0}" -ne 0 ]; then
  exit "$TEST_AUTO_EXIT"
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
for scenario in success stale auto-failure pmset-failure; do
  printf 'token\n9999999999\n' >"$TEST_STATE"
  : >"$TEST_TRACE"
  timer_token=token
  auto_exit=0
  pmset_exit=0
  case "$scenario" in
  stale) timer_token=old-token ;;
  auto-failure) auto_exit=1 ;;
  pmset-failure) pmset_exit=1 ;;
  esac
  result=0
  PATH="$mock_bin:$PATH" PSEUDO_SCREENSAVER_CONTROLLER=/usr/bin/true \
    TEST_AUTO_EXIT="$auto_exit" TEST_PMSET_EXIT="$pmset_exit" \
    bash "$temporary_dir/timeout-test.sh" 0 "$timer_token" "$TEST_STATE" \
    "$(id -u)" "$(id -un)" "$HOME" "$power_mode" || result=$?
  case "$scenario" in
  success)
    test "$result" -eq 0
    test "$(cat "$TEST_TRACE")" = $'auto\nenable-sleep'
    test ! -f "$TEST_STATE"
    assert_contains "$(cat "$TEST_ARGS")" 'sudo -n -u' 'timer requires no interactive sudo'
    assert_contains "$(cat "$TEST_ARGS")" "$power_mode auto" 'timer calls the canonical auto mode'
    assert_contains "$(cat "$TEST_ARGS")" 'POWER_MODE_NOSLEEP_RESTORE_DEFERRED=1' 'auto cleanup defers sleep restoration'
    ;;
  stale)
    test "$result" -eq 0
    test ! -s "$TEST_TRACE"
    test -f "$TEST_STATE"
    ;;
  auto-failure)
    test "$result" -ne 0
    test "$(cat "$TEST_TRACE")" = $'auto\nenable-sleep'
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
-b) exit "${TEST_TIMER_EXIT:-1}" ;;
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
for manual_mode in auto awake-remote awake setup; do
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
    "$power_mode" auto >/dev/null
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
    "$power_mode" awake-lid-closed 1 >"$temporary_dir/start-failure.out" 2>&1 || result=$?
  test "$result" -ne 0
  test "$(tail -2 "$TEST_TRACE")" = $'controller stop\npmset -a disablesleep 0 powermode 0'
  if [ "$controller_exit" -eq 0 ]; then
    test ! -f "$TEST_STATE"
  else
    test -f "$TEST_STATE"
  fi
done

cat >"$mock_bin/lockawake-launchctl" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
print) test -f "$TEST_LOCKAWAKE_JOB" ;;
bootstrap)
  test -f "$3"
  printf 'bootstrap\n' >>"$TEST_TRACE"
  touch "$TEST_LOCKAWAKE_JOB"
  ;;
bootout)
  printf 'bootout\n' >>"$TEST_TRACE"
  rm "$TEST_LOCKAWAKE_JOB"
  ;;
*) exit 1 ;;
esac
STUB
chmod +x "$mock_bin/lockawake-launchctl"
export TEST_LOCKAWAKE_JOB="$temporary_dir/lockawake-job"

run_lockawake_test_mode() {
  PATH="$mock_bin:$PATH" POWER_MODE_STATE_DIR="$temporary_dir/lockawake-state" \
    POWER_MODE_LAUNCHCTL="$mock_bin/lockawake-launchctl" \
    PSEUDO_SCREENSAVER_CONTROLLER="$mock_bin/controller" \
    "$power_mode" "$@"
}

: >"$TEST_TRACE"
lockawake_preview="$(run_lockawake_test_mode awake --dry-run)"
assert_contains "$lockawake_preview" 'bootstrap gui/' 'awake previews the user-session job'
assert_contains "$lockawake_preview" 'idleTime -int 900' 'awake restores the standard screen saver delay'
assert_not_contains "$lockawake_preview" 'sudo ' 'awake from auto needs no sudo'
test ! -f "$TEST_LOCKAWAKE_JOB"
test ! -s "$TEST_TRACE"

for target_mode in auto awake-remote setup; do
  : >"$TEST_TRACE"
  assert_contains "$(run_lockawake_test_mode awake)" 'Power mode: awake' 'awake reports success'
  test "$(run_lockawake_test_mode status)" = 'Power mode: awake'
  run_lockawake_test_mode awake >/dev/null
  test "$(rg -c '^bootstrap$' "$TEST_TRACE")" -eq 1
  run_lockawake_test_mode "$target_mode" >/dev/null
  test "$(tail -1 "$TEST_TRACE")" = bootout
  test ! -f "$TEST_LOCKAWAKE_JOB"
done

run_lockawake_test_mode awake >/dev/null
TEST_TIMER_EXIT=0 run_lockawake_test_mode awake-lid-closed 1 >/dev/null
test ! -f "$TEST_LOCKAWAKE_JOB"
test -f "$temporary_dir/lockawake-state/nosleep.state"
: >"$TEST_TRACE"
run_lockawake_test_mode awake >/dev/null
test "$(tail -2 "$TEST_TRACE")" = $'pmset -a disablesleep 0 powermode 0\nbootstrap'
test ! -f "$temporary_dir/lockawake-state/nosleep.state"
run_lockawake_test_mode auto >/dev/null

assert_mode_alias() {
  local canonical="$1"
  local alias="$2"
  shift 2
  test "$(run_lockawake_test_mode "$canonical" "$@" --dry-run)" = \
    "$(run_lockawake_test_mode "$alias" "$@" --dry-run)"
}

assert_mode_alias auto normal
assert_mode_alias awake lockawake
assert_mode_alias awake-remote nolock --pseudo-screensaver-seconds 42
assert_mode_alias awake-lid-closed nosleep 120

echo 'power_mode tests passed.'
