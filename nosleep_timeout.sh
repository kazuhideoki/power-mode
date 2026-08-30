#!/usr/bin/env bash
set -euo pipefail

duration_seconds="${1:?duration_seconds is required}"
token="${2:?token is required}"
state_file="${3:?state_file is required}"
user_id="${4:?user_id is required}"
user_name="${5:?user_name is required}"
user_home="${6:?user_home is required}"
power_mode="${7:?power_mode is required}"

exec >/dev/null 2>&1
sleep "$duration_seconds"

if [ "$(sed -n '1p' "$state_file" 2>/dev/null || true)" != "$token" ]; then
  exit 0
fi

/usr/bin/pmset -a disablesleep 0 powermode 0
/bin/launchctl asuser "$user_id" \
  /usr/bin/sudo -u "$user_name" \
  /usr/bin/env \
  HOME="$user_home" \
  "$power_mode" normal
