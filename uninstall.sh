#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

readonly SCRIPT_TARGET='/usr/local/sbin/wazuh-alerts-retention'
readonly CONFIG_TARGET='/etc/default/wazuh-alerts-retention'
readonly SERVICE_TARGET='/etc/systemd/system/wazuh-alerts-retention.service'
readonly TIMER_TARGET='/etc/systemd/system/wazuh-alerts-retention.timer'
readonly LOCK_TARGET='/run/lock/wazuh-alerts-retention.lock'

purge=0

usage() {
    cat <<'USAGE'
Usage: sudo ./uninstall.sh [--purge]

Options:
  --purge  Also remove /etc/default/wazuh-alerts-retention.
  --help   Show this help.

Existing Wazuh logs and previously created backup files are not removed.
USAGE
}

while (($# > 0)); do
    case "$1" in
        --purge)
            purge=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unknown option: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

if (( EUID != 0 )); then
    printf 'ERROR: run this uninstaller as root\n' >&2
    exit 1
fi

systemctl disable --now wazuh-alerts-retention.timer 2>/dev/null || true
systemctl stop wazuh-alerts-retention.service 2>/dev/null || true

rm -f -- "$TIMER_TARGET" "$SERVICE_TARGET" "$SCRIPT_TARGET" "$LOCK_TARGET"

if (( purge == 1 )); then
    rm -f -- "$CONFIG_TARGET"
elif [[ -e "$CONFIG_TARGET" ]]; then
    printf 'Preserved configuration: %s\n' "$CONFIG_TARGET"
fi

systemctl daemon-reload
systemctl reset-failed wazuh-alerts-retention.service wazuh-alerts-retention.timer 2>/dev/null || true

printf 'Wazuh alerts retention units and executable were removed.\n'
