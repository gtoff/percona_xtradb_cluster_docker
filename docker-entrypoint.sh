#!/bin/bash

#
# 
# Original work Copyright 2015 Patrick Galbraith 
# Modified work Copyright 2015 Giovanni Toffetti

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
# 
# I am not particularly fond of this script as I would prefer 
# using confd to do this ugly work. Confd functionality is being
# built into kubernetes as I write this which may replace this
# 
# also important here is that this script will work outside of 
# Kubernetes as long as the container is run with the correct 
# environment variables passed to replace discovery that 
# Kubernetes provides
# 
set -vx

HOSTNAME=`hostname`

if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
  # read DATADIR from the MySQL config
  DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
  
  if [ ! -d "$DATADIR/mysql" ]; then
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
      echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
      echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
      exit 1
    fi

    chown -R mysql:mysql "$DATADIR"

    echo 'Running mysql_install_db ...'
        mysql_install_db --datadir="$DATADIR"
        echo 'Finished mysql_install_db'

    
    # These statements _must_ be on individual lines, and _must_ end with
    # semicolons (no line breaks or comments are permitted).
    # TODO proper SQL escaping on ALL the things D:
    
    tempSqlFile='/tmp/mysql-first-time.sql'
    cat > "$tempSqlFile" <<-EOSQL
DELETE FROM mysql.user ;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
DROP DATABASE IF EXISTS test ;
EOSQL
    
    if [ "$MYSQL_DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
    fi
    
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$tempSqlFile"
      
      if [ "$MYSQL_DATABASE" ]; then
        echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$tempSqlFile"
      fi
    fi

    if [ -n "$GALERA_CLUSTER" -a "$GALERA_CLUSTER" = true ]; then
      WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
      if [ -z "$WSREP_SST_PASSWORD" ]; then
        echo >&2 'error: database is uninitialized and WSREP_SST_PASSWORD not set'
        echo >&2 '  Did you forget to add -e WSREP_SST_PASSWORD=xxx ?'
        exit 1
      fi

      sed -i -e "s|wsrep_sst_auth \= \"sstuser:changethis\"|wsrep_sst_auth = ${WSREP_SST_USER}:${WSREP_SST_PASSWORD}|" /etc/confd/mysql/templates/cluster.cnf.tmpl

      WSREP_NODE_ADDRESS=${COREOS_PRIVATE_IPV4}
      if [ -n "$WSREP_NODE_ADDRESS" ]; then
        sed -i -e "s|^#wsrep_node_address \= .*$|wsrep_node_address = ${WSREP_NODE_ADDRESS}|" /etc/confd/mysql/templates/cluster.cnf.tmpl
      fi

      
  
#      # Ok, now that we went through the trouble of building up a nice
#      # cluster address string, regex the conf file with that value 
#      if [ -n "$WSREP_CLUSTER_ADDRESS" -a "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
#        sed -i -e "s|wsrep_cluster_address \= gcomm://|wsrep_cluster_address = ${WSREP_CLUSTER_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
#      fi

      echo "CREATE USER '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';" >> "$tempSqlFile"
      echo "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost';" >> "$tempSqlFile"
    fi
    echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
    
    set -- "$@" --init-file="$tempSqlFile"
  fi
  
  
fi

export ETCD_ENDPOINT=${ETCD_ENDPOINT:-172.17.42.1:4001}

# Check if we are primary node (node_id=1)
if [ $GALERA_CLUSTER_NODE_ID == 1 ]; then
#   if [ -z "$WSREP_CLUSTER_ADDRESS" ]; then
    WSREP_CLUSTER_ADDRESS="gcomm://"
#   fi 
    cp /etc/confd/mysql/templates/cluster.cnf.tmpl /etc/mysql/conf.d/cluster.cnf
    sed -i -e "s|^wsrep_cluster_address \= .*$|wsrep_cluster_address = ${WSREP_CLUSTER_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
else
    # Try to make initial configuration every 5 seconds until successful
    until confd -verbose -debug -onetime -node $ETCD_ENDPOINT -config-file /etc/confd/mysql/conf.d/ zurmo_galera_cluster.toml; do
      echo "[mysql-cluster] waiting for confd to create initial mysql-cluster configuration."
      sleep 5
done
fi 

echo "[mysql-cluster] mysql-cluster configuration is now:"
cat /etc/mysql/conf.d/cluster.cnf

chmod +x /restart_mysql.sh
exec "mysqld_safe"

# FIXME: I am currently disabling discovery because I still do not know how to make node 1 restart and join an existing cluster
## Put a continual polling `confd` process into the background to watch
## for changes every 10 seconds
#confd -interval 10 -node $ETCD_ENDPOINT -config-file /etc/confd/mysql/conf.d/zurmo_galera_cluster.toml &
#echo "[mysql-cluster] confd is now monitoring etcd for changes"

tail -f /var/log/mysql.log

