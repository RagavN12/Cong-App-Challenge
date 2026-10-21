#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ecoai-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -module-cache-path "$test_dir/modules" \
  EcoAI/Models/ChatModels.swift \
  EcoAI/Models/EnergyUsageSnapshot.swift \
  EcoAI/Models/EnergyBudget.swift \
  EcoAI/Models/EnergyLimitContext.swift \
  EcoAI/Services/AccountStorage.swift \
  EcoAI/Services/CredentialVault.swift \
  EcoAI/Services/ResponseRetryPolicy.swift \
  EcoAI/Services/ChatLocalRepository.swift \
  EcoAI/Services/EnergyUsageRepository.swift \
  EcoAI/Services/CloudflareAccessPoint.swift \
  EcoAI/Stores/ChatStore.swift \
  EcoAI/Stores/EnergyUsageStore.swift \
  EcoAI/Stores/AccountDataStore.swift \
  tests/RegressionTests.swift -o "$test_dir/regressions"
"$test_dir/regressions"
