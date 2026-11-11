#!/bin/bash
cd "$(dirname "$0")/.."
status=0
swift run PortholeSelfTest || status=1
node --test web/tests/*.test.js || status=1
exit $status
