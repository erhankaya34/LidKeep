#!/bin/zsh
set -euo pipefail
root=${0:A:h}
cd "$root"
mkdir -p dist
swiftc -parse-as-library -D LIDKEEP_TESTS \
  -framework AppKit -framework ServiceManagement \
  Sources/LidKeep.swift Tests/RegressionTests.swift -o dist/LidKeepTests
dist/LidKeepTests
