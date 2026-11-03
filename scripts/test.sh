#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run PortholeSelfTest "$@"
node --test web/
