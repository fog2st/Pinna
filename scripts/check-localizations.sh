#!/bin/bash
# Checks every translation against the strings the app uses: lists missing ones, and ones no longer used.
# The compiler finds the strings, from every String(localized:) in the code.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/strings"
# Depending on the build system, the .stringsdata files land in the given folder or next to the object files.
swift build --scratch-path "$WORK/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

python3 -I - "$WORK" Resources/*.lproj/Localizable.strings <<'EOF'
import glob, json, subprocess, sys

strings, tables = sys.argv[1], sys.argv[2:]
used = {entry["key"]
        for path in glob.glob(strings + "/**/*.stringsdata", recursive=True)
        for entries in json.load(open(path))["tables"].values()
        for entry in entries}
status = 0
for table in tables:
    if "/en.lproj/" in table:
        continue  # English is the text in the code
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", table], capture_output=True, check=True)
    translated = json.loads(converted.stdout)
    for key in sorted(used - translated.keys()):
        print(f"{table}: missing {key!r}")
        status = 1
    for key in sorted(translated.keys() - used):
        print(f"{table}: unused {key!r}")
        status = 1
sys.exit(status)
EOF
echo "Every string is translated."
