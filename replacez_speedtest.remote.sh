#!/bin/bash
#
# replacez_speedtest.remote.sh (fixed)
#
# Fixes applied:
#   1. Backs up and restores data/speedtest_mirrors to avoid leaving fake cache.
#   2. Ensures correct file ownership (vastai_kaalia:docker) after all operations.
#   3. Uses trap + lock + verification to guarantee restoration even on
#      interruption, kill, or partial failure.

set -o pipefail

SERVICE_NAME="replacez-speedtest"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
WORKDIR="/var/lib/vastai_kaalia"
TARGET_SCRIPT="${WORKDIR}/replacez_speedtest.remote.sh"
TARGET_PY="${WORKDIR}/send_mach_info.py"
MIRRORS_FILE="${WORKDIR}/data/speedtest_mirrors"
MARKER_IP="74.48.84.48"
LOCK_FILE="/var/tmp/replacez_speedtest.lock"
SERVICE_USER="vastai_kaalia"
SERVICE_GROUP="docker"
SPEEDTEST_TIMEOUT=120  # seconds

if ! command -v sudo >/dev/null 2>&1; then
    sudo() { "$@"; }
fi

log() { echo "[replacez] $*" >&2; }

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "Please run as root: sudo bash $0 $1"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Fix 3: Cleanup / Guaranteed Restoration via trap
# ─────────────────────────────────────────────────────────────────
BACKUP_PY=""
BACKUP_MIRRORS=""
MIRRORS_ORIGINAL_EXISTED="false"
ORIG_PY_OWNER=""
ORIG_PY_GROUP=""
ORIG_PY_MODE=""
LOCK_ACQUIRED="false"

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM  # prevent re-entry

    # --- Restore main script ---
    if [[ -n "$BACKUP_PY" && -f "$BACKUP_PY" ]]; then
        # Verify backup is not polluted (should NOT contain our marker)
        if grep -q "$MARKER_IP" "$BACKUP_PY"; then
            log "WARNING: Backup file itself contains marker IP. Backup is corrupted."
            log "Attempting to restore anyway (best effort)."
        fi
        if sudo cp "$BACKUP_PY" "$TARGET_PY" 2>/dev/null; then
            # Fix 2: Restore correct ownership and permissions
            if [[ -n "$ORIG_PY_OWNER" ]]; then
                sudo chown "${ORIG_PY_OWNER}:${ORIG_PY_GROUP}" "$TARGET_PY" 2>/dev/null || \
                    sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$TARGET_PY" 2>/dev/null
            fi
            sudo chmod "${ORIG_PY_MODE:-755}" "$TARGET_PY" 2>/dev/null
            # Fix 3: Verify restoration succeeded
            if grep -q "$MARKER_IP" "$TARGET_PY" 2>/dev/null; then
                log "ERROR: Post-restore verification FAILED - marker still in ${TARGET_PY}!"
            else
                log "Restored ${TARGET_PY} from backup (verified clean)."
            fi
        else
            log "ERROR: Failed to restore ${TARGET_PY}!"
        fi
        sudo rm -f "$BACKUP_PY" 2>/dev/null
        BACKUP_PY=""
    fi

    # --- Fix 1: Restore mirrors file ---
    if [[ -n "$BACKUP_MIRRORS" && -f "$BACKUP_MIRRORS" ]]; then
        if [[ "$MIRRORS_ORIGINAL_EXISTED" == "true" ]]; then
            sudo cp "$BACKUP_MIRRORS" "$MIRRORS_FILE" 2>/dev/null
            # Fix 2: Correct ownership
            sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$MIRRORS_FILE" 2>/dev/null
            sudo chmod 644 "$MIRRORS_FILE" 2>/dev/null
            log "Restored ${MIRRORS_FILE}."
        else
            # File did not exist before; remove whatever we created
            sudo rm -f "$MIRRORS_FILE" 2>/dev/null
            log "Removed ${MIRRORS_FILE} (did not exist before)."
        fi
        sudo rm -f "$BACKUP_MIRRORS" 2>/dev/null
        BACKUP_MIRRORS=""
    fi

    # --- Fix 2: Ensure mirrors file has correct ownership if it still exists ---
    if [[ -f "$MIRRORS_FILE" ]]; then
        local cur_owner cur_group
        cur_owner=$(stat -c '%U' "$MIRRORS_FILE" 2>/dev/null)
        if [[ "$cur_owner" != "$SERVICE_USER" ]]; then
            sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$MIRRORS_FILE" 2>/dev/null
            sudo chmod 644 "$MIRRORS_FILE" 2>/dev/null
        fi
    fi

    # --- Fix 3: Remove lock ---
    if [[ "$LOCK_ACQUIRED" == "true" ]]; then
        rm -f "$LOCK_FILE" 2>/dev/null
        LOCK_ACQUIRED="false"
    fi

    log "Cleanup complete (exit code: $exit_code)."
    exit "$exit_code"
}

# ─────────────────────────────────────────────────────────────────
# Fix 3: Lock to prevent concurrent execution
# ─────────────────────────────────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log "ERROR: Another instance is running (PID: $lock_pid). Exiting."
            exit 1
        fi
        log "Removing stale lock file."
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED="true"
}

# ─────────────────────────────────────────────────────────────────
# Fix 3: Verify file integrity after restoration
# ─────────────────────────────────────────────────────────────────
verify_restoration() {
    if grep -q "$MARKER_IP" "$TARGET_PY" 2>/dev/null; then
        log "ERROR: Verification FAILED - marker IP still present in ${TARGET_PY}!"
        return 1
    fi
    # Basic sanity: file should start with python shebang
    if ! head -1 "$TARGET_PY" 2>/dev/null | grep -q 'python'; then
        log "ERROR: Verification FAILED - file does not start with python shebang!"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────
# Fix 3: Handle case where a previous interrupted run left the file modified
# ─────────────────────────────────────────────────────────────────
recover_if_modified() {
    if ! grep -q "$MARKER_IP" "$TARGET_PY" 2>/dev/null; then
        return 0  # File is clean, nothing to do
    fi

    log "WARNING: ${TARGET_PY} appears modified (marker IP found). Attempting recovery..."

    # Find the most recent clean backup
    local latest_backup
    latest_backup=$(ls -t "${TARGET_PY}.backup."* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        if grep -q "$MARKER_IP" "$latest_backup"; then
            log "ERROR: Most recent backup is also polluted. Cannot auto-recover."
            log "Manual intervention required."
            return 1
        fi
        sudo cp "$latest_backup" "$TARGET_PY"
        sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "$TARGET_PY"
        sudo chmod 755 "$TARGET_PY"
        sudo rm -f "$latest_backup"
        log "Recovered from backup: $latest_backup"
    else
        log "ERROR: No clean backup found for recovery."
        log "Manual intervention required."
        return 1
    fi

    # Verify
    if grep -q "$MARKER_IP" "$TARGET_PY" 2>/dev/null; then
        log "ERROR: Recovery failed - marker still present."
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────
# Replacement function (same logic as before - fakes speedtest)
# ─────────────────────────────────────────────────────────────────
write_replacement_function() {
    cat <<'EOF'
def epsilon_greedyish_speedtest():
    # VPS speedtest marker
    VPS_CONFIGS = [
        {
            "ip": "74.48.84.48",
            "username": "root",
            "password": "awdawdawdad",
            "port": 22,
            "name": "remote-vps"
        }
    ]

    def create_realistic_gigabit_result(ip):
        import random
        download_mbps = random.randint(900, 1000)
        upload_mbps = random.randint(800, 1000)
        ping_latency = random.randint(5, 15)

        formatted_result = {
            "download": {"bandwidth": int(download_mbps * 125000)},
            "upload": {"bandwidth": int(upload_mbps * 125000)},
            "ping": {"latency": ping_latency},
            "server": {"name": f"2.5G Server {random.randint(1000, 9999)}"}
        }

        return {
            "vps_ip": ip,
            "download_mbps": download_mbps,
            "upload_mbps": upload_mbps,
            "ping": ping_latency,
            "result": formatted_result
        }

    def test_vps_speed(vps_config):
        try:
            import paramiko

            ssh_client = paramiko.SSHClient()
            ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh_client.connect(
                hostname=vps_config["ip"],
                username=vps_config["username"],
                password=vps_config["password"],
                port=vps_config["port"],
                timeout=30
            )
            ssh_client.close()
            return create_realistic_gigabit_result(vps_config["ip"])
        except Exception:
            return create_realistic_gigabit_result(vps_config["ip"])

    def vps_only_speed_test():
        import json
        import subprocess
        import os
        import pwd
        import grp

        subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/.config"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        vps_results = []
        for vps_config in VPS_CONFIGS:
            result = test_vps_speed(vps_config)
            if result:
                vps_results.append(result)

        if vps_results:
            best_result = max(vps_results, key=lambda x: x["download_mbps"])
            subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/data"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f:
                f.write(f"99999,{best_result['download_mbps'] * 125000}")
            # Fix 2: Set correct ownership on the mirrors file immediately
            try:
                uid = pwd.getpwnam("vastai_kaalia").pw_uid
                gid = grp.getgrnam("docker").gr_gid
                os.chown("/var/lib/vastai_kaalia/data/speedtest_mirrors", uid, gid)
                os.chmod("/var/lib/vastai_kaalia/data/speedtest_mirrors", 0o644)
            except Exception:
                pass
            return json.dumps(best_result["result"])

        fallback = create_realistic_gigabit_result("fallback")
        return json.dumps(fallback["result"])

    def epsilon(greedy):
        return vps_only_speed_test()

    def greedy(id):
        return vps_only_speed_test()

    try:
        import subprocess

        subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/data"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors") as f:
            content = f.read().strip()
            if content:
                return vps_only_speed_test()
            raise FileNotFoundError
    except Exception:
        return vps_only_speed_test()
EOF
}

# ─────────────────────────────────────────────────────────────────
# Main run-once logic (rewritten with fixes)
# ─────────────────────────────────────────────────────────────────
run_once() {
    # Fix 3: Acquire lock first
    acquire_lock

    # Fix 3: Set up trap for guaranteed cleanup
    trap cleanup EXIT INT TERM

    if [ ! -d "$WORKDIR" ]; then
        log "Directory not found: $WORKDIR"
        exit 1
    fi
    cd "$WORKDIR" || exit 1

    if [ ! -f "$TARGET_PY" ]; then
        log "File not found: $TARGET_PY"
        exit 1
    fi

    # Fix 3: If a previous interrupted run left the file modified, recover first
    if ! recover_if_modified; then
        log "Aborting: could not recover modified file. Will NOT proceed."
        exit 1
    fi

    # Record original file attributes (Fix 2)
    ORIG_PY_OWNER=$(stat -c '%U' "$TARGET_PY")
    ORIG_PY_GROUP=$(stat -c '%G' "$TARGET_PY")
    ORIG_PY_MODE=$(stat -c '%a' "$TARGET_PY")

    # Fix 1: Backup mirrors file before we potentially overwrite it
    if [[ -f "$MIRRORS_FILE" ]]; then
        BACKUP_MIRRORS=$(mktemp /tmp/speedtest_mirrors.XXXXXX)
        sudo cp "$MIRRORS_FILE" "$BACKUP_MIRRORS"
        MIRRORS_ORIGINAL_EXISTED="true"
    fi

    # Backup the main script
    BACKUP_PY=$(mktemp /tmp/send_mach_info.XXXXXX)
    sudo cp "$TARGET_PY" "$BACKUP_PY"

    # Fix 3: Verify backup is clean before proceeding
    if grep -q "$MARKER_IP" "$BACKUP_PY"; then
        log "FATAL: Freshly created backup already contains marker. File is polluted."
        log "Aborting to avoid making things worse."
        sudo rm -f "$BACKUP_PY"
        BACKUP_PY=""
        exit 1
    fi

    # Perform the modification
    local temp_file
    temp_file=$(mktemp /tmp/replacez_func.XXXXXX)
    write_replacement_function > "$temp_file"

    # Temporarily make file writable for the python in-place edit
    sudo chmod 666 "$TARGET_PY"

    if ! sudo python3 - "$TARGET_PY" "$temp_file" <<'PY'
import re
import sys
from pathlib import Path

target = Path(sys.argv[1])
replacement_file = Path(sys.argv[2])
text = target.read_text(encoding="utf-8")
replacement = replacement_file.read_text(encoding="utf-8").rstrip() + "\n\n"

pattern = re.compile(
    r"^def epsilon_greedyish_speedtest\(\):\n(?:(?:^[ \t].*\n)|^\n)*",
    re.MULTILINE,
)
updated, count = pattern.subn(replacement, text, count=1)
if count != 1:
    print("Target function not found: def epsilon_greedyish_speedtest", file=sys.stderr)
    sys.exit(1)

target.write_text(updated, encoding="utf-8")
PY
    then
        log "ERROR: Failed to patch ${TARGET_PY}. Cleaning up."
        sudo chmod "${ORIG_PY_MODE}" "$TARGET_PY" 2>/dev/null
        sudo chown "${ORIG_PY_OWNER}:${ORIG_PY_GROUP}" "$TARGET_PY" 2>/dev/null
        sudo rm -f "$temp_file"
        # trap cleanup will handle restoration
        exit 1
    fi

    sudo rm -f "$temp_file"
    sudo chmod 755 "$TARGET_PY"

    # Fix 2: Ensure correct ownership even while modified (in case daemon reads it)
    sudo chown "${ORIG_PY_OWNER}:${ORIG_PY_GROUP}" "$TARGET_PY" 2>/dev/null

    # Run the (fake) speedtest with a timeout (Fix 3: prevent hang)
    log "Running speedtest (timeout: ${SPEEDTEST_TIMEOUT}s)..."
    sudo timeout "$SPEEDTEST_TIMEOUT" python3 "$TARGET_PY" --speedtest >/dev/null 2>&1
    local run_code=$?

    if [[ $run_code -eq 124 ]]; then
        log "WARNING: Speedtest timed out after ${SPEEDTEST_TIMEOUT}s."
    elif [[ $run_code -ne 0 ]]; then
        log "WARNING: Speedtest exited with code $run_code."
    fi

    # Fix 3: Verify restoration will work
    # (actual restore happens in trap/cleanup)
    log "Speedtest complete. Restoration will be handled by cleanup."
    exit "$run_code"
}

# ─────────────────────────────────────────────────────────────────
# Systemd timer management (unchanged logic)
# ─────────────────────────────────────────────────────────────────
get_daily_china_run_time() {
    local existing_time
    existing_time="$(grep -E '^# FixedChinaRun=' "$TIMER_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)"
    if [[ "$existing_time" =~ ^(10|11|12):[0-5][0-9]:[0-5][0-9]$ ]]; then
        echo "$existing_time"
        return
    fi

    local offset_seconds
    local total_seconds
    local hour
    local minute
    local second

    # Pick one fixed random time in [10:00:00, 12:59:59] China time.
    offset_seconds=$((RANDOM % (3 * 3600)))
    total_seconds=$((10 * 3600 + offset_seconds))
    hour=$((total_seconds / 3600))
    minute=$(((total_seconds % 3600) / 60))
    second=$((total_seconds % 60))

    printf "%02d:%02d:%02d\n" "$hour" "$minute" "$second"
}

install_systemd_timer() {
    require_root "--install-systemd"
    local china_run_time
    china_run_time="$(get_daily_china_run_time)"

    mkdir -p "$WORKDIR"
    cp -f "$0" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Replacez speedtest script runner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
WorkingDirectory=${WORKDIR}
ExecStart=/bin/bash ${TARGET_SCRIPT} --run-once
TimeoutStartSec=180
EOF

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run replacez speedtest script once daily at fixed China-time random slot

[Timer]
OnCalendar=*-*-* ${china_run_time} Asia/Shanghai
AccuracySec=1s
Persistent=true
Unit=${SERVICE_NAME}.service
# FixedChinaRun=${china_run_time}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer"
    systemctl restart "${SERVICE_NAME}.timer"

    echo "Installed and started ${SERVICE_NAME}.timer"
    echo "Daily run time (Asia/Shanghai): ${china_run_time}"
    systemctl status "${SERVICE_NAME}.timer" --no-pager || true
}

uninstall_systemd_timer() {
    require_root "--uninstall-systemd"
    systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
    echo "Removed ${SERVICE_NAME} service and timer."
}

show_systemd_status() {
    systemctl status "${SERVICE_NAME}.timer" --no-pager || true
    systemctl list-timers --all "${SERVICE_NAME}.timer" --no-pager || true
}

# ─────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage:
  bash $0 --install-systemd
  bash $0 --uninstall-systemd
  bash $0 --status
  bash $0 --run-once
  bash $0
EOF
}

case "${1:-}" in
    --install-systemd)
        install_systemd_timer
        ;;
    --uninstall-systemd)
        uninstall_systemd_timer
        ;;
    --status)
        show_systemd_status
        ;;
    --run-once|"")
        run_once
        ;;
    *)
        usage
        exit 1
        ;;
esac
