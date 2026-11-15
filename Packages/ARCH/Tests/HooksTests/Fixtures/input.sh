#!/bin/sh
# Writes its script path, its process ID, and the event it read on standard input to standard error, which the shell hook tests read.
echo "path $0" >&2
echo "pid $$" >&2
echo "event $(cat)" >&2
