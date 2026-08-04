#!/bin/sh
# Run the vim-air test suite. No network and no AWS calls.
cd "$(dirname "$0")/.."
AIR_TEST_LOG=$(mktemp)
export AIR_TEST_LOG
vim -es -N -u test/vimrc -c 'source test/run.vim' </dev/null
status=$?
cat "$AIR_TEST_LOG"
rm -f "$AIR_TEST_LOG"
exit $status
