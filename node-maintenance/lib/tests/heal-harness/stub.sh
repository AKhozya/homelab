#!/bin/bash
# Stands in for one host command inside the harness container. Installed under each stubbed
# command's name. Logs the call with its arguments, then runs /harness/behavior/<name> if a
# scenario wrote one (it sees "$@", prints the output, and may set rc); otherwise succeeds silently.
cmd="${0##*/}"
{
	printf '%s' "$cmd"
	[ "$#" -gt 0 ] && printf ' %q' "$@"
	printf '\n'
} >>/harness/calls.log
rc=0
behavior="/harness/behavior/$cmd"
if [ -f "$behavior" ]; then
	# shellcheck disable=SC1090
	. "$behavior"
fi
exit "$rc"
