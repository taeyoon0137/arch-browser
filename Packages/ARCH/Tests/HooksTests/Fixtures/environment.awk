#!/usr/bin/awk -f
# Writes the name it was started under and its whole environment, one variable a line, to standard error, as the shell hook tests read it from the run's error output.
BEGIN {
    print "zero " ARGV[0] > "/dev/stderr"
    for (name in ENVIRON) print "env " name "=" ENVIRON[name] > "/dev/stderr"
}
