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
xcrun swiftc -parse-as-library \
    -module-cache-path "$PROJECT_DIR/.build/module-cache" \
    "$PROJECT_DIR/Sources/MixWebDeploy/AppSettings.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/ConfigValidator.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/OutputParser.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/JSFile.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/JSArchiveStore.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/JSDownload.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/LocalBuildProcess.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/LocalBuildService.swift" \
    "$PROJECT_DIR/Sources/MixWebDeploy/LocalBuildModel.swift" \
    "$PROJECT_DIR/scripts/local-build-check.swift" \
    "$PROJECT_DIR/scripts/js-manager-check.swift" \
    -o "$PROJECT_DIR/.build/local-build-check"
"$PROJECT_DIR/.build/local-build-check"
