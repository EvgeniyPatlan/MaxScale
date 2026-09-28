#!/bin/bash
#
# Entrypoint of the Percona MaxScale image.
#
# MaxScale reads /etc/maxscale.cnf, which the image ships with a minimal configuration and which
# is meant to be replaced by a mounted one. Files in /etc/maxscale.cnf.d are read as well.
#
set -o errexit

if [ "$1" = "maxscale" ]
then
    shift

    # Directories can come from volumes that are empty or owned by another user.
    for dir in /var/lib/maxscale /var/log/maxscale /var/cache/maxscale /run/maxscale
    do
        if [ ! -w "$dir" ]
        then
            echo >&2 "ERROR: $dir is not writable by the maxscale user ($(id -u):$(id -g))."
            echo >&2 "       Mount it with those permissions, for example: -v maxscale-data:/var/lib/maxscale"
            exit 1
        fi
    done

    if [ ! -r /etc/maxscale.cnf ]
    then
        echo >&2 "ERROR: /etc/maxscale.cnf is missing or not readable."
        exit 1
    fi

    # --nodaemon keeps MaxScale in the foreground so that the container follows its lifetime,
    # and the log goes to stdout for "docker logs".
    exec maxscale --nodaemon --log=stdout "$@"
fi

exec "$@"
