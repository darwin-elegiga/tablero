#!/bin/zsh
# Daily reminder (launchd, weekdays 06:30): the board app notifies and opens its window,
# only when there are unfinished tasks.
# Opened by bundle id, so it works whatever name the app was given.
open -b io.github.darwin-elegiga.tablero --args --notify
