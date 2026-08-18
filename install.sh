#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT
readonly SCRIPT_SOURCE="$PROJECT_ROOT/bin/wazuh-alerts-retention"
readonly CONFIG_SOURCE="$PROJECT_ROOT/config/wazuh-alerts-retention"
readonly SERVICE_SOURCE="$PROJECT_ROOT/systemd/wazuh-alerts-retention.service"
readonly TIMER_SOURCE="$PROJECT_ROOT/systemd/wazuh-alerts-retention.timer"
readonly UNINSTALL_SOURCE="$PROJECT_ROOT/uninstall.sh"

readonly SCRIPT_TARGET='/usr/local/sbin/wazuh-alerts-retention'
readonly CONFIG_TARGET='/etc/default/wazuh-alerts-retention'
readonly SERVICE_TARGET='/etc/systemd/system/wazuh-alerts-retention.service'
readonly TIMER_TARGET='/etc/systemd/system/wazuh-alerts-retention.timer'

enable_timer=0
run_now=0
retention_override=''

usage() {
    cat <<'USAGE'
Usage: sudo ./install.sh [OPTIONS]

Options:
  --enable               Enable and start the systemd timer.
  --run-now              Run one real cleanup after installation.
  --retention-days DAYS  Set the retention period (1-3650 days).
  --help                 Show this help.

Default behavior is safe: install files, validate them, and run only a dry-run.
No cleanup is started, and the current enabled/disabled state of the timer is left unchanged.
USAGE
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

backup_if_present() {
    local target="$1"
    local stamp="$2"

    if [[ -e "$target" ]]; then
        cp -a -- "$target" "${target}.bak.${stamp}"
        printf 'Backed up: %s -> %s\n' "$target" "${target}.bak.${stamp}"
    fi
}

read_retention_days() {
    local config_file="$1"
    local value

    value="$(sed -nE 's/^[[:space:]]*RETENTION_DAYS[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config_file" | tail -n 1)"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || (( value > 3650 )); then
        fail "RETENTION_DAYS in $config_file must be an integer from 1 to 3650"
    fi

    printf '%s\n' "$value"
}

validate_existing_config_permissions() {
    local config_file="$1"
    local owner_id
    local mode

    [[ -f "$config_file" && ! -L "$config_file" ]] || \
        fail "configuration must be a regular non-symlink file: $config_file"

    owner_id="$(stat -c '%u' -- "$config_file")"
    [[ "$owner_id" == '0' ]] || fail "configuration must be owned by root: $config_file"

    mode="$(stat -c '%a' -- "$config_file")"
    mode="${mode: -3}"
    if (( (8#$mode & 0022) != 0 )); then
        fail "configuration must not be writable by group or others: $config_file"
    fi
}

while (($# > 0)); do
    case "$1" in
        --enable)
            enable_timer=1
            shift
            ;;
        --run-now)
            run_now=1
            shift
            ;;
        --retention-days)
            (($# >= 2)) || fail '--retention-days requires a value'
            retention_override="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

if (( EUID != 0 )); then
    fail 'run this installer as root'
fi

if [[ -n "$retention_override" ]] && \
   { [[ ! "$retention_override" =~ ^[1-9][0-9]*$ ]] || (( retention_override > 3650 )); }; then
    fail '--retention-days must be an integer from 1 to 3650'
fi

for source_file in "$SCRIPT_SOURCE" "$CONFIG_SOURCE" "$SERVICE_SOURCE" "$TIMER_SOURCE" "$UNINSTALL_SOURCE"; do
    [[ -f "$source_file" ]] || fail "required repository file is missing: $source_file"
done

for command_name in bash chmod chown cp date dirname find flock install mktemp rm sed stat systemctl systemd-analyze tail; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

[[ -d /var/ossec/logs/alerts ]] || fail 'Wazuh alerts directory does not exist: /var/ossec/logs/alerts'

if [[ -n "$retention_override" ]]; then
    retention_days="$retention_override"
elif [[ -e "$CONFIG_TARGET" ]]; then
    validate_existing_config_permissions "$CONFIG_TARGET"
    retention_days="$(read_retention_days "$CONFIG_TARGET")"
else
    retention_days="$(read_retention_days "$CONFIG_SOURCE")"
fi
readonly retention_days

if systemctl is-active --quiet wazuh-alerts-retention.service; then
    fail 'wazuh-alerts-retention.service is currently running; retry after it finishes'
fi

timer_was_active=0
if systemctl is-active --quiet wazuh-alerts-retention.timer; then
    timer_was_active=1
fi

bash -n "$SCRIPT_SOURCE"
bash -n "$PROJECT_ROOT/install.sh"
bash -n "$PROJECT_ROOT/uninstall.sh"

stamp="$(date '+%Y%m%d-%H%M%S')"
install -d -o root -g root -m 0755 /usr/local/sbin /etc/default /etc/systemd/system

backup_if_present "$SCRIPT_TARGET" "$stamp"
backup_if_present "$SERVICE_TARGET" "$stamp"
backup_if_present "$TIMER_TARGET" "$stamp"

install -o root -g root -m 0750 "$SCRIPT_SOURCE" "$SCRIPT_TARGET"
install -o root -g root -m 0644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
install -o root -g root -m 0644 "$TIMER_SOURCE" "$TIMER_TARGET"

if [[ -n "$retention_override" ]]; then
    backup_if_present "$CONFIG_TARGET" "$stamp"
    printf '# Number of complete 24-hour periods to retain rotated Wazuh alert files.\nRETENTION_DAYS=%s\n' \
        "$retention_override" > "$CONFIG_TARGET"
    chown root:root "$CONFIG_TARGET"
    chmod 0644 "$CONFIG_TARGET"
elif [[ ! -e "$CONFIG_TARGET" ]]; then
    install -o root -g root -m 0644 "$CONFIG_SOURCE" "$CONFIG_TARGET"
else
    printf 'Preserved existing configuration: %s\n' "$CONFIG_TARGET"
fi

systemd-analyze verify "$SERVICE_TARGET" "$TIMER_TARGET"
systemctl daemon-reload

# Reload an already active timer without changing its enabled/disabled state.
if (( timer_was_active == 1 )); then
    systemctl restart wazuh-alerts-retention.timer
fi

printf '\n=== Dry-run ===\n'
RETENTION_DAYS="$retention_days" "$SCRIPT_TARGET" --dry-run

if (( run_now == 1 )); then
    printf '\n=== First cleanup ===\n'
    systemctl start wazuh-alerts-retention.service
fi

if (( enable_timer == 1 )); then
    printf '\n=== Enable timer ===\n'
    systemctl enable --now wazuh-alerts-retention.timer
fi

printf '\nInstallation completed.\n'
printf 'Script:  %s\n' "$SCRIPT_TARGET"
printf 'Config:  %s\n' "$CONFIG_TARGET"
printf 'Service: %s\n' "$SERVICE_TARGET"
printf 'Timer:   %s\n' "$TIMER_TARGET"

if (( enable_timer == 1 )); then
    systemctl list-timers --all --no-pager wazuh-alerts-retention.timer
else
    timer_state="$(systemctl is-enabled wazuh-alerts-retention.timer 2>/dev/null || true)"
    [[ -n "$timer_state" ]] || timer_state='unknown'
    printf '\nTimer state was not changed. Current state: %s\n' "$timer_state"
    printf 'Enable it with:\n'
    printf '  systemctl enable --now wazuh-alerts-retention.timer\n'
fi

if (( run_now == 0 )); then
    printf '\nNo files were deleted by the installer. Run one cleanup with:\n'
    printf '  systemctl start wazuh-alerts-retention.service\n'
fi
