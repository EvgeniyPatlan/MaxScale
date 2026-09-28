FROM redhat/ubi9-minimal

# Please don't remove old-style LABEL since it's needed for RedHat certification
LABEL name="Percona MaxScale" \
      vendor="Percona" \
      summary="Database proxy for MariaDB and MySQL" \
      description="MariaDB MaxScale is a database proxy that forwards database statements to one or more servers, using complex rules, a semantic understanding of the statements and the roles of the servers in the backend cluster. It provides load balancing and high availability transparently to the applications." \
      maintainer="Percona Development <info@percona.com>"

LABEL org.opencontainers.image.title="Percona MaxScale"
LABEL org.opencontainers.image.vendor="Percona"
LABEL org.opencontainers.image.description="MariaDB MaxScale is a database proxy that forwards \
database statements to one or more servers, using complex rules, a semantic understanding of the \
statements and the roles of the servers in the backend cluster."
LABEL org.opencontainers.image.license="GPL-2.0-or-later"
LABEL org.opencontainers.image.authors="info@percona.com"

# The component of repo.percona.com to install from, and the version to pin to.
ARG MAXSCALE_VERSION=23.08.12
ARG MAXSCALE_RELEASE=1
ARG REPO_COMPONENT=experimental

ENV MAXSCALE_VERSION=${MAXSCALE_VERSION}
LABEL org.label-schema.schema-version=${MAXSCALE_VERSION}
LABEL org.opencontainers.image.version=${MAXSCALE_VERSION}

# Check the repository package signature in a secure way.
RUN set -ex; \
    export GNUPGHOME="$(mktemp -d)"; \
    microdnf install -y findutils gnupg2 tar; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 4D1BB29D63D98E422B2113B19334A25F8507EFA5; \
    gpg --batch --export --armor 4D1BB29D63D98E422B2113B19334A25F8507EFA5 > ${GNUPGHOME}/PERCONA-PACKAGING-KEY; \
    rpmkeys --import ${GNUPGHOME}/PERCONA-PACKAGING-KEY; \
    curl -Lf -o /tmp/percona-release.rpm https://repo.percona.com/yum/percona-release-latest.noarch.rpm; \
    rpmkeys --checksig /tmp/percona-release.rpm; \
    rpm -i /tmp/percona-release.rpm; \
    rm -rf "$GNUPGHOME" /tmp/percona-release.rpm; \
    rpm --import /etc/pki/rpm-gpg/PERCONA-PACKAGING-KEY; \
    percona-release enable maxscale ${REPO_COMPONENT}

RUN set -ex; \
    microdnf install -y \
        percona-maxscale-${MAXSCALE_VERSION}-${MAXSCALE_RELEASE}.el9 \
        shadow-utils \
        procps-ng \
        hostname; \
    microdnf update -y glibc openssl-libs; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

# MaxScale runs as this user; the packages create it, so only the ownership is set here.
RUN set -ex; \
    install -o maxscale -g maxscale -m 0755 -d \
        /var/lib/maxscale /var/log/maxscale /var/cache/maxscale /run/maxscale \
        /var/lib/maxscale/maxscale.cnf.d; \
    mkdir -p /licenses; \
    cp /usr/share/maxscale/LICENSE.TXT /licenses/LICENSE.maxscale; \
    cp /usr/share/maxscale/GPL-2.0.txt /licenses/GPL-2.0.txt

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY maxscale.cnf /etc/maxscale.cnf
RUN chmod +x /usr/local/bin/entrypoint.sh; \
    chown maxscale:maxscale /etc/maxscale.cnf

# readwritesplit, readconnroute and the REST API / GUI
EXPOSE 4006 4008 8989

VOLUME ["/var/lib/maxscale", "/var/log/maxscale"]

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD maxctrl list servers > /dev/null || exit 1

USER maxscale
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["maxscale"]
