#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/install_caddy_emby.sh"

TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf "FAIL: %s\n" "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" == "$expected" ]] || fail "$message (expected: $expected, actual: $actual)"
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" -eq "$expected" ]] || fail "$message (expected: $expected, actual: $actual)"
}

cat > "$FAKE_BIN/caddy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == validate ]]; then
    printf "%s\n" "${3:-}" >> "$FAKE_CADDY_LOG"
    if [[ "${FAKE_CADDY_VALIDATE_FAIL:-false}" == true && ( "${3:-}" == "$FAKE_CADDYFILE" || "${3:-}" == "${FAKE_CADDY_VALIDATE_FAIL_PATH:-}" ) ]]; then
        exit 1
    fi
    exit 0
fi
exit 0
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
state_file="$FAKE_SYSTEMD_STATE"
log_file="$FAKE_SYSTEMD_LOG"
command="${1:-}"

case "$command" in
    is-active)
        [[ -f "$state_file" && "$(<"$state_file")" == active ]]
        ;;
    is-failed)
        exit 1
        ;;
    reload)
        printf "reload\n" >> "$log_file"
        [[ "${FAKE_SYSTEMD_RELOAD_FAIL:-false}" != true ]]
        ;;
    restart)
        printf "restart\n" >> "$log_file"
        printf "active\n" > "$state_file"
        ;;
    start)
        printf "start\n" >> "$log_file"
        printf "active\n" > "$state_file"
        ;;
    stop)
        printf "stop\n" >> "$log_file"
        printf "inactive\n" > "$state_file"
        ;;
    status|show|enable)
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 755 "$FAKE_BIN/caddy" "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"

assert_status 0 "$(validate_domain "*.example.com"; echo $?)" "wildcard domain validation"
assert_status 1 "$(validate_domain "foo.*.example.com"; echo $?)" "embedded wildcard rejection"
assert_status 0 "$(validate_ipv6 "::1"; echo $?)" "IPv6 loopback validation"
assert_status 0 "$(validate_ipv6 "2001:db8::ffff:192.0.2.1"; echo $?)" "IPv4-mapped IPv6 validation"
assert_status 0 "$(validate_ipv6 "0:0:0:0:0:ffff:192.0.2.1"; echo $?)" "fully expanded IPv4-mapped IPv6 validation"
assert_status 1 "$(validate_ipv6 "1:2:3:4:5:6:7:8:"; echo $?)" "trailing IPv6 colon rejection"
assert_status 7 "$(parse_menu_index 08)" "decimal menu index parsing"
assert_status 1 "$(parse_menu_index 00 >/dev/null 2>&1; echo $?)" "zero menu index rejection"
assert_status 1 "$(parse_menu_index 999999999999999999999999 >/dev/null 2>&1; echo $?)" "oversized menu index rejection"

MARKER_FIXTURE="$TEST_ROOT/mismatched-markers.caddy"
printf "%s\n" "# BEGIN CADDY-EMBY-MANAGED a.example.com" "a.example.com {" "}" "# END CADDY-EMBY-MANAGED b.example.com" > "$MARKER_FIXTURE"
assert_status 1 "$(is_fully_managed_caddyfile "$MARKER_FIXTURE"; echo $?)" "mismatched managed markers"

DOMAIN_FIXTURE="$TEST_ROOT/domains.caddy"
printf "%s\n" "EXAMPLE.COM. {" "    reverse_proxy 127.0.0.1:8096" "}" "*.MEDIA.EXAMPLE.COM {" "    reverse_proxy [::1]:8096" "}" > "$DOMAIN_FIXTURE"
expected_domains=$'*.media.example.com\nexample.com'
assert_eq "$expected_domains" "$(list_configured_domains "$DOMAIN_FIXTURE")" "domain listing normalization"
assert_status 0 "$(site_block_exists_in_file "EXAMPLE.COM." "$DOMAIN_FIXTURE"; echo $?)" "legacy domain lookup"
assert_status 0 "$(site_block_exists_in_file "*.MEDIA.EXAMPLE.COM." "$DOMAIN_FIXTURE"; echo $?)" "wildcard domain lookup"
REMOVED_FIXTURE="$TEST_ROOT/domains.without.caddy"
remove_site_block_from_file "EXAMPLE.COM." "$DOMAIN_FIXTURE" "$REMOVED_FIXTURE"
! grep -qi "^example.com" "$REMOVED_FIXTURE" || fail "domain block was not removed"
grep -q "MEDIA.EXAMPLE.COM" "$REMOVED_FIXTURE" || fail "unrelated domain block was removed"

PORT_DOMAIN_FIXTURE="$TEST_ROOT/domains-with-ports.caddy"
printf "%s\n" "EXAMPLE.COM.:0443 {" "    reverse_proxy 127.0.0.1:8096" "}" "*.MEDIA.EXAMPLE.COM:443 {" "    reverse_proxy [::1]:8096" "}" > "$PORT_DOMAIN_FIXTURE"
assert_eq $'*.media.example.com:443\nexample.com:443' "$(list_configured_domains "$PORT_DOMAIN_FIXTURE")" "site address listing with ports"
assert_eq "example.com:443" "$(canonicalize_site_address "EXAMPLE.COM.:0443")" "site address canonicalization"
assert_status 0 "$(site_block_exists_in_file "*.MEDIA.EXAMPLE.COM:0443" "$PORT_DOMAIN_FIXTURE"; echo $?)" "site address lookup with ports"
assert_status 1 "$(canonicalize_site_address "example.com:0" >/dev/null 2>&1; echo $?)" "zero site port rejection"
assert_status 1 "$(canonicalize_site_address "example.com:65536" >/dev/null 2>&1; echo $?)" "oversized site port rejection"
PORT_DOMAIN_REMOVED="$TEST_ROOT/domains-with-ports.without.caddy"
remove_site_block_from_file "example.com:0443" "$PORT_DOMAIN_FIXTURE" "$PORT_DOMAIN_REMOVED"
! grep -qi "^example.com" "$PORT_DOMAIN_REMOVED" || fail "port-qualified domain block was not removed"
grep -q "\*\.MEDIA.EXAMPLE.COM:443" "$PORT_DOMAIN_REMOVED" || fail "unrelated port-qualified domain block was removed"

HTTPS_CONFIG="$TEST_ROOT/https-config.caddy"
validate_backend https://remote.example.com:443 || fail "HTTPS backend validation failed"
print_config_block https.example.com https://remote.example.com:443 > "$HTTPS_CONFIG"
grep -Fq "header_up Host {upstream_hostport}" "$HTTPS_CONFIG" || fail "HTTPS upstream Host header was not generated"
grep -Fq "header_down -Access-Control-Allow-Origin" "$HTTPS_CONFIG" || fail "wildcard upstream CORS header was not removed"

MULTI_DOMAIN_FIXTURE="$TEST_ROOT/multi-domain.caddy"
printf "%s\n" "example.com, www.example.com {" "    reverse_proxy 127.0.0.1:8096" "}" > "$MULTI_DOMAIN_FIXTURE"
assert_eq $'example.com\nwww.example.com' "$(list_configured_domains "$MULTI_DOMAIN_FIXTURE")" "multi-domain listing"
assert_status 0 "$(site_block_exists_in_file www.example.com "$MULTI_DOMAIN_FIXTURE"; echo $?)" "multi-domain lookup"
MULTI_DOMAIN_REMOVED="$TEST_ROOT/multi-domain.without.caddy"
remove_site_block_from_file www.example.com "$MULTI_DOMAIN_FIXTURE" "$MULTI_DOMAIN_REMOVED"
grep -q "^example.com[[:space:]]*{" "$MULTI_DOMAIN_REMOVED" || fail "remaining multi-domain address was not preserved"

INLINE_FIXTURE="$TEST_ROOT/inline.caddy"
printf "%s\n" "inline.example.com { respond 200 }" > "$INLINE_FIXTURE"
assert_eq "inline.example.com" "$(list_configured_domains "$INLINE_FIXTURE")" "inline site listing"
assert_status 0 "$(site_block_exists_in_file inline.example.com "$INLINE_FIXTURE"; echo $?)" "inline site lookup"
INLINE_REMOVED="$TEST_ROOT/inline.without.caddy"
remove_site_block_from_file inline.example.com "$INLINE_FIXTURE" "$INLINE_REMOVED"
[[ ! -s "$INLINE_REMOVED" ]] || fail "inline site was not removed"
! grep -q "www.example.com" "$MULTI_DOMAIN_REMOVED" || fail "target multi-domain address was not removed"

GOOD_CORS="$TEST_ROOT/good.caddy"
BAD_CORS="$TEST_ROOT/bad.caddy"
printf "%s\n" "header_down Access-Control-Allow-Origin https://app.example.com" > "$GOOD_CORS"
printf "%s\n" "header_down Access-Control-Allow-Origin *" > "$BAD_CORS"
assert_status 0 "$(reject_wildcard_cors "$GOOD_CORS" >/dev/null; echo $?)" "restricted CORS"
assert_status 1 "$(reject_wildcard_cors "$BAD_CORS" >/dev/null 2>&1; echo $?)" "wildcard CORS rejection"
printf "%s\n" "header_down Access-Control-Allow-Origin:*" > "$BAD_CORS"
assert_status 1 "$(reject_wildcard_cors "$BAD_CORS" >/dev/null 2>&1; echo $?)" "colon-attached wildcard CORS rejection"
printf "%s\n" "header_down Access-Control-Allow-Origin=*" > "$BAD_CORS"
assert_status 1 "$(reject_wildcard_cors "$BAD_CORS" >/dev/null 2>&1; echo $?)" "equals-attached wildcard CORS rejection"
printf "%s\n" "header_down Access-Control-Allow-Origin : *" > "$BAD_CORS"
assert_status 1 "$(reject_wildcard_cors "$BAD_CORS" >/dev/null 2>&1; echo $?)" "spaced-colon wildcard CORS rejection"

PORTS=$'LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:(caddy,pid=1,fd=3)\nLISTEN 0 128 [::]:443 [::]:* users:(caddy,pid=1,fd=4)\nLISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(other,pid=2,fd=3)'
assert_status 2 "$(printf "%s\n" "$PORTS" | filter_web_ports | wc -l)" "IPv4 and IPv6 port filtering"

CADDY_DIR="$TEST_ROOT/caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"
STATE_DIR="$TEST_ROOT/state"
LOG_FILE="$TEST_ROOT/manager.log"
FAKE_CADDYFILE="$CADDYFILE"
FAKE_CADDY_LOG="$TEST_ROOT/caddy.log"
FAKE_SYSTEMD_STATE="$TEST_ROOT/systemd.state"
FAKE_SYSTEMD_LOG="$TEST_ROOT/systemd.log"
export CADDY_DIR CADDYFILE STATE_DIR LOG_FILE FAKE_CADDYFILE FAKE_CADDY_LOG FAKE_SYSTEMD_STATE FAKE_SYSTEMD_LOG
mkdir -p "$CADDY_DIR"
printf "%s\n" "example.com {" "    reverse_proxy 127.0.0.1:8096" "}" > "$CADDYFILE"
printf "active\n" > "$FAKE_SYSTEMD_STATE"
: > "$FAKE_SYSTEMD_LOG"
CANDIDATE="$TEST_ROOT/candidate.caddy"
printf "%s\n" "example.com {" "    reverse_proxy 127.0.0.1:9999" "}" > "$CANDIDATE"
FAKE_CADDY_VALIDATE_FAIL=true
FAKE_CADDY_VALIDATE_FAIL_PATH="$CANDIDATE"
export FAKE_CADDY_VALIDATE_FAIL FAKE_CADDY_VALIDATE_FAIL_PATH
apply_candidate "$CANDIDATE" >/dev/null 2>&1
assert_status 1 "$?" "failed candidate validation must fail the transaction"
grep -q "reverse_proxy 127.0.0.1:8096" "$CADDYFILE" || fail "candidate validation failure changed Caddyfile"
if [[ -s "$FAKE_SYSTEMD_LOG" ]]; then
    fail "candidate validation failure touched systemd"
fi
FAKE_CADDY_VALIDATE_FAIL=false
export FAKE_CADDY_VALIDATE_FAIL FAKE_CADDY_VALIDATE_FAIL_PATH
printf "%s\n" "example.com {" "    reverse_proxy 127.0.0.1:9999" "}" > "$CANDIDATE"
FAKE_SYSTEMD_RELOAD_FAIL=true
export FAKE_SYSTEMD_RELOAD_FAIL
apply_candidate "$CANDIDATE" >/dev/null 2>&1
assert_status 1 "$?" "failed reload must fail the transaction"
grep -q "$CADDYFILE" "$FAKE_CADDY_LOG" || fail "caddy validate was not called"
grep -q "reverse_proxy 127.0.0.1:8096" "$CADDYFILE" || fail "old Caddyfile was not restored"
grep -q "^reload$" "$FAKE_SYSTEMD_LOG" || fail "reload was not attempted"
grep -q "^restart$" "$FAKE_SYSTEMD_LOG" || fail "restart fallback was not attempted"
assert_eq active "$(<"$FAKE_SYSTEMD_STATE")" "service state rollback"

: > "$FAKE_SYSTEMD_LOG"
FAKE_SYSTEMD_RELOAD_FAIL=false
export FAKE_SYSTEMD_RELOAD_FAIL
reload_caddy_locked >/dev/null 2>&1
assert_status 0 "$?" "successful reload"
grep -q "^reload$" "$FAKE_SYSTEMD_LOG" || fail "successful reload was not attempted"
if grep -q "^restart$" "$FAKE_SYSTEMD_LOG"; then
    fail "normal reload must not restart the service"
fi

FLOW_CADDY_DIR="$TEST_ROOT/config-flow-caddy"
FLOW_CADDYFILE="$FLOW_CADDY_DIR/Caddyfile"
CADDY_DIR="$FLOW_CADDY_DIR"
CADDYFILE="$FLOW_CADDYFILE"
mkdir -p "$FLOW_CADDY_DIR"
printf "active\n" > "$FAKE_SYSTEMD_STATE"
INTERACTIVE_MODE=false
FORCE_YES=true
configure_site_locked "FLOW.EXAMPLE.COM.:08443" 127.0.0.1:8096 new >/dev/null 2>&1 || fail "port-qualified site configuration failed"
grep -q "^flow.example.com:8443 {[[:space:]]*$" "$FLOW_CADDYFILE" || fail "port-qualified site was not written"
configure_site_locked other.example.com 127.0.0.1:8097 append >/dev/null 2>&1 || fail "multi-site append failed"
grep -q "^flow.example.com:8443 {[[:space:]]*$" "$FLOW_CADDYFILE" || fail "existing port-qualified site was lost during append"
grep -q "^other.example.com {[[:space:]]*$" "$FLOW_CADDYFILE" || fail "appended site was not written"
delete_site_locked flow.example.com:8443 >/dev/null 2>&1 || fail "port-qualified site deletion failed"
! grep -q "flow.example.com:8443" "$FLOW_CADDYFILE" || fail "port-qualified site was not deleted"
grep -q "^other.example.com {[[:space:]]*$" "$FLOW_CADDYFILE" || fail "unrelated site was deleted"

USER_CADDY_DIR="$TEST_ROOT/user-caddy"
USER_CADDYFILE="$USER_CADDY_DIR/Caddyfile"
mkdir -p "$USER_CADDY_DIR"
printf "%s\n" "example.com {" "    respond 200" "}" > "$USER_CADDYFILE"
printf "%s\n" "user data" > "$USER_CADDY_DIR/user.conf"
CADDY_DIR="$USER_CADDY_DIR"
CADDYFILE="$USER_CADDYFILE"
cleanup_caddy_files >/dev/null 2>&1 || true
[[ -f "$USER_CADDYFILE" ]] || fail "user Caddyfile was removed"
[[ -f "$USER_CADDY_DIR/user.conf" ]] || fail "user Caddy data was removed"

USER_BACKUP="$USER_CADDYFILE.bak.user"
printf "%s\n" "user backup" > "$USER_BACKUP"
cleanup_caddy_files >/dev/null 2>&1 || true
[[ -f "$USER_BACKUP" ]] || fail "user Caddyfile backup was removed"

REGULAR_PATH="$TEST_ROOT/regular-path"
printf "%s\n" "data" > "$REGULAR_PATH"
CADDY_DATA_DIR="$REGULAR_PATH"
assert_status 1 "$(cleanup_caddy_data >/dev/null 2>&1; echo $?)" "regular Caddy data path rejection"
[[ -f "$REGULAR_PATH" ]] || fail "regular data path was removed"
STATE_FILE_PATH="$TEST_ROOT/state-file"
printf "%s\n" "state" > "$STATE_FILE_PATH"
STATE_DIR="$STATE_FILE_PATH"
assert_status 1 "$(cleanup_manager_state >/dev/null 2>&1; echo $?)" "regular state path rejection"
[[ -f "$STATE_FILE_PATH" ]] || fail "regular state path was removed"

SCRIPT_DEST="$TEST_ROOT/installed-script.sh"
SHORTCUT="$TEST_ROOT/c"
SCRIPT_SOURCE="$TEST_ROOT/source.sh"
printf "%s\n" "# CADDY-EMBY-MANAGER-MANAGED-SCRIPT" > "$SCRIPT_SOURCE"
chmod 755 "$SCRIPT_SOURCE"
SCRIPT_FIXTURE="$TEST_ROOT/managed-script"
printf '%s\n' '#!/usr/bin/env bash' '#  CADDY-EMBY-MANAGER-MANAGED-SCRIPT' > "$SCRIPT_FIXTURE"
assert_status 0 "$(is_managed_script_file "$SCRIPT_FIXTURE"; echo $?)" "generated script ownership"
printf '%s\n' '#!/usr/bin/env bash' 'CADDY-EMBY-MANAGER-MANAGED-SCRIPT' > "$SCRIPT_FIXTURE"
assert_status 1 "$(is_managed_script_file "$SCRIPT_FIXTURE"; echo $?)" "unrelated script is preserved"
SHORTCUT_FIXTURE="$TEST_ROOT/shortcut"
printf '%s\n' '#!/usr/bin/env bash' "exec bash \"$SCRIPT_DEST\" \"\$@\"" > "$SHORTCUT_FIXTURE"
assert_status 0 "$(is_managed_shortcut_file "$SHORTCUT_FIXTURE"; echo $?)" "generated shortcut ownership"
printf '%s\n' '#!/usr/bin/env bash' "echo exec bash \"$SCRIPT_DEST\" \"\$@\"" > "$SHORTCUT_FIXTURE"
assert_status 1 "$(is_managed_shortcut_file "$SHORTCUT_FIXTURE"; echo $?)" "unrelated shortcut is preserved"
INSTALL_CALL_LOG="$TEST_ROOT/install-call.log"
install_base() { printf "install_base\n" >> "$INSTALL_CALL_LOG"; }
install_caddy() { printf "install_caddy\n" >> "$INSTALL_CALL_LOG"; }
register_shortcut() { printf "register_shortcut\n" >> "$INSTALL_CALL_LOG"; }
run_cli --install
grep -q "^register_shortcut$" "$INSTALL_CALL_LOG" || fail "--install did not register shortcut"

printf "PASS: install_caddy_emby regression tests\n"
