# Contributing

Contributions that preserve the project's narrow safety boundaries are welcome.

## Development workflow

1. Create a branch from `main`.
2. Keep cleanup rules explicit and limited to rotated Wazuh alert files.
3. Add or update functional tests for every behavior change.
4. Run the complete local check:

```bash
make check
```

5. Validate the systemd units when `systemd-analyze` is available:

```bash
sudo install -D -m 0750 bin/wazuh-alerts-retention /usr/local/sbin/wazuh-alerts-retention
sudo systemd-analyze verify \
  systemd/wazuh-alerts-retention.service \
  systemd/wazuh-alerts-retention.timer
```

## Pull requests

A pull request should describe:

- the operational problem being solved;
- changes to deletion eligibility or retention semantics;
- tests performed;
- compatibility assumptions.

Do not broaden the deletion pattern, directory depth, or writable paths without a documented reason and matching tests.
