# db-backup

数据库定时备份镜像，支持 PostgreSQL、MySQL 数据库的定期备份。

## 功能特性

- 支持 PostgreSQL、MySQL 数据库备份
- 使用 crontab 定期执行备份任务
- 每种数据库类型的备份分别存储在独立目录
- 备份文件自动压缩为 ZIP 格式，提供更高压缩率
- 支持备份文件加密保护，保障数据安全
- 支持本地存储或 S3 兼容存储
- 自定义备份保留天数（默认 30 天，本地和 S3 通用）
- 支持 S3 Path Style 访问方式
- 通过环境变量灵活配置备份参数
- 支持选择性启用或禁用各类数据库的备份功能
- 兼容 MariaDB 11 数据库
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
  ghcr.io/smy116/db-backup:latest
```

### 使用 Docker Compose

#### 本地存储示例

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
      - RETENTION_DAYS=30 # 备份保留天数
      # 存储配置
      - STORAGE_TYPE=local # 使用本地存储
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

    volumes:
      - /path/to/backup:/backup
    restart: unless-stopped
```

#### S3 存储示例

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
      - RETENTION_DAYS=30 # 备份保留天数
      # 存储配置
      - STORAGE_TYPE=s3 # 使用 S3 存储
      - S3_URL=https://s3.example.com # S3 端点 URL
      - S3_ACCESS_KEY=your_access_key # S3 访问密钥
      - S3_SECRET_KEY=your_secret_key # S3 密钥
      - S3_BUCKET=database-backups # S3 存储桶名称
      - S3_REGION=us-east-1 # S3 区域
      - S3_USE_PATH_STYLE=false # 是否使用 Path Style 访问
      - S3_KEEP_LOCAL=false # 上传后是否保留本地备份
      # PostgreSQL配置
      - ENABLE_PG=true
      - PG_HOST=postgres
      - PG_PORT=5432
      - PG_USER=postgres
      - PG_PASSWORD=secret
      # MySQL配置
      - ENABLE_MYSQL=true
      - MYSQL_HOST=mysql
      - MYSQL_PORT=3306
      - MYSQL_USER=root
      - MYSQL_PASSWORD=secret
    volumes:
      - /path/to/backup:/backup # 本地备份目录（如果保留本地备份）
    restart: unless-stopped
```

## 环境变量

### 通用配置

| 环境变量          | 说明                             | 默认值                      |
| ----------------- | -------------------------------- | --------------------------- |
| `CRON_SCHEDULE`   | Cron 表达式，定义备份执行时间    | `0 3 * * *` (每天凌晨 3 点) |
| `BACKUP_ON_START` | 容器启动或重启时是否立即执行备份 | `false`                     |
| `TZ`              | 容器时区设置                     | `Asia/Shanghai`             |
| `RETENTION_DAYS`  | 备份保留天数                     | `30`                        |

### 加密配置

| 环境变量              | 说明                           | 默认值  |
| --------------------- | ------------------------------ | ------- |
| `ENABLE_ENCRYPTION`   | 是否启用备份文件加密           | `false` |
| `ENCRYPTION_PASSWORD` | 加密密码，当加密启用时必须提供 | `""`    |

### 存储配置

| 环境变量            | 说明                                 | 默认值      |
| ------------------- | ------------------------------------ | ----------- |
| `STORAGE_TYPE`      | 存储类型，可选值为 `local` 或 `s3`   | `local`     |
| `S3_URL`            | S3 端点 URL (仅当 STORAGE_TYPE=s3)   | `""`        |
| `S3_ACCESS_KEY`     | S3 访问密钥 (仅当 STORAGE_TYPE=s3)   | `""`        |
| `S3_SECRET_KEY`     | S3 密钥 (仅当 STORAGE_TYPE=s3)       | `""`        |
| `S3_BUCKET`         | S3 存储桶名称 (仅当 STORAGE_TYPE=s3) | `""`        |
| `S3_REGION`         | S3 区域 (仅当 STORAGE_TYPE=s3)       | `us-east-1` |
| `S3_USE_PATH_STYLE` | 是否使用 Path Style 访问             | `false`     |
| `S3_KEEP_LOCAL`     | 上传到 S3 后是否保留本地备份文件     | `false`     |

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

## 备份文件位置

### 本地存储 (STORAGE_TYPE=local)

- PostgreSQL 备份: `/backup/pg/pg_backup_YYYYMMDD_HHMMSS.zip`
- MySQL 备份: `/backup/mysql/mysql_backup_YYYYMMDD_HHMMSS.zip`

### S3 存储 (STORAGE_TYPE=s3)

- PostgreSQL 备份: `s3://<S3_BUCKET>/pg/pg_backup_YYYYMMDD_HHMMSS.zip`
- MySQL 备份: `s3://<S3_BUCKET>/mysql/mysql_backup_YYYYMMDD_HHMMSS.zip`

所有备份文件（无论本地还是 S3）都会自动保留 `RETENTION_DAYS` 指定的天数（默认 30 天），超过保留期限的备份将被自动删除。

## 数据库恢复

本节说明如何恢复各类数据库备份。所有备份文件均为 ZIP 格式，需要先解压后再进行恢复操作。如果启用了加密，还需要提供正确的密码才能解压。

### 通用解压步骤

```bash
# 创建临时目录
mkdir -p /tmp/restore

# 解压缩备份文件（替换为实际备份文件路径）
# 未加密文件解压方式
unzip /backup/[db_type]/[backup_file].zip -d /tmp/restore

# 加密文件解压方式（会提示输入密码）
unzip /backup/[db_type]/[backup_file].zip -d /tmp/restore
# 或指定密码
unzip -P "your_password" /backup/[db_type]/[backup_file].zip -d /tmp/restore
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

### 清理

完成数据库恢复操作后，请删除临时目录：

```bash
rm -rf /tmp/restore
```

## 使用 S3 存储的注意事项

1. **S3 兼容性**: 本工具支持 AWS S3 和其他兼容 S3 API 的对象存储服务，如 MinIO、阿里云 OSS、腾讯云 COS 等。

2. **Path Style vs Virtual-Hosted Style**:

   - Path Style 格式: `https://s3.example.com/bucket-name/object-key`
   - Virtual-Hosted Style 格式: `https://bucket-name.s3.example.com/object-key`
   - 使用 `S3_USE_PATH_STYLE=true` 开启 Path Style 访问方式

3. **权限配置**: S3 用户需要具有以下权限:

   - `s3:PutObject`: 上传备份文件
   - `s3:ListBucket`: 列出桶中的文件
   - `s3:DeleteObject`: 删除过期备份文件

4. **读取备份文件**: 可以使用以下方式从 S3 下载备份文件:

   ```bash
   # 使用 s3cmd 下载
   s3cmd get s3://<S3_BUCKET>/pg/pg_backup_YYYYMMDD_HHMMSS.zip /path/to/local/file.zip

   # 使用 AWS CLI
   aws s3 cp s3://<S3_BUCKET>/pg/pg_backup_YYYYMMDD_HHMMSS.zip /path/to/local/file.zip
   ```

5. **排障**: 如果 S3 配置错误，脚本会自动回退到本地存储方式，并在日志中记录错误信息。

## 许可证

MIT
