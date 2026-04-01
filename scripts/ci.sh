#!/bin/bash
set -e

echo "🚀 Starting MacGuard CI Gate..."

# 1. Build
echo "📦 Building project..."
swift build

# 2. Test
echo "🧪 Running unit tests..."
swift test --parallel

# 3. Code Coverage (Optional check if tools available)
# xcodebuild test -scheme MacGuard -enableCodeCoverage YES ...

echo "✅ CI Gate Passed!"
