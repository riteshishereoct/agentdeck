#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! /usr/bin/python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' ; then
    echo 'AgentDeck requires a functional system /usr/bin/python3, version 3.8 or newer. No changes made.' >&2
    exit 1
fi
exec /usr/bin/python3 -I "$ROOT/Compatibility/setup.py" reset
