#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build/module-cache"
xcrun swiftc -parse-as-library \
    -module-cache-path "$PROJECT_DIR/.build/module-cache" \
    "$PROJECT_DIR/Sources/MixWebDeploy/AppSettings.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/ConfigValidator.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/OutputParser.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/ExpectProgram.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/AppModel.swift" \
    "$PROJECT_DIR/scripts/self-check.swift" \
    -o "$PROJECT_DIR/.build/self-check"
"$PROJECT_DIR/.build/self-check"
