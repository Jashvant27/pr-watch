#!/bin/zsh
# Refreshes every PR Watch widget now: the app fetches each cached repository and reloads the
# widgets, then quits again if it was not already open. Run it after opening, drafting or merging
# a pull request so the desktop follows. The app has to have run once from Xcode, which registers
# the prwatch:// scheme. `-g` keeps the app in the background.
set -eu
open -g "prwatch://refresh"
