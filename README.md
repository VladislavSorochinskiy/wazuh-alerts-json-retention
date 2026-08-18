# Wazuh Alerts Retention

[Русская версия](README_RU.md)

Safe, auditable retention for rotated Wazuh alert files using a Bash script and a hardened systemd timer.

Wazuh rotates and compresses alert logs under `/var/ossec/logs/alerts/YYYY/Mon/`, but self-hosted deployments retain these local files until an administrator removes or archives them. This project deletes only selected rotated alert files after a configurable retention period.

> Developed and validated on Debian 12 with Wazuh 4.14.2. Other versions should be checked with `--dry-run` before enabling deletion.

## What it deletes

Only regular files matching these Wazuh patterns are eligible:

```text
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD.log.gz
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD.json.gz
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD.log.sum
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD.json.sum
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD-NNN.log.gz
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD-NNN.json.gz
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD-NNN.log.sum
/var/ossec/logs/alerts/YYYY/Mon/ossec-alerts-DD-NNN.json.sum
```

The default retention is **7 complete 24-hour periods**, evaluated from each file's modification time.

The following are not deleted:

- current `/var/ossec/logs/alerts/alerts.log` and `alerts.json` files;
- uncompressed `.log` and `.json` files;
- directories, symbolic links, unexpected names, or unexpected directory layouts;
- files located on another mounted filesystem below the alerts directory.

## Features

- explicit `--dry-run` and `--delete` modes;
- non-blocking process lock to prevent overlapping manual and scheduled runs;
- strict validation of year, month, filename, depth, type, and age;
- NUL-safe file processing;
- daily systemd timer with `Persistent=true`;
- journald audit trail;
- hardened oneshot service with write access limited to the alerts directory;
- safe installer that performs a dry-run by default and leaves the existing timer state unchanged;
- functional tests and GitHub Actions validation.

## Execution flow

```mermaid
flowchart LR
    T[systemd timer] --> S[oneshot service]
    C[/etc/default configuration] --> S
    S --> L[exclusive process lock]
    L --> F[bounded file scan]
    F --> V[path, type, age and name validation]
    V --> D[delete eligible files]
    D --> J[journald audit trail]
```

The timer starts the oneshot service. The service loads the retention setting, starts the script with `--delete`, and writes the complete result to journald. Manual `--dry-run` and `--delete` executions use the same lock and matching rules.

## Safety controls

| Control | Effect |
|---|---|
| Exact depth | Scans only `alerts/year/month/file` |
| Exact relative-path expression | Accepts only known Wazuh rotated alert names |
| `-type f` | Excludes directories and symbolic links |
| `-xdev` | Does not cross into nested mounted filesystems |
| Modification-age threshold | Deletes only files older than the configured period |
| Non-blocking `flock` | Prevents overlapping scheduled and manual runs |
| Hardened systemd service | Limits writable paths and disables unnecessary privileges |
| Dry-run-first installer | Shows the exact candidate set before optional deletion |

## Repository layout

```text
.
├── bin/
│   └── wazuh-alerts-retention
├── config/
│   └── wazuh-alerts-retention
├── systemd/
│   ├── wazuh-alerts-retention.service
│   └── wazuh-alerts-retention.timer
├── tests/
│   └── test-retention.sh
├── .github/
│   ├── dependabot.yml
│   └── workflows/ci.yml
├── .editorconfig
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
├── Makefile
├── install.sh
├── uninstall.sh
├── README.md
├── README_RU.md
├── SECURITY.md
└── VERSION
```

## Requirements

- self-hosted Wazuh manager with `/var/ossec/logs/alerts`;
- systemd;
- Bash and GNU `find`, `stat`, `mktemp`, `rm`, and `flock`;
- root privileges for installation and scheduled deletion.

## Installation

Clone or download the repository, then enter its directory.

### Safe installation

This installs and validates the files, then performs only a dry-run. It does not start cleanup and leaves the current timer state unchanged.

```bash
sudo ./install.sh
```

Review the `WOULD_DELETE` output, then enable the timer:

```bash
sudo systemctl enable --now wazuh-alerts-retention.timer
```

Run the first real cleanup manually when ready:

```bash
sudo systemctl start wazuh-alerts-retention.service
```

### Complete installation

The following command installs the project, shows a dry-run, performs one real cleanup, and enables the timer:

```bash
sudo ./install.sh --retention-days 7 --run-now --enable
```

The installer backs up existing executable and unit files with a `.bak.YYYYMMDD-HHMMSS` suffix. An existing `/etc/default/wazuh-alerts-retention` file is preserved unless `--retention-days` is supplied.

### Updating an existing installation

Pull or copy the new repository version, then run:

```bash
sudo ./install.sh
```

The installer replaces the executable and unit files, preserves the existing configuration, reloads an already active timer, and performs only a dry-run. It does not trigger an additional cleanup unless `--run-now` is supplied.

## Configuration

The retention period is stored in:

```text
/etc/default/wazuh-alerts-retention
```

Default configuration:

```bash
RETENTION_DAYS=7
```

Allowed values are `1` through `3650`. After changing the value, no service restart is required; the next oneshot execution reads the file again.

## Schedule

The default timer runs every day at **03:15 local server time**, after normal midnight rotation:

```ini
OnCalendar=*-*-* 03:15:00
Persistent=true
```

To change the schedule without editing the installed unit directly:

```bash
sudo systemctl edit wazuh-alerts-retention.timer
```

Example override:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:30:00
```

Apply it:

```bash
sudo systemctl daemon-reload
sudo systemctl restart wazuh-alerts-retention.timer
```

## Manual use

Preview matching files:

```bash
sudo /usr/local/sbin/wazuh-alerts-retention --dry-run
```

Delete matching files immediately:

```bash
sudo /usr/local/sbin/wazuh-alerts-retention --delete
```

Test another retention period without changing the installed configuration:

```bash
sudo RETENTION_DAYS=14 /usr/local/sbin/wazuh-alerts-retention --dry-run
```

## Verification and logs

Check the timer:

```bash
systemctl status wazuh-alerts-retention.timer --no-pager
systemctl list-timers --all --no-pager wazuh-alerts-retention.timer
```

Check the latest cleanup result:

```bash
systemctl status wazuh-alerts-retention.service --no-pager
journalctl -u wazuh-alerts-retention.service -n 100 --no-pager
```

Check current disk usage:

```bash
du -sh /var/ossec/logs/alerts
```

## Testing

Run all local syntax checks, ShellCheck when available, and the functional test suite:

```bash
make check
```

Run only the functional test in an isolated temporary directory:

```bash
bash tests/test-retention.sh
```

Optional static validation:

```bash
shellcheck bin/wazuh-alerts-retention install.sh uninstall.sh tests/test-retention.sh
```

After installation, validate the installed systemd units and their executable path:

```bash
sudo systemd-analyze verify \
  /etc/systemd/system/wazuh-alerts-retention.service \
  /etc/systemd/system/wazuh-alerts-retention.timer
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Completed successfully |
| `1` | Runtime error or one or more deletion failures |
| `2` | Invalid arguments or configuration |
| `75` | Another instance already holds the lock |

## Uninstallation

Remove the executable and systemd units while preserving the configuration file:

```bash
sudo ./uninstall.sh
```

Remove the configuration as well:

```bash
sudo ./uninstall.sh --purge
```

Uninstallation does not remove Wazuh logs or `.bak.*` backups created by the installer.

## Operational considerations

Deleting these files does not remove documents that have already been indexed in Wazuh Indexer. It does remove the corresponding local compressed copies, reducing the local window available for manual recovery, replay, investigation, or external backup. Choose the retention period according to incident-response and compliance requirements.

Empty year and month directories are intentionally left in place.

## References

- [Wazuh event logging and log rotation](https://documentation.wazuh.com/current/user-manual/manager/event-logging.html)
- [Wazuh log data collection workflow](https://documentation.wazuh.com/current/user-manual/capabilities/log-data-collection/how-it-works.html)

## License

MIT. See [LICENSE](LICENSE).
