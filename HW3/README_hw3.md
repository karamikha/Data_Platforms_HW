# ДЗ3. развёртывание Hive

Скрипт hive_hw3_team06.sh автоматически разворачивает **Hive Metastore** и **HiveServer2** на edge с PostgreSQL metastore, создаёт тестовую партиционированную таблицу и загружает данные.


## Состав

- Edge — Metastore, HiveServer2, PostgreSQL — `EDGE_HOST` → `team-06-en`
- HDFS / YARN — уже развёрнуты дз1 и дз2

**Для запуска на другой среде** замените в начале скрипта:
EDGE_HOST, HADOOP_HOME, JAVA_HOME, HIVE_USER

## Требования

- Ubuntu 24.04 x86_64, systemd
- у `SSH_USER` — `sudo` без пароля
- установлены Java 11 и Hadoop 3.4.2 в `/opt/hadoop`, пользователь `hadoop`
- работают HDFS и YARN (дз1, дз2); HDFS доступен с edge
- доступ к репозиториям Ubuntu, `archive.apache.org` и Maven Central
- чистый стенд по Hive: нет `/opt/hive`, `/opt/apache-hive-*`, unit `hive-metastore` / `hiveserver2`


## Запуск

С личного компьютера (подставьте путь к файлу и внешний адрес edge):

```bash
scp "/path/to/hive_hw3_team06.sh" team@<внешний-адрес-edge>:~/
ssh team@<внешний-адрес-edge>
```

На edge от `SSH_USER`, без sudo:

```bash
set -o pipefail
bash ~/hive_hw3_team06.sh 2>&1 | tee ~/hive-install.log
```

Скрипт запросит пароль PostgreSQL для пользователя `hive`; повторный ввод должен совпасть с первым.

### Шаги, которые выполняет скрипт

1. Установка PostgreSQL, создание пользователя и БД metastore
2. Установка Hive 4.0.0-alpha-2, JDBC-драйвер PostgreSQL, инициализация схемы
3. Запуск Metastore (`:9083`) и HiveServer2 (`:10000`) через systemd
4. Создание БД `test`, таблицы `test.events`, загрузка CSV, проверка партиций и `SELECT`


## Проверка целостности

В логе установки (или повторным запросом ниже) ожидается:

```text
dt=2024-01-01
dt=2024-01-02
1	login	ok	2024-01-01
2	logout	ok	2024-01-01
3	login	fail	2024-01-01
4	login	ok	2024-01-02
5	purchase	ok	2024-01-02
6	logout	ok	2024-01-02
```

Повторный запрос:

```bash
/opt/hive/bin/beeline -u jdbc:hive2://localhost:10000 -n scott -p tiger \
  -e 'SHOW PARTITIONS test.events; SELECT * FROM test.events;'
```
