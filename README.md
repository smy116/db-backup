# db-backup

数据库定时备份镜像，支持 PostgreSQL、MySQL 和 Redis 数据库的定期备份。

## 功能特性

- 支持 PostgreSQL、MySQL 和 Redis 数据库备份
- 使用 crontab 定期执行备份任务
- 每种数据库类型的备份分别存储在独立目录
- 备份文件自动压缩为 TAR.GZ 格式
- 自动清理超过 30 天的旧备份文件
- 通过环境变量灵活配置备份参数
- 支持选择性启用或禁用各类数据库的备份功能
- 支持自定义备份计划

## 使用方法

### 拉取镜像

```bash
docker pull ghcr.io/smy116/db-backup:main
```

### 基本用法

```bash
docker run -d \
  --name db-backup \
  -v /path/to/backup:/backup \
  -e ENABLE_PG=true \
  -e PG_HOST=pg-server \
  -e PG_USER=postgres \
  -e PG_PASSWORD=secret \
  ghcr.io/smy116/db-backup:main
```

### 使用 Docker Compose

```yaml
version: "3"

services:
  db-backup:
    image: ghcr.io/smy116/db-backup:main
    container_name: db-backup
    environment:
      - CRON_SCHEDULE=0 3 * * * # 每天凌晨3点执行
      - BACKUP_ON_START=true # 容器启动时执行一次备份
      - TZ=Asia/Shanghai # 设置容器时区
      # PostgreSQL配置
      - ENABLE_PG=true
      - PG_HOST=postgres
      - PG_PORT=5432
      - PG_USER=postgres
      - PG_PASSWORD=secret
      - PG_DATABASES=all # 备份所有数据库，或使用逗号分隔的列表
      # MySQL配置
      - ENABLE_MYSQL=true
      - MYSQL_HOST=mysql
      - MYSQL_PORT=3306
      - MYSQL_USER=root
      - MYSQL_PASSWORD=secret
      - MYSQL_DATABASES=all # 备份所有数据库，或使用逗号分隔的列表
      # Redis配置
      - ENABLE_REDIS=true
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=secret
      - REDIS_DB_NUMBERS=all # 备份所有数据库，或使用逗号分隔的列表
    volumes:
      - /path/to/backup:/backup
    restart: unless-stopped
```

## 环境变量

### 通用配置

| 环境变量          | 说明                             | 默认值                      |
| ----------------- | -------------------------------- | --------------------------- |
| `CRON_SCHEDULE`   | Cron 表达式，定义备份执行时间    | `0 3 * * *` (每天凌晨 3 点) |
| `BACKUP_ON_START` | 容器启动或重启时是否立即执行备份 | `false`                     |
| `TZ`              | 容器时区设置                     | `Asia/Shanghai`             |

### PostgreSQL 配置

| 环境变量       | 说明                                                        | 默认值      |
| -------------- | ----------------------------------------------------------- | ----------- |
| `ENABLE_PG`    | 是否启用 PostgreSQL 备份                                    | `false`     |
| `PG_HOST`      | PostgreSQL 服务器地址                                       | `localhost` |
| `PG_PORT`      | PostgreSQL 服务器端口                                       | `5432`      |
| `PG_USER`      | PostgreSQL 用户名                                           | `postgres`  |
| `PG_PASSWORD`  | PostgreSQL 密码                                             | `""` (空)   |
| `PG_DATABASES` | 要备份的数据库列表，使用逗号分隔，或设为`all`备份所有数据库 | `all`       |

### MySQL 配置

| 环境变量          | 说明                                                        | 默认值      |
| ----------------- | ----------------------------------------------------------- | ----------- |
| `ENABLE_MYSQL`    | 是否启用 MySQL 备份                                         | `false`     |
| `MYSQL_HOST`      | MySQL 服务器地址                                            | `localhost` |
| `MYSQL_PORT`      | MySQL 服务器端口                                            | `3306`      |
| `MYSQL_USER`      | MySQL 用户名                                                | `root`      |
| `MYSQL_PASSWORD`  | MySQL 密码                                                  | `""` (空)   |
| `MYSQL_DATABASES` | 要备份的数据库列表，使用逗号分隔，或设为`all`备份所有数据库 | `all`       |

### Redis 配置

| 环境变量           | 说明                                                                   | 默认值      |
| ------------------ | ---------------------------------------------------------------------- | ----------- |
| `ENABLE_REDIS`     | 是否启用 Redis 备份                                                    | `false`     |
| `REDIS_HOST`       | Redis 服务器地址                                                       | `localhost` |
| `REDIS_PORT`       | Redis 服务器端口                                                       | `6379`      |
| `REDIS_PASSWORD`   | Redis 密码                                                             | `""` (空)   |
| `REDIS_DB_NUMBERS` | 要备份的 Redis 数据库编号列表，使用逗号分隔，或设为`all`备份所有数据库 | `all`       |

## 备份文件位置

- PostgreSQL 备份: `/backup/pg/pg_backup_YYYYMMDD_HHMMSS.tar.gz`
- MySQL 备份: `/backup/mysql/mysql_backup_YYYYMMDD_HHMMSS.tar.gz`
- Redis 备份: `/backup/redis/redis_backup_YYYYMMDD_HHMMSS.tar.gz`

所有备份文件会自动保留 30 天，超过时间的备份将被自动删除。

## 数据库恢复

本节说明如何恢复各类数据库备份。所有备份文件均为 TAR.GZ 格式，需要先解压后再进行恢复操作。

### 通用解压步骤

```bash
# 创建临时目录
mkdir -p /tmp/restore

# 解压缩备份文件（替换为实际备份文件路径）
tar -xzf /backup/[db_type]/[backup_file].tar.gz -C /tmp/restore
```

### PostgreSQL 恢复

PostgreSQL 备份文件为 `.dump` 格式（自定义二进制格式），需要使用 `pg_restore` 命令恢复：

```bash
# 列出备份中包含的数据库
ls -la /tmp/restore

# 恢复单个数据库（替换为实际数据库名称）
pg_restore -h [host] -p [port] -U [username] -d [database_name] -v /tmp/restore/[database_name].dump

# 如果数据库不存在，需要先创建
createdb -h [host] -p [port] -U [username] [database_name]
pg_restore -h [host] -p [port] -U [username] -d [database_name] -v /tmp/restore/[database_name].dump

# 恢复特定表（可选）
pg_restore -h [host] -p [port] -U [username] -d [database_name] -t [table_name] -v /tmp/restore/[database_name].dump

# 只恢复数据，不恢复结构（可选）
pg_restore -h [host] -p [port] -U [username] -d [database_name] --data-only -v /tmp/restore/[database_name].dump

# 只恢复结构，不恢复数据（可选）
pg_restore -h [host] -p [port] -U [username] -d [database_name] --schema-only -v /tmp/restore/[database_name].dump
```

常用 pg_restore 参数说明：

- `-v`: 显示详细信息
- `-c`: 在恢复前清空目标数据库中的对象
- `-C`: 在恢复前创建数据库
- `--data-only`: 只恢复数据，不恢复表结构
- `--schema-only`: 只恢复表结构，不恢复数据
- `-t [table]`: 只恢复指定的表

### MySQL 恢复

MySQL 备份文件为 `.sql` 文本格式，可以使用 `mysql` 命令恢复：

```bash
# 列出备份中包含的数据库
ls -la /tmp/restore

# 恢复数据库（替换为实际数据库名称）
mysql -h [host] -P [port] -u [username] -p < /tmp/restore/[database_name].sql
```

如果需要先创建数据库（备份中不包含创建数据库语句时）：

```bash
# 创建数据库
mysql -h [host] -P [port] -u [username] -p -e "CREATE DATABASE IF NOT EXISTS [database_name];"

# 恢复到指定数据库
mysql -h [host] -P [port] -u [username] -p [database_name] < /tmp/restore/[database_name].sql
```

如果只需恢复特定表：

```bash
# 从完整备份中提取单个表
grep -n "CREATE TABLE.*\`[table_name]\`" /tmp/restore/[database_name].sql  # 查找表定义的行号
# 使用sed命令提取特定表的SQL，范围从表定义开始到下一个表定义或文件结束
sed -n '[start_line],[end_line]p' /tmp/restore/[database_name].sql > /tmp/table_backup.sql
mysql -h [host] -P [port] -u [username] -p [database_name] < /tmp/table_backup.sql
```

### Redis 恢复

Redis 备份文件为 `.rdb` 格式，需要停止 Redis 服务并替换 RDB 文件：

```bash
# 列出备份中包含的数据库文件
ls -la /tmp/restore

# 方法 1: 直接使用 redis-cli 恢复特定数据库（适用于小型数据库）
cat /tmp/restore/dump_[db_number].rdb | redis-cli -h [host] -p [port] -a [password] --pipe

# 方法 2: 替换 Redis RDB 文件（推荐方式，适用于所有规模数据库）
# 1. 停止 Redis 服务
sudo systemctl stop redis-server  # 或者 redis-server, 取决于安装方式

# 2. 备份当前 RDB 文件（如果有的话）
sudo cp /var/lib/redis/dump.rdb /var/lib/redis/dump.rdb.bak  # 实际路径可能不同

# 3. 复制恢复文件到 Redis 数据目录
# 如果只有一个数据库需要恢复
sudo cp /tmp/restore/dump_[db_number].rdb /var/lib/redis/dump.rdb

# 4. 调整权限
sudo chown redis:redis /var/lib/redis/dump.rdb

# 5. 启动 Redis 服务
sudo systemctl start redis-server  # 或者 redis-server
```

注意事项：

- Redis RDB 文件路径可能因安装方式而异，常见路径有 `/var/lib/redis/dump.rdb`、`/etc/redis/dump.rdb` 等
- Docker 环境中路径可能为容器内的 `/data/dump.rdb`
- 恢复前请确认 Redis 配置中的 `dir` 参数，这是 RDB 文件的存储位置

### 清理

完成数据库恢复操作后，请删除临时目录：

```bash
rm -rf /tmp/restore
```

## 许可证

MIT
