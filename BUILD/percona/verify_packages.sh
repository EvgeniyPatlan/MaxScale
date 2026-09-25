#!/bin/bash
#
# Verifies percona-maxscale packages on every supported platform.
#
# For each platform the script installs the packages in a container of that distribution,
# points MaxScale at two real MariaDB servers (a master and its replica) and checks that
# queries are routed, that the monitor sees the replication topology, and that the REST API
# and the GUI answer. The backends and MaxScale share the host network, so the platforms are
# verified one after another.
#
# Usage: verify_packages.sh --packages=DIR [OPTIONS]
#     --packages=DIR      Directory with the packages. Either rpm/ and deb/ subdirectories
#                         (the layout the builder produces) or the packages directly in DIR.
#     --platforms=LIST    Space separated subset of: el8 el9 el10 amzn2023 jammy noble
#                         bookworm trixie (default: all of them)
#     --keep              Leave the MariaDB backends running afterwards
#     --help
#

set -o pipefail

PACKAGES=
PLATFORMS="el8 el9 el10 amzn2023 jammy noble bookworm trixie"
KEEP=0

MASTER_PORT=3000
REPLICA_PORT=3001
RWSPLIT_PORT=4006
READCONN_PORT=4008
ADMIN_PORT=8989
BACKEND_IMAGE=mariadb:10.11
MASTER_ID=3000
REPLICA_ID=3001

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

die() {
    echo >&2 "ERROR: $*"
    exit 1
}

platform_image() {
    case "$1" in
        el8)      echo oraclelinux:8 ;;
        el9)      echo oraclelinux:9 ;;
        el10)     echo oraclelinux:10 ;;
        amzn2023) echo amazonlinux:2023 ;;
        jammy)    echo ubuntu:jammy ;;
        noble)    echo ubuntu:noble ;;
        bookworm) echo debian:bookworm ;;
        trixie)   echo debian:trixie ;;
        *)        return 1 ;;
    esac
}

# Prints the packages of one platform, newline separated.
platform_packages() {
    local platform=$1
    case "$platform" in
        el*|amzn*) find "$PACKAGES" -name "*.${platform}.*.rpm" ! -name "*.src.rpm" ;;
        *)         find "$PACKAGES" -name "*.${platform}_*.deb" ;;
    esac
}

parse_arguments() {
    for arg do
        local val=${arg#*=}
        case "$arg" in
            --packages=*)  PACKAGES="$val" ;;
            --platforms=*) PLATFORMS="$val" ;;
            --keep)        KEEP=1 ;;
            --help)        usage ;;
            *)             die "Unknown option: $arg" ;;
        esac
    done
    [ -n "$PACKAGES" ] || usage
    PACKAGES=$(cd "$PACKAGES" && pwd) || die "No such directory: $PACKAGES"
}

check_prerequisites() {
    command -v docker > /dev/null || die "docker is required"
    local port
    for port in $MASTER_PORT $REPLICA_PORT $RWSPLIT_PORT $READCONN_PORT $ADMIN_PORT
    do
        if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null
        then
            die "Port $port is already in use; stop whatever listens there first"
        fi
    done
}

mariadb_client() {  # mariadb_client <port> <sql>
    docker run --rm --network host "$BACKEND_IMAGE" \
        mariadb -h 127.0.0.1 -P "$1" -u root --skip-ssl -N -B -e "$2" 2>/dev/null
}

wait_for_backend() {  # wait_for_backend <port>
    local i
    for ((i = 0; i < 90; i++))
    do
        [ "$(mariadb_client "$1" 'SELECT 1')" = "1" ] && return 0
        sleep 2
    done
    return 1
}

start_backends() {
    echo "== starting MariaDB backends"
    docker rm -f mxsverify-master mxsverify-replica > /dev/null 2>&1

    docker run -d --name mxsverify-master --network host \
        -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "$BACKEND_IMAGE" \
        --server-id=$MASTER_ID --port=$MASTER_PORT --log-bin=binlog --binlog-format=ROW \
        --log-slave-updates --gtid-strict-mode=1 > /dev/null || die "Cannot start the master"

    docker run -d --name mxsverify-replica --network host \
        -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "$BACKEND_IMAGE" \
        --server-id=$REPLICA_ID --port=$REPLICA_PORT --log-bin=binlog --binlog-format=ROW \
        --log-slave-updates --gtid-strict-mode=1 > /dev/null || die "Cannot start the replica"

    wait_for_backend $MASTER_PORT || die "The master did not start"
    wait_for_backend $REPLICA_PORT || die "The replica did not start"

    # The users are created on the master and reach the replica through replication.
    mariadb_client $MASTER_PORT "
        CREATE USER 'maxuser'@'%' IDENTIFIED BY 'maxpwd';
        GRANT ALL ON *.* TO 'maxuser'@'%';
        CREATE USER 'repl'@'%' IDENTIFIED BY 'repl';
        GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';" > /dev/null \
        || die "Cannot create the users on the master"

    mariadb_client $REPLICA_PORT "
        CHANGE MASTER TO MASTER_HOST='127.0.0.1', MASTER_PORT=$MASTER_PORT,
            MASTER_USER='repl', MASTER_PASSWORD='repl', MASTER_USE_GTID=slave_pos;
        START SLAVE;" > /dev/null || die "Cannot start replication on the replica"

    local i
    for ((i = 0; i < 30; i++))
    do
        [ "$(mariadb_client $REPLICA_PORT "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND LIKE 'Slave%'")" -ge 1 ] \
            && { echo "   backends ready (master $MASTER_PORT, replica $REPLICA_PORT)"; return 0; }
        sleep 2
    done
    die "Replication did not start"
}

stop_backends() {
    docker rm -f mxsverify-master mxsverify-replica > /dev/null 2>&1
}

write_maxscale_config() {  # write_maxscale_config <file>
    cat > "$1" <<EOF
[maxscale]
threads=2
admin_host=127.0.0.1
admin_port=$ADMIN_PORT
admin_secure_gui=false

[server1]
type=server
address=127.0.0.1
port=$MASTER_PORT

[server2]
type=server
address=127.0.0.1
port=$REPLICA_PORT

[MariaDB-Monitor]
type=monitor
module=mariadbmon
servers=server1,server2
user=maxuser
password=maxpwd
monitor_interval=1s

[RW-Split-Router]
type=service
router=readwritesplit
servers=server1,server2
user=maxuser
password=maxpwd

[Read-Only-Service]
type=service
router=readconnroute
router_options=slave
servers=server1,server2
user=maxuser
password=maxpwd

[RW-Split-Listener]
type=listener
service=RW-Split-Router
port=$RWSPLIT_PORT

[Read-Only-Listener]
type=listener
service=Read-Only-Service
port=$READCONN_PORT
EOF
}

# The part that runs inside the platform container: install the packages and start MaxScale.
write_container_script() {  # write_container_script <file>
    cat > "$1" <<'EOF'
set -o errexit
set -o xtrace

if command -v apt-get > /dev/null
then
    apt-get update -qq
    # curl and pgrep are used by the checks; some images have neither.
    command -v curl > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl
    command -v pgrep > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq procps
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /pkgs/*.deb
else
    # Installing curl on Amazon Linux would conflict with the preinstalled curl-minimal.
    command -v curl > /dev/null || dnf install -y -q curl
    command -v pgrep > /dev/null || dnf install -y -q procps-ng
    dnf install -y -q /pkgs/*.rpm
fi

# The packages must not be built for a different distribution.
maxscale --version

install -o maxscale -g maxscale -d /var/log/maxscale /var/lib/maxscale /var/cache/maxscale /run/maxscale
cp /cnf/maxscale.cnf /etc/maxscale.cnf

maxscale -U maxscale -f /etc/maxscale.cnf --log=stdout > /var/log/maxscale/stdout.log 2>&1 &

for i in $(seq 1 60)
do
    maxctrl list servers > /dev/null 2>&1 && break
    sleep 1
done
maxctrl list servers > /dev/null 2>&1 || { echo "MaxScale did not start"; tail -20 /var/log/maxscale/stdout.log; exit 1; }
EOF
}

# Runs one check inside the platform container. Prints PASS/FAIL and returns non-zero on failure.
check() {  # check <name> <command...>
    local name=$1; shift
    if output=$("$@" 2>&1)
    then
        echo "   PASS  $name"
        return 0
    else
        echo "   FAIL  $name"
        echo "$output" | head -5 | sed 's/^/         /'
        return 1
    fi
}

in_container() {  # in_container <container> <command...>
    docker exec "$1" sh -c "$2"
}

sql() {  # sql <port> <query>, through MaxScale
    docker run --rm --network host "$BACKEND_IMAGE" \
        mariadb -h 127.0.0.1 -P "$1" -u maxuser -pmaxpwd --skip-ssl -N -B -e "$2" 2>/dev/null
}

verify_platform() {  # verify_platform <platform>
    local platform=$1 image container pkgdir failures=0
    image=$(platform_image "$platform") || { echo "!! unknown platform $platform"; return 1; }

    local packages
    packages=$(platform_packages "$platform")
    if [ -z "$packages" ]
    then
        echo "-- $platform: no packages found, skipped"
        return 0
    fi

    echo "== $platform ($image)"
    pkgdir=$(mktemp -d)
    echo "$packages" | while read -r p; do cp "$p" "$pkgdir/"; done
    write_maxscale_config "$pkgdir/maxscale.cnf"
    write_container_script "$pkgdir/setup.sh"

    container="mxsverify-$platform"
    docker rm -f "$container" > /dev/null 2>&1
    # --init reaps the MaxScale process once it exits, so that the shutdown check does not
    # find a zombie.
    if ! docker run -d --name "$container" --network host --init \
        -v "$pkgdir:/pkgs:ro" -v "$pkgdir:/cnf:ro" "$image" sleep infinity > /dev/null
    then
        echo "   FAIL  cannot start $image"
        rm -rf "$pkgdir"
        return 1
    fi

    if ! docker exec "$container" sh /pkgs/setup.sh > "$pkgdir/setup.log" 2>&1
    then
        echo "   FAIL  install and start"
        tail -15 "$pkgdir/setup.log" | sed 's/^/         /'
        docker rm -f "$container" > /dev/null 2>&1
        rm -rf "$pkgdir"
        return 1
    fi
    echo "   PASS  install and start"

    # The monitor must see one master and one replica.
    check "monitor detects the topology" \
        in_container "$container" "maxctrl list servers --tsv | grep -q 'Master, Running' && maxctrl list servers --tsv | grep -q 'Slave, Running'" || failures=$((failures + 1))

    # Writes and reads through readwritesplit.
    check "DDL and DML through readwritesplit" \
        sql $RWSPLIT_PORT "CREATE DATABASE IF NOT EXISTS mxsverify;
            CREATE TABLE mxsverify.t (id INT PRIMARY KEY, v VARCHAR(16));
            INSERT INTO mxsverify.t VALUES (1, 'one'), (2, 'two');" || failures=$((failures + 1))

    check "the rows reached the replica" \
        test "$(sql $RWSPLIT_PORT 'SELECT COUNT(*) FROM mxsverify.t')" = "2" || failures=$((failures + 1))

    # Reads go to the replica, writes and transactions to the master.
    check "reads are routed to the replica" \
        test "$(sql $RWSPLIT_PORT 'SELECT @@server_id')" = "$REPLICA_ID" || failures=$((failures + 1))

    check "transactions are routed to the master" \
        test "$(sql $RWSPLIT_PORT 'BEGIN; SELECT @@server_id; COMMIT;')" = "$MASTER_ID" || failures=$((failures + 1))

    check "readconnroute reaches the replica" \
        test "$(sql $READCONN_PORT 'SELECT @@server_id')" = "$REPLICA_ID" || failures=$((failures + 1))

    check "REST API lists the servers" \
        in_container "$container" "curl -s -f -u admin:mariadb http://127.0.0.1:$ADMIN_PORT/v1/servers | grep -q server2" || failures=$((failures + 1))

    check "GUI is served" \
        in_container "$container" "curl -s -f -o /dev/null http://127.0.0.1:$ADMIN_PORT/" || failures=$((failures + 1))

    check "modules are loaded" \
        in_container "$container" "maxctrl list modules --tsv | grep -q mariadbmon && maxctrl list modules --tsv | grep -q readwritesplit" || failures=$((failures + 1))

    check "no errors in the log" \
        in_container "$container" "! grep -iE '  (error|alert) *:' /var/log/maxscale/stdout.log" || failures=$((failures + 1))

    check "shuts down cleanly" \
        in_container "$container" "pkill -TERM -x maxscale;
            for i in \$(seq 1 30); do pgrep -x maxscale > /dev/null || break; sleep 1; done;
            ! pgrep -x maxscale && grep -q 'MaxScale shutdown completed' /var/log/maxscale/stdout.log" \
        || failures=$((failures + 1))

    # Clean up for the next platform.
    sql $MASTER_PORT "DROP DATABASE IF EXISTS mxsverify" > /dev/null 2>&1
    docker rm -f "$container" > /dev/null 2>&1
    rm -rf "$pkgdir"

    if [ "$failures" -eq 0 ]
    then
        echo "   $platform OK"
        return 0
    fi
    echo "   $platform FAILED ($failures checks)"
    return 1
}

#main
parse_arguments "$@"
check_prerequisites

# Accept both the builder layout and a flat directory.
[ -d "$PACKAGES" ] || die "No such directory: $PACKAGES"

trap '[ "$KEEP" = 1 ] || stop_backends' EXIT

start_backends

failed=
for platform in $PLATFORMS
do
    verify_platform "$platform" || failed="$failed $platform"
done

echo
if [ -z "$failed" ]
then
    echo "All platforms passed."
    exit 0
fi
echo "Failed platforms:$failed"
exit 1
