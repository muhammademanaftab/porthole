#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $DEV/Frameworks -Xlinker -F -Xlinker $DEV/Frameworks \
  -Xlinker -rpath -Xlinker $DEV/Frameworks -Xlinker -rpath -Xlinker $DEV/usr/lib "$@"
