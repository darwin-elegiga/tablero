#!/bin/zsh
# Daily reminder (launchd, weekdays 06:30): Tablero.app notifies and opens its window,
# only when there are unfinished tasks.
open "$HOME/Applications/Tablero.app" --args --notify
