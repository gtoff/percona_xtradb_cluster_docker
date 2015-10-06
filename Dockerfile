FROM ubuntu:trusty

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

ENV PERCONA_XTRADB_VERSION 5.6
ENV MYSQL_VERSION 5.6
ENV TERM linux

# gpg: key 5072E1F5: public key "MySQL Release Engineering <mysql-build@oss.oracle.com>" imported

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
                echo percona-server-server-5.6 percona-server-server/data-dir select ''; \
                echo percona-server-server-5.6 percona-server-server/root_password password ''; \
        } | debconf-set-selections \
        && apt-key adv --keyserver keys.gnupg.net --recv-keys 1C4CBDCDCD2EFD2A \
        && echo "deb http://repo.percona.com/apt trusty main" > /etc/apt/sources.list.d/percona.list \
        && echo "deb-src http://repo.percona.com/apt trusty main" >> /etc/apt/sources.list.d/percona.list \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y perl --no-install-recommends \
        && apt-get update && DEBIAN_FRONTEND=nointeractive apt-get install -y percona-xtradb-cluster-client-"${MYSQL_VERSION}" \ 
           percona-xtradb-cluster-common-"${MYSQL_VERSION}" percona-xtradb-cluster-server-"${MYSQL_VERSION}" \
        && rm -rf /var/lib/apt/lists/* \
        && rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql && chown -R mysql:mysql /var/lib/mysql \
        && apt-get autoremove -y

VOLUME /var/lib/mysql

COPY my.cnf /etc/mysql/my.cnf
COPY cluster.cnf /tmp/cluster.cnf
# need random.sh because otherwise, ENV $RANDOM is not set
#COPY random.sh /tmp/random.sh
#RUN /tmp/random.sh
 

COPY docker-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 3306 4444 4567 4568
CMD ["mysqld"]
