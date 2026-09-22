#!/bin/bash
#
# Percona build wrapper for MariaDB MaxScale.
#
# RPMs and DEBs are built from the packaging in BUILD/percona/packaging (spec and debian
# directory) so that the published source packages rebuild the shipped binaries. The binary
# tarball uses MaxScale's own CPack packaging. Everything runs inside the OS the script is
# started in, normally a Docker container of the target distribution.
#
# The options follow the stage layout of the Percona Jenkins pipelines:
#
#   --install_deps -> --get_sources -> --build_src_rpm -> --build_rpm
#                                   \-> --build_source_deb -> --build_deb
#                                   \-> --build_tarball
#
# Every stage reads its input from, and writes its output to, both the build
# directory (--builddir) and the current directory, so consecutive stages can run
# on different machines with the current directory stashed in between.
#

shell_quote_string() {
    echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

usage() {
    cat <<EOF
Usage: $0 --builddir=DIR [OPTIONS]
    --builddir=DIR          Absolute path to an existing directory where all work is done (required)
    --install_deps=1|git    1: install all build dependencies, git: only what --get_sources needs (needs root)
    --get_sources=1         Clone the MaxScale repository and create the source tarball
    --build_src_rpm=1       Build the source RPM from the source tarball
    --build_source_deb=1    Build the source DEB (.dsc) from the source tarball
    --build_rpm=1           Build RPM packages from the source RPM
    --build_deb=1           Build DEB packages from the source DEB
    --build_tarball=1       Build a binary tarball from the source tarball
    --repo=URL              MaxScale git repository (default: ${GIT_REPO})
    --branch=REF            Branch or tag to build (default: ${BRANCH})
    --version=X.Y.Z         Expected MaxScale version, must match the version in the sources
    --rpm_release=N         RPM release (default: ${RPM_RELEASE})
    --deb_release=N         DEB release (default: ${DEB_RELEASE})
    --package_name=NAME     Package name (default: ${PACKAGE_NAME})
    --build_tests=1         Also build and run the unit tests
    --help                  Show this message
Example: $0 --builddir=/tmp/build --install_deps=1 --get_sources=1 --build_deb=1
EOF
    exit 1
}

append_arg_to_args() {
    args="$args "$(shell_quote_string "$1")
}

parse_arguments() {
    pick_args=
    if test "$1" = PICK-ARGS-FROM-ARGV
    then
        pick_args=1
        shift
    fi

    for arg do
        val=$(echo "$arg" | sed -e 's;^--[^=]*=;;')
        case "$arg" in
            --builddir=*) WORKDIR="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_source_deb=*) SDEB="$val" ;;
            --build_rpm=*) RPM="$val" ;;
            --build_deb=*) DEB="$val" ;;
            --build_tarball=*) BTARBALL="$val" ;;
            --repo=*) GIT_REPO="$val" ;;
            --branch=*) BRANCH="$val" ;;
            --version=*) VERSION="$val" ;;
            --rpm_release=*) RPM_RELEASE="$val" ;;
            --deb_release=*) DEB_RELEASE="$val" ;;
            --package_name=*) PACKAGE_NAME="$val" ;;
            --build_tests=*) BUILD_TESTS="$val" ;;
            --help) usage ;;
            *)
                if test -n "$pick_args"
                then
                    append_arg_to_args "$arg"
                fi
                ;;
        esac
    done
}

die() {
    echo >&2 "ERROR: $*"
    exit 1
}

check_workdir() {
    if [ -z "$WORKDIR" ]
    then
        usage
    elif [ "x$WORKDIR" = "x$CURDIR" ]
    then
        die "Current directory cannot be used for building!"
    elif ! test -d "$WORKDIR"
    then
        die "$WORKDIR is not a directory."
    fi
}

# Prints one field of /etc/os-release. Read in a subshell: the file defines VERSION and NAME.
os_release_field() {
    (. /etc/os-release && eval "echo \"\${$1}\"")
}

get_system() {
    local os_like version_id
    OS_ID=$(os_release_field ID)
    os_like=$(os_release_field ID_LIKE)
    version_id=$(os_release_field VERSION_ID)
    ARCH=$(uname -m)
    case " ${OS_ID} ${os_like} " in
        *" debian "*|*" ubuntu "*)
            OS="deb"
            OS_NAME=$(os_release_field VERSION_CODENAME)
            ;;
        *" rhel "*|*" fedora "*|*" centos "*)
            OS="rpm"
            if [ "${OS_ID}" = "amzn" ]
            then
                RHEL=""
                OS_NAME="amzn${version_id}"
            else
                RHEL="${version_id%%.*}"
                OS_NAME="el${RHEL}"
            fi
            ;;
        *)
            die "Unsupported distribution: $(os_release_field PRETTY_NAME)"
            ;;
    esac
    NCPU=$(nproc)
}

enable_rpm_extra_repos() {
    yum -y install dnf-plugins-core || die "Failed to install dnf-plugins-core"
    case "${OS_ID}" in
        ol)
            yum -y install "oracle-epel-release-el${RHEL}" || die "Failed to install EPEL"
            dnf config-manager --set-enabled "ol${RHEL}_codeready_builder" || die "Failed to enable CodeReady Builder"
            ;;
        amzn)
            # No EPEL on Amazon Linux; the upstream dependency script installs what exists.
            ;;
        *)
            yum -y install epel-release || die "Failed to install EPEL"
            if [ "${RHEL}" = 8 ]
            then
                dnf config-manager --set-enabled powertools || die "Failed to enable PowerTools"
            else
                dnf config-manager --set-enabled crb || die "Failed to enable CRB"
            fi
            ;;
    esac
}

version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

verify_build_tools() {
    for tool in git cmake make gcc g++ node npm
    do
        command -v "$tool" > /dev/null || die "Build tool '$tool' is missing after dependency installation"
    done

    if [ "x$OS" = "xrpm" ]
    then
        for tool in rpmbuild rpmspec
        do
            command -v "$tool" > /dev/null || die "Packaging tool '$tool' is missing"
        done
    else
        for tool in dpkg-buildpackage dpkg-source dpkg-shlibdeps dh dch fakeroot lsb_release
        do
            command -v "$tool" > /dev/null || die "Packaging tool '$tool' is missing"
        done
    fi

    local cmake_version
    cmake_version=$(cmake --version | awk '/cmake version/ {print $3}')
    version_ge "$cmake_version" "$CMAKE_VERSION" || die "CMake $cmake_version is older than $CMAKE_VERSION"
}

install_deps() {
    if [ "$INSTALL" = 0 ]
    then
        echo "Dependencies will not be installed"
        return
    fi
    if [ "$(id -u)" -ne 0 ]
    then
        die "It is not possible to install dependencies. Please run as root"
    fi

    if [ "x$OS" = "xrpm" ]
    then
        yum -y install git tar gzip findutils which procps-ng || die "Failed to install base packages"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || die "apt-get update failed"
        apt-get -y install git ca-certificates curl wget tar gzip lsb-release procps \
            || die "Failed to install base packages"
    fi

    if [ "$INSTALL" = "git" ]
    then
        return
    fi

    if [ "x$OS" = "xrpm" ]
    then
        enable_rpm_extra_repos
    fi

    # Use the dependency scripts of the exact sources being built.
    local deps_src="${WORKDIR}/deps-src"
    rm -rf "$deps_src"
    # A shallow clone only works for branches and tags; fall back to a full clone for commit hashes.
    if ! git clone --depth 1 --branch "$BRANCH" "$GIT_REPO" "$deps_src"
    then
        rm -rf "$deps_src"
        git clone "$GIT_REPO" "$deps_src" && git -C "$deps_src" checkout "$BRANCH" \
            || die "Failed to clone $GIT_REPO ($BRANCH) for the dependency scripts"
    fi
    bash -x "$deps_src/BUILD/install_build_deps.sh" "$CMAKE_VERSION" "$NODE_MAJOR"
    rm -rf "$deps_src"

    # Tools for building the source and binary packages, which the upstream script does not install.
    if [ "x$OS" = "xrpm" ]
    then
        yum -y install rpm-build rpmdevtools || die "Failed to install the RPM packaging tools"
    else
        apt-get -y install debhelper devscripts fakeroot dpkg-dev \
            || die "Failed to install the DEB packaging tools"
    fi

    verify_build_tools
}

get_source_version() {
    local srcdir=$1 vfile major minor patch
    vfile=$(sed -n 's|^include(${CMAKE_SOURCE_DIR}/\(.*\))|\1|p' "$srcdir/VERSION.cmake")
    [ -f "$srcdir/$vfile" ] || die "Cannot find the version file referenced by $srcdir/VERSION.cmake"
    major=$(sed -n 's/^set(MAXSCALE_VERSION_MAJOR "\([0-9]*\)".*/\1/p' "$srcdir/$vfile")
    minor=$(sed -n 's/^set(MAXSCALE_VERSION_MINOR "\([0-9]*\)".*/\1/p' "$srcdir/$vfile")
    patch=$(sed -n 's/^set(MAXSCALE_VERSION_PATCH "\([0-9]*\)".*/\1/p' "$srcdir/$vfile")
    echo "${major}.${minor}.${patch}"
}

get_sources() {
    if [ "$SOURCE" = 0 ]
    then
        echo "Sources will not be downloaded"
        return
    fi

    cd "$WORKDIR" || die "Cannot enter $WORKDIR"
    rm -rf maxscale-clone
    git clone "$GIT_REPO" maxscale-clone || die "There were some issues during repo cloning. Please retry one more time"
    cd maxscale-clone || die "Cannot enter the cloned repository"
    git checkout "$BRANCH" || die "Cannot check out $BRANCH"
    git submodule update --init --recursive || die "Cannot initialize git submodules"

    local commit revision src_version branch_path
    commit=$(git rev-parse HEAD)
    revision=$(git rev-parse --short HEAD)
    src_version=$(get_source_version .)
    if [ -n "$VERSION" ] && [ "$VERSION" != "$src_version" ]
    then
        die "Requested version $VERSION does not match the source version $src_version"
    fi
    VERSION="$src_version"
    cd "$WORKDIR" || die "Cannot enter $WORKDIR"

    PRODUCT_FULL="${PACKAGE_NAME}-${VERSION}"
    rm -rf "$PRODUCT_FULL"
    mv maxscale-clone "$PRODUCT_FULL"

    # The packaging has to sit where rpmbuild and dpkg-buildpackage expect it.
    cp -a "$PRODUCT_FULL/BUILD/percona/packaging/rpm" "$PRODUCT_FULL/rpm"
    cp -a "$PRODUCT_FULL/BUILD/percona/packaging/debian" "$PRODUCT_FULL/debian"

    branch_path=$(echo "$BRANCH" | tr '/' '_')
    {
        echo "PRODUCT=${PACKAGE_NAME}"
        echo "VERSION=${VERSION}"
        echo "PRODUCT_FULL=${PRODUCT_FULL}"
        echo "PACKAGE_NAME=${PACKAGE_NAME}"
        echo "REVISION=${revision}"
        echo "COMMIT=${commit}"
        echo "RPM_RELEASE=${RPM_RELEASE}"
        echo "DEB_RELEASE=${DEB_RELEASE}"
        echo "GIT_REPO=${GIT_REPO}"
        echo "BRANCH_NAME=${BRANCH}"
        echo "UPLOAD=UPLOAD/experimental/BUILDS/${PACKAGE_NAME}/${PRODUCT_FULL}/${branch_path}/${revision}/"
    } > maxscale.properties
    # The tarball has no .git directory, so the commit ID travels inside it.
    cp maxscale.properties "$PRODUCT_FULL/percona-build.properties"

    tar --owner=0 --group=0 --exclude=.git -czf "${PRODUCT_FULL}.tar.gz" "$PRODUCT_FULL" \
        || die "Failed to create the source tarball"

    mkdir -p "$WORKDIR/source_tarball" "$CURDIR/source_tarball"
    cp "${PRODUCT_FULL}.tar.gz" "$WORKDIR/source_tarball/"
    cp "${PRODUCT_FULL}.tar.gz" "$CURDIR/source_tarball/"
    cat maxscale.properties
}

# Extracts the source tarball into $WORKDIR and sets SRC_DIR, VERSION and COMMIT.
prepare_source() {
    local tarfile
    tarfile=$(find "$WORKDIR/source_tarball" "$CURDIR/source_tarball" -name "${PACKAGE_NAME}-*.tar.gz" 2>/dev/null | sort | tail -n1)
    [ -n "$tarfile" ] || die "There is no source tarball for ${PACKAGE_NAME}; create it with --get_sources=1"

    cd "$WORKDIR" || die "Cannot enter $WORKDIR"
    TARFILE="$tarfile"
    SRC_DIR="$WORKDIR/$(basename "$tarfile" .tar.gz)"
    rm -rf "$SRC_DIR"
    tar xzf "$tarfile" || die "Failed to extract $tarfile"
    [ -f "$SRC_DIR/percona-build.properties" ] || die "$tarfile was not created by this script"

    local src_version
    src_version=$(get_source_version "$SRC_DIR")
    if [ -n "$VERSION" ] && [ "$VERSION" != "$src_version" ]
    then
        die "Requested version $VERSION does not match the source version $src_version"
    fi
    VERSION="$src_version"
    COMMIT=$(sed -n 's/^COMMIT=//p' "$SRC_DIR/percona-build.properties")
}

# Configures, builds and packages. Arguments are extra CMake options.
cmake_build_package() {
    local build_dir="$WORKDIR/build"
    local build_tests=N
    [ "$BUILD_TESTS" = 1 ] && build_tests=Y

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir" || die "Cannot enter $build_dir"

    cmake "$SRC_DIR" -DCMAKE_COLOR_MAKEFILE=N -DPACKAGE=Y -DPACKAGE_NAME="$PACKAGE_NAME" \
        -DMAXSCALE_COMMIT="$COMMIT" -DBUILD_TESTS="$build_tests" "$@" \
        || die "CMake configuration failed"

    # Without libsystemd MaxScale sends no watchdog notifications and systemd
    # kills it because of WatchdogSec in maxscale.service.
    if grep -q '^HAVE_SYSTEMD:FILEPATH=.*NOTFOUND' CMakeCache.txt
    then
        die "libsystemd was not found; the packages would not work under systemd"
    fi

    make -j"$NCPU" || die "Build failed"

    if [ "$BUILD_TESTS" = 1 ]
    then
        ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=abort_on_error=1 \
            ctest --timeout 120 --output-on-failure -j"$NCPU" || die "Unit tests failed"
    fi

    # dpkg-shlibdeps must be able to resolve MaxScale's own core library.
    LD_LIBRARY_PATH="$build_dir/server/core" make package || die "Packaging failed"
}

# Copies files matching an absolute glob to <dir> in both $WORKDIR and $CURDIR.
collect_output() {
    local dir=$1 pattern=$2 found=0 file
    mkdir -p "$WORKDIR/$dir" "$CURDIR/$dir"
    for file in $pattern
    do
        [ -f "$file" ] || continue
        cp "$file" "$WORKDIR/$dir/"
        cp "$file" "$CURDIR/$dir/"
        found=1
    done
    [ "$found" = 1 ] || die "No files matching $pattern were produced"
    ls -l "$CURDIR/$dir"
}

# The packaging carries the package name, so a different one would need packaging changes.
check_package_name() {
    [ "$PACKAGE_NAME" = "$PACKAGING_NAME" ] \
        || die "--package_name=$PACKAGE_NAME does not match the packaging in BUILD/percona/packaging ($PACKAGING_NAME)"
}

# Creates $WORKDIR/rpmbuild and puts the spec and the source tarball in it.
prepare_rpmbuild_tree() {
    RPMBUILD_DIR="$WORKDIR/rpmbuild"
    rm -rf "$RPMBUILD_DIR"
    mkdir -p "$RPMBUILD_DIR"/{SOURCES,SPECS,BUILD,BUILDROOT,SRPMS,RPMS}
}

build_src_rpm() {
    if [ "$SRPM" = 0 ]
    then
        echo "Source RPM will not be created"
        return
    fi
    [ "x$OS" = "xrpm" ] || die "It is not possible to build a source rpm here"

    check_package_name
    prepare_source
    prepare_rpmbuild_tree

    local spec="$RPMBUILD_DIR/SPECS/${PACKAGE_NAME}.spec"
    cp "$SRC_DIR/rpm/${PACKAGE_NAME}.spec" "$spec" || die "The sources contain no spec file"
    sed -i "s:@@VERSION@@:${VERSION}:g; s:@@RELEASE@@:${RPM_RELEASE}:g" "$spec"
    cp "$TARFILE" "$RPMBUILD_DIR/SOURCES/" || die "Failed to copy the source tarball"

    # .generic keeps the source RPM independent of the distribution it was built on.
    rpmbuild -bs --define "_topdir ${RPMBUILD_DIR}" --define "dist .generic" "$spec" \
        || die "Failed to build the source RPM"

    collect_output srpm "${RPMBUILD_DIR}/SRPMS/*.src.rpm"
    rpm -qpi "$CURDIR"/srpm/*.src.rpm
}

build_rpm() {
    if [ "$RPM" = 0 ]
    then
        echo "RPM will not be created"
        return
    fi
    [ "x$OS" = "xrpm" ] || die "It is not possible to build rpm here"

    check_package_name
    local src_rpm
    src_rpm=$(find "$WORKDIR/srpm" "$CURDIR/srpm" -name "${PACKAGE_NAME}-*.src.rpm" 2>/dev/null | sort | tail -n1)
    [ -n "$src_rpm" ] || die "There is no source RPM; create it with --build_src_rpm=1"

    prepare_rpmbuild_tree
    rpmbuild --rebuild --define "_topdir ${RPMBUILD_DIR}" --define "dist .${OS_NAME}" "$src_rpm" \
        || die "Failed to build the RPM packages"

    # The repository upload expects <name>-<version>-<release>.<el8|el9|amzn2023>.<arch>.rpm
    collect_output rpm "${RPMBUILD_DIR}/RPMS/*/${PACKAGE_NAME}*-${VERSION}-${RPM_RELEASE}.${OS_NAME}.${ARCH}.rpm"
    rpm -qpi "$CURDIR"/rpm/*.rpm
    rpm -qp --provides --conflicts --obsoletes "$CURDIR"/rpm/*.rpm
}

build_source_deb() {
    if [ "$SDEB" = 0 ]
    then
        echo "Source DEB will not be created"
        return
    fi
    [ "x$OS" = "xdeb" ] || die "It is not possible to build a source deb here"

    check_package_name
    prepare_source

    cd "$WORKDIR" || die "Cannot enter $WORKDIR"
    cp "$TARFILE" "${PACKAGE_NAME}_${VERSION}.orig.tar.gz" || die "Failed to create the orig tarball"

    cd "$SRC_DIR" || die "Cannot enter $SRC_DIR"
    dch --force-bad-version --distribution unstable --force-distribution \
        -v "${VERSION}-${DEB_RELEASE}" "Percona build of MariaDB MaxScale ${VERSION}" \
        || die "Failed to update debian/changelog"
    # -d: the build dependencies are only needed when the binaries are built.
    dpkg-buildpackage -S -us -uc -d || die "Failed to build the source DEB"

    cd "$WORKDIR" || die "Cannot enter $WORKDIR"
    collect_output source_deb "${WORKDIR}/${PACKAGE_NAME}_${VERSION}-${DEB_RELEASE}*"
    collect_output source_deb "${WORKDIR}/${PACKAGE_NAME}_${VERSION}.orig.tar.gz"
}

build_deb() {
    if [ "$DEB" = 0 ]
    then
        echo "DEB will not be created"
        return
    fi
    [ "x$OS" = "xdeb" ] || die "It is not possible to build deb here"

    check_package_name
    local dsc src_dir
    cd "$WORKDIR" || die "Cannot enter $WORKDIR"
    for file in "$CURDIR"/source_deb/* "$WORKDIR"/source_deb/*
    do
        [ -f "$file" ] && cp "$file" "$WORKDIR/"
    done
    dsc=$(find "$WORKDIR" -maxdepth 1 -name "${PACKAGE_NAME}_*.dsc" | sort | tail -n1)
    [ -n "$dsc" ] || die "There is no source DEB; create it with --build_source_deb=1"

    src_dir="$WORKDIR/${PACKAGE_NAME}-${VERSION}"
    rm -rf "$src_dir"
    dpkg-source -x "$dsc" "$src_dir" || die "Failed to extract $dsc"

    cd "$src_dir" || die "Cannot enter $src_dir"
    # The codename in the release makes the package unique per distribution.
    dch -b -m --force-bad-version --distribution "$OS_NAME" --force-distribution \
        -v "${VERSION}-${DEB_RELEASE}.${OS_NAME}" "Build for ${OS_NAME}" \
        || die "Failed to update debian/changelog"
    dpkg-buildpackage -rfakeroot -uc -us -b || die "Failed to build the DEB packages"

    # The repository upload expects <name>_<version>-<release>.<codename>_<arch>.deb
    collect_output deb "${WORKDIR}/${PACKAGE_NAME}*_${VERSION}-${DEB_RELEASE}.${OS_NAME}_*.deb"
    for deb in "$CURDIR"/deb/*.deb
    do
        dpkg-deb -I "$deb"
    done
}

build_tarball() {
    if [ "$BTARBALL" = 0 ]
    then
        echo "Binary tarball will not be created"
        return
    fi

    prepare_source
    local release="$RPM_RELEASE"
    [ "x$OS" = "xdeb" ] && release="$DEB_RELEASE"
    local name="${PACKAGE_NAME}-${VERSION}-${release}.${OS_NAME}.${ARCH}"
    cmake_build_package -DTARBALL=Y -DDISTRIB_SUFFIX="$OS_NAME" -DTARBALL_FILE_NAME="$name"
    collect_output tarball "${WORKDIR}/build/${name}.tar.gz"
}

#main
CURDIR=$(pwd)
args=
WORKDIR=
INSTALL=0
SOURCE=0
SRPM=0
SDEB=0
RPM=0
DEB=0
BTARBALL=0
BUILD_TESTS=0
GIT_REPO="https://github.com/EvgeniyPatlan/MaxScale.git"
BRANCH="percona-23.08"
VERSION=
RPM_RELEASE=1
DEB_RELEASE=1
PACKAGE_NAME="percona-maxscale"
# The name the spec file and debian/control are written for.
PACKAGING_NAME="percona-maxscale"
# Used by dch for the debian/changelog entries.
export DEBEMAIL="${DEBEMAIL:-info@percona.com}"
export DEBFULLNAME="${DEBFULLNAME:-Percona Build Team}"
# Packaging needs CMake 3.25.1 or newer (Documentation/Getting-Started/Building-MaxScale-from-Source-Code.md)
CMAKE_VERSION="3.25.1"
NODE_MAJOR=16
parse_arguments PICK-ARGS-FROM-ARGV "$@"

check_workdir
get_system
install_deps
get_sources
build_src_rpm
build_source_deb
build_rpm
build_deb
build_tarball
