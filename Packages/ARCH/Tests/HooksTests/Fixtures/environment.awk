#!/usr/bin/awk -f
# Writes its whole environment, one variable a line, to standard error, as the shell hook tests read it from the run's error output.
BEGIN {
    for (name in ENVIRON) print "env " name "=" ENVIRON[name] > "/dev/stderr"
}
