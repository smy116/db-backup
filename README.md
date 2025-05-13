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
docker pull ghcr.io/smy116/db-backup:latest
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
  ghcr.io/smy116/db-backup:latest
```

### 使用 Docker Compose

```yaml
version: "3"

services:
  db-backup:
    image: ghcr.io/smy116/db-backup:latest
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

## 许可证

MIT
