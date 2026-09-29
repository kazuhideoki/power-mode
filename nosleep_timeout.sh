#!/usr/bin/env bash
set -euo pipefail

duration_seconds="${1:?duration_seconds is required}"
token="${2:?token is required}"
state_file="${3:?state_file is required}"
user_id="${4:?user_id is required}"
user_name="${5:?user_name is required}"
user_home="${6:?user_home is required}"
power_mode="${7:?power_mode is required}"
operation_lock_file="${state_file%/*}/operation.lock"

# Never retain a caller's operation lock while waiting.
exec 9>&-
exec >/dev/null 2>&1
sleep "$duration_seconds"

exec 9>>"$operation_lock_file"
/usr/bin/lockf 9

if [ "$(sed -n '1p' "$state_file" 2>/dev/null || true)" != "$token" ]; then
  exit 0
fi

normal_result=0
/bin/launchctl asuser "$user_id" \
  /usr/bin/sudo -n -u "$user_name" \
  /usr/bin/env \
  HOME="$user_home" \
  POWER_MODE_OPERATION_LOCK_HELD=1 \
  POWER_MODE_NOSLEEP_RESTORE_DEFERRED=1 \
  POWER_MODE_STATE_DIR="${state_file%/*}" \
  "$power_mode" normal || normal_result=$?

# Attempt user-session cleanup before allowing a closed-lid Mac to sleep.
# Even if cleanup fails, do not leave timed sleep inhibition enabled forever.
/usr/bin/pmset -a disablesleep 0 powermode 0
if [ "$normal_result" -eq 0 ]; then
  rm -f "$state_file"
fi
exit "$normal_result"
