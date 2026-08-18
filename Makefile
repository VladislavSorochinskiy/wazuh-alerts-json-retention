SHELL := /usr/bin/env bash

.PHONY: check lint test

check: lint test

lint:
	bash -n bin/wazuh-alerts-retention
	bash -n install.sh
	bash -n uninstall.sh
	bash -n tests/test-retention.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/wazuh-alerts-retention install.sh uninstall.sh tests/test-retention.sh; \
	else \
		echo 'shellcheck is not installed; static analysis skipped'; \
	fi

test:
	bash tests/test-retention.sh
