#!/bin/bash
# Builds the member web app and publishes it to the gh-pages branch of
# github.com/zond/spot (served at https://zond.github.io/spot/).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_TS="$(date -Iseconds)"
echo "Building $BUILD_TS..."
flutter pub get
flutter build web --release --base-href /spot/ --dart-define=BUILD_TS="$BUILD_TS"

# Stamp the service worker so browsers pick up the new version
echo "// build: $BUILD_TS" >> build/web/firebase-messaging-sw.js
echo "$BUILD_TS" > build/web/version.txt

REMOTE="${1:-git@github.com:zond/spot.git}"

echo "Deploying to gh-pages via $REMOTE..."
DIR=$(mktemp -d)
cp -r build/web/* "$DIR"
cd "$DIR"
git init -q
git checkout -q -b gh-pages
git add -A
git commit -q -m "Deploy $BUILD_TS"
git push -f "$REMOTE" gh-pages
rm -rf "$DIR"

echo "Done. https://zond.github.io/spot/ updates in ~30 seconds."
