#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
nvim --headless -u NONE -i NONE --noplugin -l tests/setup_contract.lua
nvim --headless -u NONE -i NONE --noplugin -l tests/command_ownership.lua
nvim --headless -u NONE -i NONE --noplugin -l tests/profiler.lua
nvim --headless -u NONE -i NONE --noplugin -l tests/startuptime.lua
stylua --check lua tests
