#!/bin/bash
# Drives the Insomnia menu bar app through its insomnia:// URL scheme.
#
#   insomnia-ctl.sh start [DURATION]   start a session (default preset without DURATION)
#   insomnia-ctl.sh extend DURATION    extend the running session
#   insomnia-ctl.sh end                end the running session
#   insomnia-ctl.sh status             write the session state to insomnia.log
#
# DURATION is 8h, 30m, 28800s or plain seconds (28800).
# `open -g` hands the URL to Insomnia without bringing anything forward,
# and launches the app first when it is not running. The app answers in
# ~/Library/Logs/Insomnia/insomnia.log, not here.
set -eu

usage() {
  echo "usage: $(basename "$0") start [DURATION] | extend DURATION | end | status" >&2
  echo "DURATION: 8h, 30m, 28800s or 28800 (seconds)" >&2
  exit 2
}

# Prints DURATION in seconds; fails for anything but a positive whole number
# with an optional h, m or s suffix.
seconds() {
  local n unit
  case "$1" in
    *h) n=${1%h}; unit=3600 ;;
    *m) n=${1%m}; unit=60 ;;
    *s) n=${1%s}; unit=1 ;;
    *) n=$1; unit=1 ;;
  esac
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
  esac
  # 10# so a leading zero is not read as octal.
  n=$((10#$n))
  [ "$n" -gt 0 ] || return 1
  echo $((n * unit))
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  start)
    if [ $# -eq 0 ]; then
      url="insomnia://start"
    elif [ $# -eq 1 ]; then
      s=$(seconds "$1") || usage
      url="insomnia://start?seconds=$s"
    else
      usage
    fi
    ;;
  extend)
    [ $# -eq 1 ] || usage
    s=$(seconds "$1") || usage
    url="insomnia://extend?seconds=$s"
    ;;
  end | status)
    [ $# -eq 0 ] || usage
    url="insomnia://$cmd"
    ;;
  *)
    usage
    ;;
esac
open -g "$url"
