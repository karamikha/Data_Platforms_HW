#!/usr/bin/env bash
set -euo pipefail
umask 077

EDGE_HOST="team-06-en"
HADOOP_HOME="/opt/hadoop"
JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
HIVE_VERSION="4.0.0-alpha-2"
HIVE_DIR="/opt/apache-hive-${HIVE_VERSION}-bin"
HIVE_HOME="/opt/hive"
WAREHOUSE="/user/hive/warehouse"
PG_DB="metastore"
PG_USER="hive"
HIVE_USER="hadoop"

IFS= read -r -s -p 'Пароль PostgreSQL для пользователя hive: ' PG_PASS
printf '\n'
IFS= read -r -s -p 'Повторите пароль: ' PG_PASS2
printf '\n'
[[ "$PG_PASS" == "$PG_PASS2" ]] || { echo 'Пароли не совпадают' >&2; exit 1; }
unset PG_PASS2

PG_PASS_XML=$PG_PASS
PG_PASS_XML=${PG_PASS_XML//&/\&amp;}
PG_PASS_XML=${PG_PASS_XML//</\&lt;}
PG_PASS_XML=${PG_PASS_XML//>/\&gt;}
PG_PASS_XML=${PG_PASS_XML//\"/\&quot;}
PG_PASS_XML=${PG_PASS_XML//\'/\&apos;}

WORK=$(mktemp -d "$PWD/hive-config.XXXXXXXX")
echo "Рабочий каталог: $WORK"

sudo -n apt-get update
sudo -n apt-get install -y curl ca-certificates postgresql
sudo -n systemctl enable --now postgresql

sudo -n -u postgres psql -v ON_ERROR_STOP=1 -v "pass=$PG_PASS" <<SQL
CREATE USER $PG_USER WITH PASSWORD :'pass';
CREATE DATABASE $PG_DB OWNER $PG_USER;
SQL
sudo -n -u postgres psql -v ON_ERROR_STOP=1 -d "$PG_DB" <<SQL
GRANT ALL ON SCHEMA public TO $PG_USER;
ALTER SCHEMA public OWNER TO $PG_USER;
SQL

mkdir -p "$HOME/hive-download"
ARCHIVE="$HOME/hive-download/apache-hive-${HIVE_VERSION}-bin.tar.gz"
curl -fsSL --retry 3 -o "$ARCHIVE" \
  "https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz"
curl -fsSL --retry 3 -o "$ARCHIVE.sha256" \
  "https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz.sha256"
DIGEST=$(tr -d ' \n\r\t' < "$ARCHIVE.sha256" | grep -Eo '[[:xdigit:]]{64}' | head -1)
printf '%s  %s\n' "$DIGEST" "$ARCHIVE" | sha256sum --status -c -

JDBC="$HOME/hive-download/postgresql-42.7.4.jar"
curl -fsSL --retry 3 -o "$JDBC" \
  "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar"

sudo -n tar -xzf "$ARCHIVE" -C /opt --no-same-owner
sudo -n ln -sfn "$HIVE_DIR" "$HIVE_HOME"
sudo -n install -m 644 "$JDBC" "$HIVE_HOME/lib/postgresql-42.7.4.jar"
COLL="$HOME/hive-download/commons-collections-3.2.2.jar"
curl -fsSL --retry 3 -o "$COLL" \
  "https://repo1.maven.org/maven2/commons-collections/commons-collections/3.2.2/commons-collections-3.2.2.jar"
sudo -n install -m 644 "$COLL" "$HIVE_HOME/lib/commons-collections-3.2.2.jar"
sudo -n install -m 644 "$COLL" "$HADOOP_HOME/share/hadoop/common/lib/commons-collections-3.2.2.jar"
sudo -n install -d -o "$HIVE_USER" -g "$HIVE_USER" -m 750 /var/log/hive
sudo -n chown -R "$HIVE_USER:$HIVE_USER" "$HIVE_HOME/conf"

cat > "$WORK/hive-env.sh" <<ENV
export JAVA_HOME=$JAVA_HOME
export HADOOP_HOME=$HADOOP_HOME
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HIVE_HOME=$HIVE_HOME
export HIVE_CONF_DIR=$HIVE_HOME/conf
export PATH=\$PATH:\$HIVE_HOME/bin
export HADOOP_HEAPSIZE=512
export HIVE_LOG_DIR=/var/log/hive
export HIVE_PID_DIR=/var/run/hive
ENV

cat > "$WORK/hive-site.xml" <<XML
<configuration>
<property>
  <name>javax.jdo.option.ConnectionURL</name>
  <value>jdbc:postgresql://localhost:5432/$PG_DB</value>
</property>
<property>
  <name>javax.jdo.option.ConnectionDriverName</name>
  <value>org.postgresql.Driver</value>
</property>
<property>
  <name>javax.jdo.option.ConnectionUserName</name>
  <value>$PG_USER</value>
</property>
<property>
  <name>javax.jdo.option.ConnectionPassword</name>
  <value>$PG_PASS_XML</value>
</property>
<property>
  <name>hive.metastore.uris</name>
  <value>thrift://$EDGE_HOST:9083</value>
</property>
<property>
  <name>hive.metastore.warehouse.dir</name>
  <value>$WAREHOUSE</value>
</property>
<property>
  <name>hive.metastore.schema.verification</name>
  <value>true</value>
</property>
<property>
  <name>datanucleus.autoCreateSchema</name>
  <value>false</value>
</property>
<property>
  <name>hive.server2.thrift.bind.host</name>
  <value>0.0.0.0</value>
</property>
<property>
  <name>hive.server2.thrift.port</name>
  <value>10000</value>
</property>
<property>
  <name>hive.server2.authentication</name>
  <value>NONE</value>
</property>
<property>
  <name>hive.server2.enable.doAs</name>
  <value>false</value>
</property>
<property>
  <name>hive.security.authorization.enabled</name>
  <value>false</value>
</property>
<property>
  <name>hive.metastore.event.db.notification.api.auth</name>
  <value>false</value>
</property>
<property>
  <name>metastore.event.db.notification.api.auth</name>
  <value>false</value>
</property>
<property>
  <name>hive.notification.event.poll.interval</name>
  <value>0s</value>
</property>
</configuration>
XML

cat > "$WORK/metastore-site.xml" <<XML
<configuration>
<property>
  <name>metastore.event.db.notification.api.auth</name>
  <value>false</value>
</property>
</configuration>
XML

sudo -n install -m 644 "$WORK/hive-env.sh" "$HIVE_HOME/conf/hive-env.sh"
sudo -n install -o "$HIVE_USER" -g "$HIVE_USER" -m 600 "$WORK/hive-site.xml" "$HIVE_HOME/conf/hive-site.xml"
sudo -n install -o "$HIVE_USER" -g "$HIVE_USER" -m 600 "$WORK/metastore-site.xml" "$HIVE_HOME/conf/metastore-site.xml"
sudo -n install -d -o "$HIVE_USER" -g "$HIVE_USER" -m 755 /var/run/hive
sudo -n chown -R "$HIVE_USER:$HIVE_USER" "$HIVE_HOME/conf"

sudo -n -u "$HIVE_USER" "$HADOOP_HOME/bin/hdfs" dfsadmin -safemode wait
sudo -n -u "$HIVE_USER" "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /tmp /tmp/hive "$WAREHOUSE" /user/"$HIVE_USER" /input/events
sudo -n -u "$HIVE_USER" "$HADOOP_HOME/bin/hdfs" dfs -chmod g+w /tmp "$WAREHOUSE"
sudo -n -u "$HIVE_USER" "$HADOOP_HOME/bin/hdfs" dfs -chmod -R 777 /tmp/hive

sudo -n -u "$HIVE_USER" env JAVA_HOME="$JAVA_HOME" HADOOP_HOME="$HADOOP_HOME" HIVE_HOME="$HIVE_HOME" HIVE_CONF_DIR="$HIVE_HOME/conf" \
  "$HIVE_HOME/bin/schematool" -dbType postgres -initSchema

cat > "$WORK/hive-metastore.service" <<UNIT
[Unit]
Description=Hive Metastore
Wants=network-online.target postgresql.service
After=network-online.target postgresql.service
[Service]
Type=simple
User=$HIVE_USER
Group=$HIVE_USER
Environment=JAVA_HOME=$JAVA_HOME
Environment=HADOOP_HOME=$HADOOP_HOME
Environment=HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
Environment=HIVE_HOME=$HIVE_HOME
Environment=HIVE_CONF_DIR=$HIVE_HOME/conf
Environment=HIVE_PID_DIR=/var/run/hive
Environment=HIVE_LOG_DIR=/var/log/hive
ExecStart=$HIVE_HOME/bin/hive --service metastore
Restart=on-failure
RestartSec=10
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT

cat > "$WORK/hiveserver2.service" <<UNIT
[Unit]
Description=HiveServer2
Wants=network-online.target hive-metastore.service
After=network-online.target hive-metastore.service
[Service]
Type=simple
User=$HIVE_USER
Group=$HIVE_USER
Environment=JAVA_HOME=$JAVA_HOME
Environment=HADOOP_HOME=$HADOOP_HOME
Environment=HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
Environment=HIVE_HOME=$HIVE_HOME
Environment=HIVE_CONF_DIR=$HIVE_HOME/conf
Environment=HIVE_PID_DIR=/var/run/hive
Environment=HIVE_LOG_DIR=/var/log/hive
ExecStart=$HIVE_HOME/bin/hive --service hiveserver2
Restart=on-failure
RestartSec=10
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT

sudo -n install -m 644 "$WORK/hive-metastore.service" /etc/systemd/system/hive-metastore.service
sudo -n install -m 644 "$WORK/hiveserver2.service" /etc/systemd/system/hiveserver2.service
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now hive-metastore
ready=0
for _ in $(seq 1 60); do
  if ss -ltn | grep -q ':9083 '; then
    ready=1
    break
  fi
  sleep 3
done
[[ "$ready" -eq 1 ]] || {
  echo 'Metastore не слушает :9083' >&2
  sudo -n systemctl status hive-metastore --no-pager -l >&2 || true
  exit 1
}
sudo -n systemctl enable --now hiveserver2
ready=0
for _ in $(seq 1 90); do
  if ss -ltn | grep -q ':10000 ' && \
     sudo -n -u "$HIVE_USER" env JAVA_HOME="$JAVA_HOME" HADOOP_HOME="$HADOOP_HOME" HIVE_HOME="$HIVE_HOME" \
      "$HIVE_HOME/bin/beeline" -u "jdbc:hive2://localhost:10000" -n scott -p tiger \
      -e 'SHOW DATABASES;' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 3
done
[[ "$ready" -eq 1 ]] || {
  echo 'HiveServer2 не готов на :10000' >&2
  sudo -n systemctl status hiveserver2 --no-pager -l >&2 || true
  sudo -n tail -80 /tmp/hadoop/hive.log >&2 || true
  exit 1
}

mkdir -p "$WORK/data"
cat > "$WORK/data/events_2024-01-01.csv" <<'CSV'
1,login,ok
2,logout,ok
3,login,fail
CSV
cat > "$WORK/data/events_2024-01-02.csv" <<'CSV'
4,login,ok
5,purchase,ok
6,logout,ok
CSV

sudo -n -u "$HIVE_USER" "$HADOOP_HOME/bin/hdfs" dfs -put -f - /input/events/events_2024-01-01.csv \
  < "$WORK/data/events_2024-01-01.csv"
sudo -n -u "$HIVE_USER" "$HADOOP_HOME/bin/hdfs" dfs -put -f - /input/events/events_2024-01-02.csv \
  < "$WORK/data/events_2024-01-02.csv"

BEELINE=(
  sudo -n -u "$HIVE_USER" env JAVA_HOME="$JAVA_HOME" HADOOP_HOME="$HADOOP_HOME" HIVE_HOME="$HIVE_HOME"
  "$HIVE_HOME/bin/beeline" -u "jdbc:hive2://localhost:10000" -n scott -p tiger
  --silent=true --showHeader=false --outputformat=tsv2
)

"${BEELINE[@]}" -e "
CREATE DATABASE IF NOT EXISTS test;
DROP TABLE IF EXISTS test.events;
CREATE TABLE test.events (
  id INT,
  event_type STRING,
  status STRING
)
PARTITIONED BY (dt STRING)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ','
STORED AS TEXTFILE;
"

"${BEELINE[@]}" -e "
LOAD DATA INPATH '/input/events/events_2024-01-01.csv'
INTO TABLE test.events PARTITION (dt='2024-01-01');
LOAD DATA INPATH '/input/events/events_2024-01-02.csv'
INTO TABLE test.events PARTITION (dt='2024-01-02');
"

echo 'Партиции:'
"${BEELINE[@]}" -e 'SHOW PARTITIONS test.events;'
echo 'Данные:'
"${BEELINE[@]}" -e 'SELECT * FROM test.events LIMIT 20;'

unset PG_PASS PG_PASS_XML
echo "Hive ${HIVE_VERSION}"
echo "Metastore: thrift://$EDGE_HOST:9083"
echo "HiveServer2: jdbc:hive2://$EDGE_HOST:10000"
echo "Второй клиент: $HIVE_HOME/bin/beeline -u jdbc:hive2://localhost:10000 -n scott -p tiger"
