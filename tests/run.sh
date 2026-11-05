#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
nvim --headless -u NONE -i NONE --noplugin -l tests/profiler.lua
nvim --headless -u NONE -i NONE --noplugin -l tests/startuptime.lua
stylua --check lua tests
