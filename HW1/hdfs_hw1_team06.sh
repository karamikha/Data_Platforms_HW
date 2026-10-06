#!/usr/bin/env bash
set -euo pipefail


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
DATA_DIR="/var/lib/hadoop-hdfs"

# NameNode - третья DataNode
NODES=("$NAMENODE_IP" "$DATANODE_0_IP" "$DATANODE_1_IP")
SSH_OPTIONS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

remote() { local host=$1; shift; ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$host" "$@"; }
fail() { echo "$*" >&2; exit 1; }

ensure_known_hosts() {
  local host keyfile=$HOME/.ssh/known_hosts
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$keyfile"
  chmod 600 "$keyfile"
  for host in "${NODES[@]}"; do
    if ! ssh-keygen -F "$host" -f "$keyfile" >/dev/null; then
      ssh-keyscan -T 5 -H "$host" >> "$keyfile"
    fi
  done
}

# Запуск от пользователя с SSH-ключом, без sudo
[[ $(id -un) == "$SSH_USER" ]] || fail "Запускайте от $SSH_USER, без sudo."
# Абсолютный путь без пробелов и XML-символов
[[ $DATA_DIR =~ ^/[A-Za-z0-9_/-]+$ && $DATA_DIR != / ]] || fail 'Некорректный DATA_DIR'

settings=$(declare -p EDGE_IP EDGE_HOST NAMENODE_IP NAMENODE_HOST DATANODE_0_IP DATANODE_0_HOST DATANODE_1_IP DATANODE_1_HOST DATA_DIR)

# Установочный файл
work=$(mktemp -d)
printf '%s\n' "$settings" > "$work/install.sh"
cat >> "$work/install.sh" <<'INSTALL'
set -euo pipefail
role=$1
archive=$2
IFS= read -r hadoop_password

# Java и новый пользователь для сервисов
export DEBIAN_FRONTEND=noninteractive
apt-get update

if ! LC_ALL=C apt-cache policy openjdk-11-jdk-headless | grep -E 'Candidate: [0-9]' >/dev/null; then
  apt-get install -y software-properties-common
  add-apt-repository -y universe
  apt-get update
fi
apt-get install -y openjdk-11-jdk-headless
if ! id hadoop >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash hadoop
fi
printf 'hadoop:%s\n' "$hadoop_password" | chpasswd
unset hadoop_password

# Сохраняем hosts и обновляем имена узлов
cp -a /etc/hosts "/etc/hosts.before-hdfs-$(date +%Y%m%d%H%M%S)"
hosts_file=$(mktemp)
awk -v names="$EDGE_HOST $NAMENODE_HOST $DATANODE_0_HOST $DATANODE_1_HOST" '
  BEGIN {
    count = split(names, hosts, " ")
    for (i = 1; i <= count; i++) managed[hosts[i]] = 1
  }
  /^#/ || NF < 2 { print; next }
  {
    line = $1
    for (i = 2; i <= NF; i++) {
      if (!($i in managed)) line = line " " $i
    }
    if (line != $1) print line
  }
' /etc/hosts > "$hosts_file"
cat "$hosts_file" > /etc/hosts
cat >> /etc/hosts <<HOSTS
$EDGE_IP $EDGE_HOST
$NAMENODE_IP $NAMENODE_HOST
$DATANODE_0_IP $DATANODE_0_HOST
$DATANODE_1_IP $DATANODE_1_HOST
HOSTS

# Hadoop и минимальная конфигурация из лекции
tar -xzf "$archive" -C /opt --no-same-owner
ln -s /opt/hadoop-3.4.2 /opt/hadoop

cat > /opt/hadoop/etc/hadoop/core-site.xml <<XML
<configuration>
<property>
  <name>fs.defaultFS</name>
  <value>hdfs://$NAMENODE_HOST:9000</value>
</property>
<property>
  <name>hadoop.tmp.dir</name>
  <value>$DATA_DIR</value>
</property>
</configuration>
XML

cat > /opt/hadoop/etc/hadoop/hdfs-site.xml <<'XML'
<configuration>
<property>
  <name>dfs.replication</name>
  <value>3</value>
</property>
</configuration>
XML

cat > /opt/hadoop/etc/hadoop/hadoop-env.sh <<'ENV'
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export HADOOP_LOG_DIR=/var/log/hadoop
export HADOOP_HEAPSIZE_MAX=512m
ENV

# Каталоги данных и журналов hadoop
install -d -o hadoop -g hadoop -m 750 /var/log/hadoop "$DATA_DIR"
for dir in dfs dfs/name dfs/data dfs/namesecondary; do
  install -d -o hadoop -g hadoop -m 750 "$DATA_DIR/$dir"
done

# Службы нужны только на внутренних узлах
if [[ $role != edge ]]; then
  cat > /etc/systemd/system/hdfs@.service <<'UNIT'
[Unit]
Description=HDFS %i
Wants=network-online.target
After=network-online.target
[Service]
User=hadoop
Group=hadoop
ExecStart=/opt/hadoop/bin/hdfs %i
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
fi
INSTALL

# Первоначальная установка кластера
check='
set -eu
source /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 24.04 ]]; then
  echo "Требуется Ubuntu 24.04" >&2
  exit 1
fi
test "$(uname -m)" = x86_64
test -d /run/systemd/system
sudo -n true
for path in /opt/hadoop /opt/hadoop-3.4.2 /tmp/hadoop-hadoop /var/lib/hadoop-hdfs "$DATA_DIR" /etc/systemd/system/hdfs@.service; do
  if [[ -e $path || -L $path ]]; then
    echo "Уже существует: $path. Установка остановлена" >&2
    exit 1
  fi
done
'

# Проверка всех серверов до внесения изменений
check="$settings
$check"
ensure_known_hosts
bash -c "$check"
for host in "${NODES[@]}"; do
  remote "$host" 'bash -s' <<< "$check"
done

# Ввод пароля и дальнейшая передача
IFS= read -r -s -p 'Пароль для hadoop (от 16 символов, A–Z, a–z, цифра и спецсимвол): ' hadoop_password
printf '\n'
if [[ ${#hadoop_password} -lt 16 ||
      $hadoop_password != *[A-Z]* ||
      $hadoop_password != *[a-z]* ||
      $hadoop_password != *[0-9]* ||
      $hadoop_password != *[![:alnum:][:space:]]* ]]; then
  fail 'Пароль не соответствует требованиям'
fi
IFS= read -r -s -p 'Повторите пароль: ' hadoop_password_confirm
printf '\n'
[[ $hadoop_password == "$hadoop_password_confirm" ]] || fail 'Пароли не совпадают'
unset hadoop_password_confirm

# Загрузка дистрибутива
sudo -n apt-get update
sudo -n apt-get install -y curl ca-certificates
mkdir -p "$HOME/hdfs-download"
archive="$HOME/hdfs-download/hadoop-3.4.2.tar.gz"
curl -fsSL --retry 3 -o "$archive" https://archive.apache.org/dist/hadoop/common/hadoop-3.4.2/hadoop-3.4.2.tar.gz
curl -fsSL --retry 3 -o "$archive.sha512" https://archive.apache.org/dist/hadoop/common/hadoop-3.4.2/hadoop-3.4.2.tar.gz.sha512
digest=$(grep -Eo '[[:xdigit:]]{128}' "$archive.sha512")
[[ $digest =~ ^[[:xdigit:]]{128}$ ]] || fail 'Неожиданный формат SHA512'
printf '%s  %s\n' "$digest" "$archive" | sha512sum --status -c -

# Установка на edge, затем на трёх внутренних серверах
printf '%s\n' "$hadoop_password" | sudo -n bash "$work/install.sh" edge "$archive"
for host in "${NODES[@]}"; do
  stage=$(remote "$host" 'mktemp -d /tmp/hdfs-install.XXXXXXXX')
  [[ $stage =~ ^/tmp/hdfs-install\.[A-Za-z0-9]+$ ]] || fail 'Некорректный временный путь'
  scp "${SSH_OPTIONS[@]}" "$work/install.sh" "$SSH_USER@$host:$stage/install.sh"
  scp "${SSH_OPTIONS[@]}" "$archive" "$SSH_USER@$host:$stage/hadoop.tar.gz"
  printf '%s  %s\n' "$digest" "$stage/hadoop.tar.gz" | remote "$host" 'sha512sum --status -c -'
  printf '%s\n' "$hadoop_password" | remote "$host" "sudo -n bash '$stage/install.sh' server '$stage/hadoop.tar.gz'"
done
unset hadoop_password

# Форматирование нового NameNode и запуск всех сервисов
remote "$NAMENODE_IP" 'sudo -n -u hadoop /opt/hadoop/bin/hdfs namenode -format -nonInteractive'
remote "$NAMENODE_IP" 'sudo -n systemctl enable --now hdfs@namenode'
for host in "${NODES[@]}"; do
  remote "$host" 'sudo -n systemctl enable --now hdfs@datanode'
done
remote "$NAMENODE_IP" 'sudo -n systemctl enable --now hdfs@secondarynamenode'
