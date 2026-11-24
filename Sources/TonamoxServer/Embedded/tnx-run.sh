#!/bin/sh
# tnx-run.sh: runs a command, posts its output and exit status to a Tonamox ingest URL,
# then exits with the command's status. Served by TonamoxServer at /s/tnx-run.sh.
# Usage: echo '<ingest-url>' | sh tnx-run.sh -- <command> [arguments...]
# The URL comes on standard input and reaches curl through -K -, so it never appears in ps.
umask 077
if [ "$#" -lt 2 ] || [ "$1" != "--" ]; then
  echo "usage: echo '<ingest-url>' | sh tnx-run.sh -- <command> [arguments...]" >&2
  exit 2
fi
url=
IFS= read -r url
case "$url" in
  *[!A-Za-z0-9:/._-]*) echo "tnx-run.sh: not an ingest URL" >&2; exit 2 ;;
  http://*/i/*) ;;
  *) echo "tnx-run.sh: not an ingest URL" >&2; exit 2 ;;
esac
shift
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
"$@" </dev/null >"$out" 2>&1
status=$?
printf 'url = "%s"\n' "$url" | curl -sS -K - --data-binary "@$out" -H "X-Tonamox-Exit-Status: $status"
exit "$status"
