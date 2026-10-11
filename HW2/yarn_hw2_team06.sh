#!/usr/bin/env bash
set -euo pipefail
umask 077

EDGE_IP="10.6.0.10"
EDGE_HOST="team-06-en"
NAMENODE_IP="10.6.0.11"
NAMENODE_HOST="team-06-nn"
DATANODE_0_IP="10.6.0.12"
DATANODE_0_HOST="team-06-00"
DATANODE_1_IP="10.6.0.13"
DATANODE_1_HOST="team-06-01"
SSH_USER="team"
SSH_KEY="$HOME/.ssh/team_internal"
DATA_DIR="/var/lib/yarn"
PUBLIC_HOST=127.0.0.1
WEB_USER=team
NODES=("$EDGE_HOST" "$NAMENODE_HOST" "$DATANODE_0_HOST" "$DATANODE_1_HOST")
WORKERS=("$NAMENODE_HOST" "$DATANODE_0_HOST" "$DATANODE_1_HOST")
if [[ $# -ne 0 ]]; then
  echo 'Использование: bash yarn_hw2_team06.sh'
  exit 1
fi

# Абсолютный путь без пробелов и XML-символов
if [[ ! $DATA_DIR =~ ^/[A-Za-z0-9_/-]+$ || $DATA_DIR == / ]]; then
  echo 'Некорректный DATA_DIR' >&2
  exit 1
fi

# Выполнение команд на узлах
run() {
  local host=$1
  shift
  if [[ "$host" == "$EDGE_HOST" ]]; then
    bash -e -c "$1"
  else
    case "$host" in
      "$NAMENODE_HOST") host="$NAMENODE_IP" ;;
      "$DATANODE_0_HOST") host="$DATANODE_0_IP" ;;
      "$DATANODE_1_HOST") host="$DATANODE_1_IP" ;;
    esac
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$SSH_USER@$host" "$1"
  fi
}

# Проверка узлов и готовности HDFS
test "$(id -un)" = "$SSH_USER"
ip -4 -o address show | grep -F " $EDGE_IP/"
test -r "$SSH_KEY"
for host in "${NODES[@]}"; do
  run "$host" 'sudo -n true && id hadoop && test -x /usr/lib/jvm/java-11-openjdk-amd64/bin/java && test -f /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.2.jar'
done
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfsadmin -safemode wait
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfsadmin -report

# Каталог конфигураций и результатов
WORK=$(mktemp -d "$PWD/yarn-config.XXXXXXXX")
echo "Конфигурации и результаты: $WORK"

# Конфигурация YARN и MapReduce
cat > "$WORK/yarn-site.xml" <<XML
<configuration>
<property>
  <name>yarn.resourcemanager.hostname</name>
  <value>$NAMENODE_HOST</value>
</property>
<property>
  <name>yarn.resourcemanager.webapp.address</name>
  <value>$NAMENODE_HOST:8088</value>
</property>
<property>
  <name>yarn.nodemanager.hostname</name>
  <value>NODE_HOST</value>
</property>
<property>
  <name>yarn.nodemanager.webapp.address</name>
  <value>NODE_HOST:8042</value>
</property>
<property>
  <name>yarn.nodemanager.aux-services</name>
  <value>mapreduce_shuffle</value>
</property>
<property>
  <name>yarn.nodemanager.env-whitelist</name>
  <value>JAVA_HOME,HADOOP_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_YARN_HOME,HADOOP_MAPRED_HOME,HADOOP_CONF_DIR,PATH,LANG,TZ,CLASSPATH_PREPEND_DISTCACHE</value>
</property>
<property>
  <name>yarn.nodemanager.resource.memory-mb</name>
  <value>512</value>
</property>
<property>
  <name>yarn.nodemanager.resource.cpu-vcores</name>
  <value>1</value>
</property>
<property>
  <name>yarn.nodemanager.vmem-check-enabled</name>
  <value>false</value>
</property>
<property>
  <name>yarn.scheduler.minimum-allocation-mb</name>
  <value>128</value>
</property>
<property>
  <name>yarn.scheduler.maximum-allocation-mb</name>
  <value>512</value>
</property>
<property>
  <name>yarn.scheduler.maximum-allocation-vcores</name>
  <value>1</value>
</property>
<property>
  <name>yarn.nodemanager.local-dirs</name>
  <value>$DATA_DIR/local</value>
</property>
<property>
  <name>yarn.nodemanager.log-dirs</name>
  <value>/var/log/yarn/containers</value>
</property>
<property>
  <name>yarn.log-aggregation-enable</name>
  <value>true</value>
</property>
<property>
  <name>yarn.nodemanager.remote-app-log-dir</name>
  <value>/yarn-logs</value>
</property>
<property>
  <name>yarn.log-aggregation.retain-seconds</name>
  <value>604800</value>
</property>
<property>
  <name>yarn.log.server.url</name>
  <value>http://$EDGE_HOST:19889/jobhistory/logs</value>
</property>
<property>
  <name>yarn.web-proxy.address</name>
  <value>$EDGE_HOST:19099</value>
</property>
<property>
  <name>yarn.timeline-service.enabled</name>
  <value>true</value>
</property>
<property>
  <name>yarn.timeline-service.version</name>
  <value>1.0</value>
</property>
<property>
  <name>yarn.timeline-service.hostname</name>
  <value>$EDGE_HOST</value>
</property>
<property>
  <name>yarn.timeline-service.address</name>
  <value>$EDGE_HOST:10200</value>
</property>
<property>
  <name>yarn.timeline-service.webapp.address</name>
  <value>$EDGE_HOST:18188</value>
</property>
<property>
  <name>yarn.timeline-service.generic-application-history.enabled</name>
  <value>true</value>
</property>
<property>
  <name>yarn.resourcemanager.system-metrics-publisher.enabled</name>
  <value>true</value>
</property>
<property>
  <name>yarn.timeline-service.leveldb-timeline-store.path</name>
  <value>$DATA_DIR/timeline</value>
</property>
<property>
  <name>yarn.acl.enable</name>
  <value>true</value>
</property>
<property>
  <name>yarn.admin.acl</name>
  <value>hadoop</value>
</property>
</configuration>
XML

cat > "$WORK/mapred-site.xml" <<XML
<configuration>
<property>
  <name>mapreduce.framework.name</name>
  <value>yarn</value>
</property>
<property>
  <name>mapreduce.application.classpath</name>
  <value>/opt/hadoop/share/hadoop/mapreduce/*:/opt/hadoop/share/hadoop/mapreduce/lib/*</value>
</property>
<property>
  <name>mapreduce.jobhistory.address</name>
  <value>$EDGE_HOST:10020</value>
</property>
<property>
  <name>mapreduce.jobhistory.webapp.address</name>
  <value>$EDGE_HOST:19889</value>
</property>
<property>
  <name>mapreduce.jobhistory.intermediate-done-dir</name>
  <value>/mr-history/tmp</value>
</property>
<property>
  <name>mapreduce.jobhistory.done-dir</name>
  <value>/mr-history/done</value>
</property>
<property>
  <name>mapreduce.job.acl-view-job</name>
  <value>*</value>
</property>
<property>
  <name>mapreduce.job.emit-timeline-data</name>
  <value>true</value>
</property>
<property>
  <name>yarn.app.mapreduce.am.resource.mb</name>
  <value>512</value>
</property>
<property>
  <name>yarn.app.mapreduce.am.command-opts</name>
  <value>-Xmx256m</value>
</property>
<property>
  <name>mapreduce.map.memory.mb</name>
  <value>256</value>
</property>
<property>
  <name>mapreduce.map.java.opts</name>
  <value>-Xmx128m</value>
</property>
<property>
  <name>mapreduce.reduce.memory.mb</name>
  <value>256</value>
</property>
<property>
  <name>mapreduce.reduce.java.opts</name>
  <value>-Xmx128m</value>
</property>
<property>
  <name>mapreduce.task.io.sort.mb</name>
  <value>32</value>
</property>
</configuration>
XML

cat > "$WORK/capacity-scheduler.xml" <<'XML'
<configuration>
<property>
  <name>yarn.scheduler.capacity.root.queues</name>
  <value>default</value>
</property>
<property>
  <name>yarn.scheduler.capacity.root.default.capacity</name>
  <value>100</value>
</property>
<property>
  <name>yarn.scheduler.capacity.root.default.maximum-capacity</name>
  <value>100</value>
</property>
<property>
  <name>yarn.scheduler.capacity.maximum-am-resource-percent</name>
  <value>0.75</value>
</property>
<property>
  <name>yarn.scheduler.capacity.root.default.acl_submit_applications</name>
  <value>hadoop</value>
</property>
</configuration>
XML

# Окружение и службы systemd
cat > "$WORK/yarn-env.sh" <<ENV
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_HOME=/opt/hadoop
export HADOOP_COMMON_HOME=/opt/hadoop
export HADOOP_HDFS_HOME=/opt/hadoop
export HADOOP_YARN_HOME=/opt/hadoop
export HADOOP_MAPRED_HOME=/opt/hadoop
export HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop
export HADOOP_LOG_DIR=/var/log/yarn
export HADOOP_PID_DIR=$DATA_DIR/run
export HADOOP_HEAPSIZE_MAX=256m
ENV
cp "$WORK/yarn-env.sh" "$WORK/mapred-env.sh"

cat > "$WORK/yarn@.service" <<'UNIT'
[Unit]
Description=YARN %i
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=hadoop
Group=hadoop
WorkingDirectory=/home/hadoop
ExecStart=/opt/hadoop/bin/yarn %i
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
LimitNOFILE=65536
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT
sed -e 's|/opt/hadoop/bin/yarn %i|/opt/hadoop/bin/mapred historyserver|' -e 's|Description=YARN %i|Description=MapReduce JobHistory|' "$WORK/yarn@.service" > "$WORK/jobhistory.service"

# Установка конфигурации на узле
cat > "$WORK/install-node.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
cd "$1"
NODE=$2
DATA_DIR=$3
BACKUP=$(mktemp -d /var/backups/yarn-simple.XXXXXXXX)
cp -a /opt/hadoop/etc/hadoop "$BACKUP/hadoop"
for file in /etc/systemd/system/yarn@.service /etc/systemd/system/jobhistory.service; do
  if [[ -f "$file" ]]; then cp -a "$file" "$BACKUP/"; fi
done
sed "s/NODE_HOST/$NODE/g" yarn-site.xml > yarn-site-node.xml
install -m 644 yarn-site-node.xml /opt/hadoop/etc/hadoop/yarn-site.xml
install -m 644 mapred-site.xml capacity-scheduler.xml /opt/hadoop/etc/hadoop/
install -m 644 yarn-env.sh mapred-env.sh /opt/hadoop/etc/hadoop/
install -d -o hadoop -g hadoop -m 750 "$DATA_DIR" "$DATA_DIR/local" "$DATA_DIR/run" "$DATA_DIR/timeline" /var/log/yarn /var/log/yarn/containers
install -m 644 yarn@.service jobhistory.service /etc/systemd/system/
systemctl daemon-reload
echo "Резервная копия на $NODE: $BACKUP"
INSTALL

# Сервис, узел, IP, внутренний порт, внешний порт, страница
cat > "$WORK/endpoints.txt" <<PORTS
NameNode $NAMENODE_HOST $NAMENODE_IP 9870 9870 /
SecondaryNameNode $NAMENODE_HOST $NAMENODE_IP 9868 9868 /
DataNode-NN $NAMENODE_HOST $NAMENODE_IP 9864 19864 /
DataNode-00 $DATANODE_0_HOST $DATANODE_0_IP 9864 19865 /
DataNode-01 $DATANODE_1_HOST $DATANODE_1_IP 9864 19866 /
ResourceManager $NAMENODE_HOST $NAMENODE_IP 8088 8088 /cluster
NodeManager-NN $NAMENODE_HOST $NAMENODE_IP 8042 18042 /node
NodeManager-00 $DATANODE_0_HOST $DATANODE_0_IP 8042 18043 /node
NodeManager-01 $DATANODE_1_HOST $DATANODE_1_IP 8042 18044 /node
JobHistory $EDGE_HOST $EDGE_IP 19889 19888 /jobhistory
Timeline $EDGE_HOST $EDGE_IP 18188 8188 /applicationhistory
WebAppProxy $EDGE_HOST $EDGE_IP 19099 9099 /proxy/
PORTS

# Замена внутренних адресов в ссылках и перенаправлениях
while read -r label host ip inside outside page; do
  for address in "$host" "$ip"; do
    echo "    sub_filter '$address:$inside' '$PUBLIC_HOST:$outside';" >> "$WORK/rewrites.conf"
    echo "    proxy_redirect http://$address:$inside/ http://$PUBLIC_HOST:$outside/;" >> "$WORK/rewrites.conf"
  done
done < "$WORK/endpoints.txt"

while read -r label host ip inside outside page; do
  cat >> "$WORK/nginx.conf" <<NGINX
server {
  listen $outside;
  server_name _;
  auth_basic "Hadoop";
  auth_basic_user_file /etc/nginx/yarn.htpasswd;
  location / {
    limit_except GET { deny all; }
    proxy_pass http://$ip:$inside;
    proxy_set_header Host \$proxy_host;
    proxy_set_header Accept-Encoding "";
    proxy_set_header Authorization "";
    proxy_read_timeout 120s;
    sub_filter_once off;
    sub_filter_types application/json application/javascript text/css;
NGINX
  cat "$WORK/rewrites.conf" >> "$WORK/nginx.conf"
  printf '  }\n}\n' >> "$WORK/nginx.conf"
  echo "$label http://$PUBLIC_HOST:$outside$page" >> "$WORK/urls.txt"
done < "$WORK/endpoints.txt"

sudo -n bash "$WORK/install-node.sh" "$WORK" "$EDGE_HOST" "$DATA_DIR"
for host in "${WORKERS[@]}"; do
  REMOTE=$(run "$host" 'mktemp -d /tmp/yarn.XXXXXXXX')
  case "$host" in
    "$NAMENODE_HOST") IP="$NAMENODE_IP" ;;
    "$DATANODE_0_HOST") IP="$DATANODE_0_IP" ;;
    "$DATANODE_1_HOST") IP="$DATANODE_1_IP" ;;
  esac
  scp -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -r "$WORK/." "$SSH_USER@$IP:$REMOTE/"
  run "$host" "sudo -n bash '$REMOTE/install-node.sh' '$REMOTE' '$host' '$DATA_DIR'"
done

# Создание каталогов HDFS и запуск сервисов
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -mkdir -p /mr-history/tmp /mr-history/done /yarn-logs /user/hadoop
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -chown hadoop:hadoop /mr-history /mr-history/tmp /mr-history/done /yarn-logs /user/hadoop
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -chmod 1777 /mr-history/tmp /yarn-logs
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -chmod 750 /mr-history/done

sudo -n systemctl enable yarn@timelineserver yarn@proxyserver jobhistory
sudo -n systemctl restart yarn@timelineserver yarn@proxyserver jobhistory
run "$NAMENODE_HOST" 'sudo -n systemctl enable yarn@resourcemanager && sudo -n systemctl restart yarn@resourcemanager'
for host in "${WORKERS[@]}"; do
  run "$host" 'sudo -n systemctl enable yarn@nodemanager && sudo -n systemctl restart yarn@nodemanager'
done

# Публикация веб-интерфейсов
sudo -n apt-get update
sudo -n apt-get install -y nginx apache2-utils
if ! sudo -n test -f /etc/nginx/yarn.htpasswd; then
  sudo -n htpasswd -cB /etc/nginx/yarn.htpasswd "$WEB_USER"
fi
sudo -n chown root:www-data /etc/nginx/yarn.htpasswd
sudo -n chmod 640 /etc/nginx/yarn.htpasswd
NGINX_BACKUP=$(sudo -n mktemp -d /var/backups/yarn-nginx.XXXXXXXX)
if sudo -n test -f /etc/nginx/conf.d/yarn.conf; then
  sudo -n cp -a /etc/nginx/conf.d/yarn.conf "$NGINX_BACKUP/previous.conf"
fi
sudo -n install -m 644 "$WORK/nginx.conf" /etc/nginx/conf.d/yarn.conf
if ! sudo -n nginx -t; then
  if sudo -n test -f "$NGINX_BACKUP/previous.conf"; then
    sudo -n cp "$NGINX_BACKUP/previous.conf" /etc/nginx/conf.d/yarn.conf
  else
    sudo -n mv /etc/nginx/conf.d/yarn.conf "$NGINX_BACKUP/invalid.conf"
  fi
  exit 1
fi
sudo -n systemctl enable --now nginx
sudo -n systemctl reload nginx

# Ожидание регистрации трёх NodeManager
READY=no
for attempt in $(seq 1 60); do
  if timeout 10 sudo -n -u hadoop /opt/hadoop/bin/yarn node -list > "$WORK/nodes.txt" 2>&1; then
    if [[ $(grep -c RUNNING "$WORK/nodes.txt") == 3 ]]; then
      READY=yes
      break
    fi
  fi
  sleep 3
done
cat "$WORK/nodes.txt"
if [[ "$READY" != yes ]]; then
  echo 'Не зарегистрировались три NodeManager. Проверьте journalctl -u yarn@nodemanager на узлах.'
  exit 1
fi
sudo -n systemctl is-active yarn@timelineserver yarn@proxyserver jobhistory nginx
run "$NAMENODE_HOST" 'sudo -n systemctl is-active yarn@resourcemanager'

# Проверка работы кластера через WordCount
TEST_PATH="/user/hadoop/hw2-$(date +%Y%m%d-%H%M%S)-$$"
printf 'hello yarn\nhello team\n' > "$WORK/input.txt"
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -mkdir -p "$TEST_PATH/input"
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -put - "$TEST_PATH/input/text.txt" < "$WORK/input.txt"
timeout 600 sudo -n -u hadoop /opt/hadoop/bin/yarn jar /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-3.4.2.jar wordcount -Dmapreduce.job.reduces=1 "$TEST_PATH/input" "$TEST_PATH/output" 2>&1 | tee "$WORK/wordcount.log"
sudo -n -u hadoop /opt/hadoop/bin/hdfs dfs -cat "$TEST_PATH/output/part-r-*" > "$WORK/result.txt"
printf 'hello\t2\nteam\t1\nyarn\t1\n' > "$WORK/expected.txt"
diff -u "$WORK/expected.txt" "$WORK/result.txt"
echo 'WordCount выполнен успешно.'
cat "$WORK/urls.txt"
echo 'Откройте адреса через SSH-туннель (см. README).'
echo 'Проверьте WebAppProxy через Tracking UI работающего задания.'
