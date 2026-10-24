#!/usr/bin/env bash
set -euo pipefail
umask 077

EDGE_IP="10.6.0.10"
NAMENODE_IP="10.6.0.11"
NAMENODE_HOST="team-06-nn"
DATANODE_0_IP="10.6.0.12"
DATANODE_1_IP="10.6.0.13"
SSH_USER="team"
SSH_KEY="$HOME/.ssh/team_internal"
NODES=("$NAMENODE_IP" "$DATANODE_0_IP" "$DATANODE_1_IP")
SSH_OPTIONS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

SPARK_VERSION="3.5.9"
SPARK_DIR="/opt/spark-${SPARK_VERSION}-bin-hadoop3"
SPARK_HOME="/opt/spark"
HADOOP_HOME="/opt/hadoop"
HIVE_HOME="/opt/hive"
JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"
HDFS_URI="hdfs://$NAMENODE_HOST:9000"
SOURCE_DIR="/input/events"
WAREHOUSE_TABLE_DIR="/user/hive/warehouse/test.db/events"
OUTPUT_DIR="/user/hadoop/dz4/event_counts_by_day"

if [[ $# -ne 0 ]]; then
  echo 'Использование: bash spark_hw4_team06.sh' >&2
  exit 1
fi

# Проверка пользователя и готовности HDFS
test "$(id -un)" = "$SSH_USER"
sudo -n -u hadoop "$HADOOP_HOME/bin/hdfs" dfsadmin -safemode wait
if sudo -n -u hadoop "$HADOOP_HOME/bin/hdfs" dfs -test -e "$OUTPUT_DIR"; then
  echo "Выходной каталог уже существует: $OUTPUT_DIR" >&2
  exit 1
fi

# Поиск данных в /input/events или партициях test.events
source_for_day() {
  local day=$1
  local uploaded="$SOURCE_DIR/events_${day}.csv"
  local partition="$WAREHOUSE_TABLE_DIR/dt=$day"
  if sudo -n -u hadoop "$HADOOP_HOME/bin/hdfs" dfs -test -e "$uploaded"; then
    printf '%s\n' "$HDFS_URI$uploaded"
  elif sudo -n -u hadoop "$HADOOP_HOME/bin/hdfs" dfs -test -d "$partition"; then
    printf '%s\n' "$HDFS_URI$partition"
  else
    echo "Не найдены данные за $day в HDFS" >&2
    return 1
  fi
}
SOURCE_01=$(source_for_day 2024-01-01)
SOURCE_02=$(source_for_day 2024-01-02)
echo "Исходные данные: $SOURCE_01, $SOURCE_02"

WORK=$(mktemp -d /tmp/dz4.XXXXXXXX)
chmod 755 "$WORK"
echo "Рабочий каталог: $WORK"
cd "$WORK"

# Установка Spark на edge
if [[ ! -x "$SPARK_DIR/bin/spark-submit" ]]; then
  ARCHIVE="$WORK/spark-${SPARK_VERSION}-bin-hadoop3.tgz"
  URL="https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz"
  curl -fsSL --retry 3 -o "$ARCHIVE" "$URL"
  curl -fsSL --retry 3 -o "$ARCHIVE.sha512" "$URL.sha512"
  DIGEST=$(grep -Eo '[[:xdigit:]]{128}' "$ARCHIVE.sha512" | head -1)
  printf '%s  %s\n' "$DIGEST" "$ARCHIVE" | sha512sum --status -c -
  sudo -n tar -xzf "$ARCHIVE" -C /opt --no-same-owner
fi
if [[ -e "$SPARK_HOME" || -L "$SPARK_HOME" ]]; then
  [[ $(readlink -f "$SPARK_HOME") == "$SPARK_DIR" ]] || {
    echo "$SPARK_HOME указывает на другую версию Spark" >&2
    exit 1
  }
else
  sudo -n ln -s "$SPARK_DIR" "$SPARK_HOME"
fi

# Настройка памяти YARN
cat > "$WORK/configure-yarn.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
FILE=/opt/hadoop/etc/hadoop/yarn-site.xml
CONFIG=$(sed \
  -e '/<name>yarn\.nodemanager\.resource\.memory-mb<\/name>/,/<\/property>/s|<value>512</value>|<value>1024</value>|' \
  -e '/<name>yarn\.scheduler\.maximum-allocation-mb<\/name>/,/<\/property>/s|<value>512</value>|<value>1024</value>|' \
  "$FILE")
if [[ "$CONFIG" != "$(cat "$FILE")" ]]; then
  cp -a "$FILE" "$FILE.bak.$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$CONFIG" > "$FILE"
  echo CHANGED
fi
SH

YARN_CHANGED=0
RESULT=$(sudo -n bash "$WORK/configure-yarn.sh")
if [[ "$RESULT" == CHANGED ]]; then YARN_CHANGED=1; fi
for NODE_IP in "${NODES[@]}"; do
  RESULT=$(ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$NODE_IP" 'sudo -n bash -s' \
    < "$WORK/configure-yarn.sh")
  if [[ "$RESULT" == CHANGED ]]; then YARN_CHANGED=1; fi
done
if (( YARN_CHANGED )); then
  ssh -n "${SSH_OPTIONS[@]}" "$SSH_USER@$NAMENODE_IP" \
    'sudo -n systemctl restart yarn@resourcemanager yarn@nodemanager'
  for NODE_IP in "$DATANODE_0_IP" "$DATANODE_1_IP"; do
    ssh -n "${SSH_OPTIONS[@]}" "$SSH_USER@$NODE_IP" \
      'sudo -n systemctl restart yarn@nodemanager'
  done

  # Ожидание регистрации трёх NodeManager
  NODES_READY=0
  for _ in $(seq 1 60); do
    if timeout 10 sudo -n -u hadoop "$HADOOP_HOME/bin/yarn" node -list \
      -states RUNNING > "$WORK/nodes.txt" 2>&1; then
      if [[ $(grep -c RUNNING "$WORK/nodes.txt") == 3 ]]; then
        NODES_READY=1
        break
      fi
    fi
    sleep 3
  done
  cat "$WORK/nodes.txt"
  (( NODES_READY )) || { echo 'Не зарегистрировались три NodeManager' >&2; exit 1; }
fi

# Настройка Hive
HIVE_CHANGED=$(sudo -n bash <<'SH'
set -euo pipefail
FILE=/opt/hive/conf/hive-site.xml
if grep -q '<name>hive\.metastore\.event\.db\.notification\.api\.auth</name>' "$FILE"; then
  CONFIG=$(sed '/<name>hive\.metastore\.event\.db\.notification\.api\.auth<\/name>/,/<\/property>/s|<value>true</value>|<value>false</value>|' "$FILE")
else
  CONFIG=$(sed '/<\/configuration>/i\
<property>\
  <name>hive.metastore.event.db.notification.api.auth</name>\
  <value>false</value>\
</property>
' "$FILE")
fi
if [[ "$CONFIG" != "$(cat "$FILE")" ]]; then
  cp -a "$FILE" "$FILE.bak.$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$CONFIG" > "$FILE"
  echo CHANGED
fi
SH
)
if [[ "$HIVE_CHANGED" == CHANGED ]] || \
  ! sudo -n systemctl is-active --quiet hive-metastore || \
  ! sudo -n systemctl is-active --quiet hiveserver2; then
  sudo -n systemctl restart hive-metastore hiveserver2
fi

# Проверка подключения к HiveServer2
BEELINE=(sudo -n -u hadoop env JAVA_HOME="$JAVA_HOME" HADOOP_HOME="$HADOOP_HOME"
  PATH="$HADOOP_HOME/bin:/usr/bin:/bin"
  HIVE_HOME="$HIVE_HOME" HIVE_CONF_DIR="$HIVE_HOME/conf"
  "$HIVE_HOME/bin/beeline" -u jdbc:hive2://localhost:10000 -n hadoop -p ''
  --silent=true --showHeader=false --outputformat=tsv2)
HIVE_READY=0
for _ in $(seq 1 60); do
  if timeout -k 5 10 "${BEELINE[@]}" -e 'SHOW DATABASES;' >/dev/null 2>&1; then
    HIVE_READY=1
    break
  fi
  sleep 2
done
(( HIVE_READY )) || { echo 'Не удалось подключиться к HiveServer2' >&2; exit 1; }

# Обработка данных в Spark
cat > "$WORK/dz4.py" <<'PY'
import sys

from pyspark.sql import SparkSession, functions as F

source_01, source_02, output_path = sys.argv[1:4]
spark = SparkSession.builder.appName('team06-dz4-events').getOrCreate()
try:
    schema = 'id INT, event_type STRING, status STRING'
    raw_01 = spark.read.schema(schema).csv(source_01).withColumn('dt', F.lit('2024-01-01'))
    raw_02 = spark.read.schema(schema).csv(source_02).withColumn('dt', F.lit('2024-01-02'))
    raw = raw_01.unionByName(raw_02)
    events = raw.filter(F.col('id').isNotNull())
    result = (
        events.groupBy('dt', 'event_type')
        .agg(
            F.count('*').alias('event_count'),
            F.sum(F.when(F.col('status') == 'fail', 1).otherwise(0)).alias('failed_count'),
        )
        .select('event_type', 'event_count', 'failed_count', 'dt')
    )
    result.write.mode('errorifexists').partitionBy('dt').parquet(output_path)
    print('Результат:', output_path)
finally:
    spark.stop()
PY
chmod 644 "$WORK/dz4.py"

sudo -n -u hadoop env \
  JAVA_HOME="$JAVA_HOME" HADOOP_HOME="$HADOOP_HOME" \
  PATH="$HADOOP_HOME/bin:/usr/bin:/bin" \
  HADOOP_CONF_DIR="$HADOOP_CONF_DIR" YARN_CONF_DIR="$HADOOP_CONF_DIR" \
  SPARK_HOME="$SPARK_HOME" PYSPARK_PYTHON=/usr/bin/python3 \
  "$SPARK_HOME/bin/spark-submit" \
  --master yarn --deploy-mode client \
  --driver-memory 512m --executor-memory 512m \
  --executor-cores 1 --num-executors 1 \
  --conf spark.driver.host="$EDGE_IP" \
  --conf spark.driver.bindAddress="$EDGE_IP" \
  --conf spark.executor.memoryOverhead=384 \
  --conf spark.yarn.am.memory=512m \
  --conf spark.yarn.am.memoryOverhead=384 \
  --conf spark.dynamicAllocation.enabled=false \
  --conf spark.sql.shuffle.partitions=2 \
  "$WORK/dz4.py" "$SOURCE_01" "$SOURCE_02" "$HDFS_URI$OUTPUT_DIR" \
  2>&1 | tee "$WORK/spark-submit.log"

# Создание таблицы Hive
"${BEELINE[@]}" -e "
CREATE DATABASE IF NOT EXISTS test;
CREATE EXTERNAL TABLE test.event_counts_by_day (
  event_type STRING,
  event_count BIGINT,
  failed_count BIGINT
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET
LOCATION '$HDFS_URI$OUTPUT_DIR';
MSCK REPAIR TABLE test.event_counts_by_day;
" | tee "$WORK/hive-register.log"

# Проверка данных через Hive
echo 'Партиции:'
"${BEELINE[@]}" -e 'SHOW PARTITIONS test.event_counts_by_day;'
echo 'Данные:'
"${BEELINE[@]}" -e \
  'SELECT dt, event_type, event_count, failed_count FROM test.event_counts_by_day LIMIT 20;'

echo 'Задание Spark выполнено успешно.'
