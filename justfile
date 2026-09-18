# TunaOS local task surface for Bootsahi.
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

check: lint selftest backend-contract agent

lint:
    shellcheck -S warning scripts/*.sh components/*/*.sh

selftest:
    sudo ./scripts/selftest.sh

backend-contract:
    ./scripts/test-backend-contract.sh

agent:
    ./components/bootsahi-agent/test-agent.sh

payload:
    sudo ./scripts/test-payload.sh
