#!/bin/bash
set -e

PROJECT="Indicator/Indicator.xcodeproj"
SCHEME="Indicator"
APP_NAME="Indicator"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "▶ 빌드 중..."
xcodebuild -project "$PROJECT" \
           -scheme "$SCHEME" \
           -configuration Debug build \
           2>&1 | grep -E "error:|warning:|Build succeeded|Build FAILED" || true

# 빌드 결과 확인
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug build > /tmp/indicator_build.log 2>&1; then
    echo "❌ 빌드 실패"
    grep "error:" /tmp/indicator_build.log | head -20
    exit 1
fi

echo "▶ 기존 앱 종료..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "▶ 설치 중..."
BUILD_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR" | awk '{print $3}')
rm -rf "$INSTALL_PATH"
cp -R "$BUILD_DIR/$APP_NAME.app" "$INSTALL_PATH"

echo "▶ 손쉬운 사용 권한 초기화..."
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || echo "")
if [ -n "$BUNDLE_ID" ]; then
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
fi

echo "▶ 실행 중..."
open "$INSTALL_PATH"

echo "✅ 완료"
