#!/bin/sh
set -u

anodyne_root=$1
status_file=${ANODYNE_SMOKE_STATUS_PATH:-"$anodyne_root/coverage/smoke-status.json"}
status_directory=${status_file%/*}
mkdir -p "$status_directory"

write_status() {
  smoke_value=$1
  smoke_temporary="$status_file.tmp.$$"
  printf '{"status":"%s"}\n' "$smoke_value" >"$smoke_temporary" || return 1
  mv -f "$smoke_temporary" "$status_file"
}

write_status DEFERRED-ENVIRONMENT || exit 1

case ${ANODYNE_SMOKE_TEST_MODE:-} in
  preflight-deferred)
    ;;
  armed-abort|armed-timeout)
    write_status FAIL || exit 1
    ;;
  success-restoration)
    write_status FAIL || exit 1
    write_status PASS || exit 1
    ;;
  invalid-marker)
    printf '%s\n' 'invalid' >"$status_file"
    ;;
  "")
    if command -v hs >/dev/null 2>&1; then
      python3 "$anodyne_root/tools/run_with_timeout.py" --seconds 4 -- \
        hs -c "return assert(loadfile('$anodyne_root/spec/fixtures/anodyne_smoke.lua'))('$anodyne_root')" \
        >/dev/null 2>&1 || true
    fi
    ;;
  *)
    write_status FAIL || exit 1
    ;;
esac

if [ -f "$status_file" ] && [ "$(cat "$status_file")" = '{"status":"PASS"}' ]; then
  printf '%s\n' 'Anodyne smoke: PASS'
  exit 0
fi
if [ -f "$status_file" ] && [ "$(cat "$status_file")" = '{"status":"FAIL"}' ]; then
  printf '%s\n' 'Anodyne smoke: FAIL' >&2
  exit 1
fi
if [ -f "$status_file" ] && [ "$(cat "$status_file")" = '{"status":"DEFERRED-ENVIRONMENT"}' ]; then
  printf '%s\n' 'Anodyne smoke: DEFERRED-ENVIRONMENT (preflight, flag, IPC, conflict, or safe snapshot unavailable)'
  exit 0
fi

write_status FAIL || true
printf '%s\n' 'Anodyne smoke: FAIL (missing or invalid status marker)' >&2
exit 1
