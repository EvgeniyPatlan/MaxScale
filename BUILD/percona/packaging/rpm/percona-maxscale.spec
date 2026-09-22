#
# Spec file for the Percona build of MariaDB MaxScale.
#
# @@VERSION@@ and @@RELEASE@@ are replaced by BUILD/percona/maxscale_builder.sh before the
# source RPM is built.
#
# Node.js (>= 16) and npm are needed to build MaxCtrl and the GUI. They are intentionally not
# listed in BuildRequires because the distribution packages are frequently too old; install them
# with BUILD/install_build_deps.sh, which fetches a suitable version.
#
# The build needs network access: FORCE_BUNDLE (on by default) downloads and statically builds
# jansson, microhttpd, pcre2, libssh and rdkafka, the LDI filter fetches libmarias3, and MaxCtrl
# and the GUI install their npm dependencies.
#

%global upstream_name maxscale
# Ship the binaries unstripped and the man pages uncompressed, like the CPack packages did.
# This also disables the debuginfo subpackage.
%global __os_install_post %{nil}
%global debug_package %{nil}

Name:           percona-maxscale
Version:        @@VERSION@@
Release:        @@RELEASE@@%{?dist}
Summary:        MaxScale - An intelligent database proxy

License:        BUSL-1.1
URL:            https://github.com/mariadb-corporation/MaxScale
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  cmake >= 3.16
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  git
BuildRequires:  bison
BuildRequires:  flex
BuildRequires:  pkgconfig
BuildRequires:  boost-devel
BuildRequires:  cyrus-sasl-devel
BuildRequires:  gnutls-devel
BuildRequires:  krb5-devel
BuildRequires:  libatomic
BuildRequires:  libcurl-devel
BuildRequires:  libgcrypt-devel
BuildRequires:  libicu-devel
BuildRequires:  libssh-devel
BuildRequires:  libuuid-devel
BuildRequires:  libxml2-devel
BuildRequires:  openssl-devel
BuildRequires:  pam-devel
BuildRequires:  pcre2-devel
BuildRequires:  jansson-devel
BuildRequires:  sqlite-devel
BuildRequires:  systemd-devel
BuildRequires:  tcl
BuildRequires:  unixODBC-devel
BuildRequires:  xz-devel
BuildRequires:  zlib-devel

Requires(post): systemd
Requires(post): shadow-utils
Requires(preun): systemd

# Drop-in replacement for the upstream MariaDB package of the same software.
Provides:       %{upstream_name} = %{version}-%{release}
Conflicts:      %{upstream_name}
Obsoletes:      %{upstream_name} < %{version}-%{release}

%description
MariaDB MaxScale is an intelligent proxy that allows forwarding of
database statements to one or more database servers using complex rules,
a semantic understanding of the database statements and the roles of
the various servers within the backend cluster of databases.
MaxScale is designed to provide load balancing and high availability
functionality transparently to the applications. In addition it provides
a highly scalable and flexible architecture, with plugin components to
support different protocols and routing decisions.

%package devel
Summary:        MaxScale plugin development headers
Requires:       %{name}%{?_isa} = %{version}-%{release}
Provides:       %{upstream_name}-devel = %{version}-%{release}
Conflicts:      %{upstream_name}-devel
Obsoletes:      %{upstream_name}-devel < %{version}-%{release}

%description devel
This package contains header files required for plugin module development for
MariaDB MaxScale. The source of MariaDB MaxScale is not required.

%prep
%autosetup -n %{name}-%{version}

%build
mkdir -p build
cd build
# The tarball has no .git directory; the commit ID travels in percona-build.properties.
maxscale_commit=$(sed -n 's/^COMMIT=//p' ../percona-build.properties 2>/dev/null)
# PACKAGE=Y selects the packaging layout: prefix /usr, and the systemd unit, ld.so
# configuration and init script are installed below %{_datadir}/maxscale for the
# postinst script to place, exactly as in a CPack build.
cmake .. \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_COLOR_MAKEFILE=N \
    -DPACKAGE=Y \
    -DPACKAGE_NAME=%{name} \
    -DTARGET_COMPONENT=core,devel \
    -DSKIP_CPACK=Y \
    -DBUILD_TESTS=N \
    -DMAXSCALE_COMMIT="${maxscale_commit}" \
    %{?extra_cmake_flags}
make %{?_smp_mflags}

%install
cd build
make install DESTDIR=%{buildroot}
cd ..

# CMake installs this only when TARGET_COMPONENT is exactly "core", so do it here.
install -D -m 0644 etc/maxscale.cnf.template %{buildroot}%{_sysconfdir}/maxscale.cnf.template

%post
sh %{_datadir}/maxscale/postinst

%preun
sh %{_datadir}/maxscale/prerm "$1"

%files
%{_sysconfdir}/maxscale.cnf.template
%{_bindir}/*
%{_libdir}/maxscale/
%{_datadir}/maxscale/
%{_mandir}/man1/*

%files devel
%{_includedir}/maxscale/

%changelog
* Mon Sep 21 2026 Percona Build Team <info@percona.com> - @@VERSION@@-@@RELEASE@@
- Percona build of MariaDB MaxScale @@VERSION@@
