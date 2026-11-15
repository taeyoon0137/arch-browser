#!/bin/sh
# Starts a child that sleeps, names it on standard error, and waits for it, so that only the time limit ends the run.
sleep 30 &
echo "child $!" >&2
wait
