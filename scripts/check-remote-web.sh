#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build/mac-web-module-cache" "$PROJECT_DIR/.build/remote-web-assets"
cp "$PROJECT_DIR/Shared/WebUI/"* "$PROJECT_DIR/.build/remote-web-assets/"
cp "$PROJECT_DIR/Resources/ServerUI/"* "$PROJECT_DIR/.build/remote-web-assets/"
sources=("$PROJECT_DIR"/Sources/MixWebDeploy/*.swift)
sources=("${sources[@]:#*/MixWebDeployApp.swift}")
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$PROJECT_DIR/.build/mac-web-module-cache" \
    "${sources[@]}" "$PROJECT_DIR/scripts/remote-web-check.swift" \
    -o "$PROJECT_DIR/.build/remote-web-check"
"$PROJECT_DIR/.build/remote-web-check" "$PROJECT_DIR/.build/remote-web-assets" "${1:-$PROJECT_DIR/.build/remote-web-report}"
