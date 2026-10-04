#!/bin/bash
# Keep failed build/test diagnostics in the workflow annotations as well as logs.
set -euo pipefail
label="$1"
shift
log_file="$(mktemp "${TMPDIR:-/tmp}/notchhub-ci.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

set +e
"$@" 2>&1 | tee "$log_file"
result=${PIPESTATUS[0]}
set -e
if [ "$result" -ne 0 ]; then
    python3 - "$label" "$log_file" <<'PY'
from pathlib import Path
import sys

label, path = sys.argv[1:]
lines = Path(path).read_text(errors='replace').splitlines()
# Native compiler errors can precede the final compilation progress lines.
errors = list(dict.fromkeys(line for line in lines
                           if 'error:' in line or line.startswith(('FAIL:', 'ERROR:'))))
summary = '\n'.join(errors[:30] + ['Last output:'] + lines[-40:])[:24000]
def escape(value):
    return value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
print('::error title=' + escape(label) + '::' + escape(summary))
PY
fi
exit "$result"
