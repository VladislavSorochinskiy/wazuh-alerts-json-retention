# Security policy

## Supported versions

Security fixes are applied to the latest release.

## Reporting a vulnerability

Use GitHub private vulnerability reporting when it is enabled for the repository. Do not publish exploit details, destructive test data, credentials, or host-specific paths in a public issue.

Include the affected version, operating system, Wazuh version, reproduction steps, expected behavior, and observed behavior.

## Security scope

This project runs as `root` because it deletes Wazuh-owned files. Its safety model therefore depends on strict path validation, exact filename matching, fixed directory depth, regular-file checks, process locking, and systemd filesystem restrictions. Changes to any of these controls require additional review and tests.
