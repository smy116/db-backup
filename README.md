# db-backup

数据库定时备份镜像，支持 PostgreSQL、MySQL 数据库的定期备份。

## 功能特性

- 支持 PostgreSQL、MySQL 数据库备份
- 使用 crontab 定期执行备份任务
- 每种数据库类型的备份分别存储在独立目录
- 备份文件自动压缩为 ZIP 格式，提供更高压缩率
- 支持备份文件加密保护，保障数据安全
- 支持通过 rclone 配置任意存储系统
- 自定义备份保留天数（默认 30 天）
- 使用 rclone 统一管理本地和远程存储
- 基于文件创建时间清理旧备份，更加智能和可靠
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
      - RETENTION_DAYS=30 # 备份保留天数
      # 存储配置
      - RCLONE_CONFIG_PATH=/backup/rclone.conf # rclone配置文件路径
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
      - /path/to/backup:/backup # 本地备份目录
      - /path/to/rclone.conf:/backup/rclone.conf # rclone配置文件 (可选)
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

| 环境变量             | 说明                | 默认值                |
| -------------------- | ------------------- | --------------------- |
| `RCLONE_CONFIG_PATH` | rclone 配置文件路径 | `/backup/rclone.conf` |

**备注**：本项目使用 rclone 来管理本地和远程存储，使用名称为"backup"的存储系统进行备份。如果配置文件不存在，将自动创建一个指向本地 /backup 目录的 alias 类型存储。

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

## rclone 存储配置示例

以下是几种常见存储系统的 rclone 配置示例，可以作为 `rclone.conf` 文件的内容。请确保存储系统名称为 `backup`：

### 本地目录（默认配置）

```
[backup]
type = alias
remote = /backup
```

### S3 兼容存储 (AWS S3, MinIO 等)

```
[s3]
type = s3
provider = AWS
access_key_id = your_access_key
secret_access_key = your_secret_key
region = us-east-1
endpoint = https://s3.example.com
# 如需使用Path Style，添加以下行
# force_path_style = true

[backup]
type = alias
remote = s3:backup
```

### WebDAV 存储

```
[backup]
type = webdav
url = https://webdav.example.com
vendor = other
user = your_username
pass = your_password
```

### FTP 服务器

```
[backup]
type = ftp
host = ftp.example.com
user = your_username
pass = your_password
# 如果需要使用FTPS (FTP over SSL/TLS)
# tls = true
```

### SFTP (SSH) 服务器

```
[backup]
type = sftp
host = sftp.example.com
user = your_username
# 密码认证
pass = your_password
# 或使用SSH密钥认证
# key_file = /path/to/private_key
```

## 备份文件位置

- PostgreSQL 备份: `backup:pg/pg_backup_YYYYMMDD_HHMMSS.zip`
- MySQL 备份: `backup:mysql/mysql_backup_YYYYMMDD_HHMMSS.zip`

所有备份文件都会自动保留 `RETENTION_DAYS` 指定的天数（默认 30 天），超过保留期限的备份将被自动删除。

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

## 使用远程存储的注意事项

1. **自动配置**: 如果没有找到 rclone 配置文件，系统将自动创建一个名为 `backup` 的 alias 类型存储，指向本地的 `/backup` 目录。

2. **错误处理**: 如果 backup 存储系统配置错误或不可用，系统将仅使用本地存储并记录警告日志，不会终止容器运行。

3. **权限配置**: 远程存储系统需要具有以下操作权限:

   - 列出目录内容
   - 上传文件
   - 删除文件

4. **基于时间的清理**: 本项目使用 rclone 的 `--min-age` 过滤功能，根据文件的创建时间清理旧的备份，确保准确保留指定天数的备份。

5. **读取备份文件**: 可以使用以下方式从远程存储下载备份文件:

   ```bash
   # 使用 rclone 下载
   rclone copy backup:pg/pg_backup_YYYYMMDD_HHMMSS.zip /path/to/local/directory/
   ```

## 许可证

MIT
