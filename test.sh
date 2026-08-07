#!/bin/bash
# 跑纯逻辑测试（树操作、拖拽合法性、数据迁移、JSON 往返）
# -DTESTING 会关掉 PrWaiter.swift 里的 @main，改由 Tests.swift 提供入口
set -euo pipefail
cd "$(dirname "$0")"

BIN=$(mktemp -d)/prwaiter-tests
swiftc -swift-version 5 -parse-as-library -DTESTING \
    -o "$BIN" PrWaiter.swift Tests.swift
"$BIN"
