#!/bin/sh
# Ignores SIGTERM, as its child then does, and marks its working folder once it does, so that only SIGKILL ends the run.
trap '' TERM
sleep 30 &
: > "$TMPDIR/ready"
wait
