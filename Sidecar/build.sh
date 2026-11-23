#!/bin/sh
# Builds the JDBC sidecar into Resources/sidecar.jar (no external dependencies).
set -e
cd "$(dirname "$0")"
OUT=build/classes
rm -rf build
mkdir -p "$OUT" ../Resources
javac --release 11 -encoding UTF-8 -d "$OUT" $(find src -name '*.java')
jar --create --file build/sidecar.jar --main-class ru.evotor.sqldesk.Main -C "$OUT" .
mv build/sidecar.jar ../Resources/sidecar.jar
echo "sidecar.jar: $(ls -lh ../Resources/sidecar.jar | awk '{print $5}')"
