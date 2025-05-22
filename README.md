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
- **高可靠性**: 增强的错误处理和日志记录，确保容器在备份失败时保持稳定运行，并尝试后续计划任务。
- 兼容 MariaDB 11 数据库
- 支持自定义备份计划

## 运行稳健性 (Operational Robustness)

此备份容器在设计时充分考虑了运行稳定性：

-   **备份失败的弹性处理：**
    -   如果初始备份（由 `BACKUP_ON_START=true` 触发）失败，错误将被记录，但容器**不会**崩溃。它将继续运行以尝试所有未来的计划备份。
    -   如果计划备份失败（例如，数据库暂时不可用、rclone 远程存储问题），错误会记录到 cron 日志中（可通过 `docker logs <container_name>` 查看），但 cron 守护进程和容器将继续运行。后续备份将按计划尝试执行。
-   **改进的错误处理：** 底层的 `backup.sh` 脚本增强了错误检测能力，并提供更具体的日志记录以帮助诊断问题。它还使用不同的退出码来表明成功或失败。
-   **资源清理：** 在备份操作期间创建的临时文件和目录会被认真清理，即使在大多数错误情况下也是如此，以防止磁盘空间耗尽。脚本中使用到的环境变量中的敏感信息（例如 `PGPASSWORD`）在使用后会被取消设置。

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

## 问题排查 (Troubleshooting)

本节提供诊断和解决常见问题的指南。

### 日志位置

-   **主要日志：** 主要信息来源是容器的日志输出。您可以使用以下命令查看：
    ```bash
    docker logs <container_name_or_id>
    ```
    这包括：
    -   `entrypoint.sh` 的启动消息。
    -   每次 `backup.sh` 执行开始时记录的关键工具（`rclone`, `zip`, `pg_dump`, `mysqldump`, `mariadb-dump`）的版本信息。
    -   `backup.sh` 脚本针对初始备份（`BACKUP_ON_START=true`）和计划备份的输出。
    -   Cron 守护进程消息。
-   **Cron 日志文件 (内部)：** 在容器内部，cron 任务的输出也会定向到 `/var/log/cron.log`。`entrypoint.sh` 末尾的 `tail -f /var/log/cron.log` 命令确保此内容流式传输到 `docker logs`。

### 常见错误及解读

-   **初始备份失败（容器启动期间记录）**
    -   **症状：** 容器启动时，在 "执行初始备份..." 日志行之后立即看到来自 `backup.sh` 的错误消息。
    -   **含义：** `BACKUP_ON_START` 设置为 `true`，并且第一次自动备份尝试遇到了问题。
    -   **操作：** 查看紧随失败消息之后的容器日志，以了解具体错误（例如，数据库连接、rclone 问题）。
    -   **注意：** 容器将保持运行，并且仍会尝试计划的备份。

-   **备份脚本在 cron 日志中以非零状态退出**
    -   **症状：** 日志条目（通过 `docker logs`）显示类似 `INFO: Sending PIDs of all processes in session XXXX killed by TERM signal (exit status 1)` 的内容。或者更直接地，在计划运行期间出现来自 `backup.sh` 的错误消息。
    -   **含义：** 计划的备份运行失败。退出状态（例如 `1`）表示失败。
    -   **操作：** 检查此 cron 消息之前的 `backup.sh` 详细日志以确定原因。

-   **与数据库连接相关的错误（例如，身份验证失败、数据库未找到、连接被拒绝）**
    -   **症状：** 日志包含类似 `psql: error: connection to server ... failed: FATAL: password authentication failed for user "..."`、`mysqldump: Got error: 1045: Access denied for user...` 或 `Connection refused` 的消息。
    -   **操作：**
        -   验证数据库主机名/IP (`PG_HOST`, `MYSQL_HOST`) 是否正确，并且可以从备份容器内部访问。
        -   检查端口 (`PG_PORT`, `MYSQL_PORT`)。
        -   确保用户名 (`PG_USER`, `MYSQL_USER`) 和密码 (`PG_PASSWORD`, `MYSQL_PASSWORD`) 正确无误。
        -   确认 `PG_DATABASES` 或 `MYSQL_DATABASES` 中指定的数据库名称存在，并且用户具有适当的权限。

-   **与 rclone 相关的错误（例如，"Failed to copy", "Failed to delete", "Config not found"）**
    -   **症状 (配置未找到)：** 启动期间，您可能会看到 "警告：rclone配置验证失败或无法连接到 'backup:' 远程存储..." 或 "错误: 无法连接到backup存储系统..."。
    -   **含义 (配置未找到)：** 如果 `RCLONE_CONFIG_PATH` 指向不存在或无效的 rclone 配置文件，脚本将记录此情况并默认使用本地 `/backup` 目录作为存储目标。
    -   **操作 (配置未找到)：**
        -   如果您打算使用自定义 rclone 远程存储，请确保您的 `rclone.conf` 文件已正确地卷载到 `RCLONE_CONFIG_PATH` 指定的路径（默认为 `/backup/rclone.conf`）。
        -   验证 `rclone.conf` 包含一个名为 `[backup]` 的远程配置。这可以是到另一个已定义远程的别名。
    -   **症状 (上传/删除/列出错误)：** 日志显示类似 `Failed to copy: ...`、`Failed to delete: ...` 或在 `rclone lsd` 期间出错的消息。
    -   **含义 (上传/删除/列出错误)：** 与 rclone 远程存储通信或写入时出现问题。
    -   **操作 (上传/删除/列出错误)：**
        -   检查您的 `rclone.conf` 中 `[backup]` 远程的配置。确保端点、凭据和其他参数正确。
        -   验证从容器到远程存储提供商的网络连接。
        -   确保 rclone 使用的凭据在远程存储上具有必要的权限（列出、读取、写入、删除）。

-   **"设备上没有剩余空间 (No space left on device)"**
    -   **症状：** 备份失败，并出现指示磁盘空间耗尽的消息。
    -   **含义：** 容器内的本地存储已满。这可能是：
        -   用于临时数据库转储的目录（`/tmp/pg_backup.XXXXXX` 或 `/tmp/mysql_backup.XXXXXX`）。
        -   主备份卷（在容器中挂载到 `/backup`），如果 rclone 配置为使用本地路径或者初始转储非常大。
    -   **操作：**
        -   确保 Docker 主机具有足够的磁盘空间。
        -   如果使用本地 rclone 远程，请确保目标目录有足够的空间。
        -   检查旧备份是否按 `RETENTION_DAYS` 正确清理。如果没有，可能是 `rclone delete` 或远程存储对修改时间的处理存在问题。

-   **"缺少命令 (Missing command)（例如，pg_dump, mysqldump, rclone, zip）"**
    -   **症状：** `backup.sh` 运行开始时的日志指示找不到像 `rclone`、`zip`、`pg_dump` 或 `mysqldump`/`mariadb-dump` 这样的命令。
    -   **含义：** 备份操作所需的关键工具在容器环境中缺失。如果 `ENABLE_PG` 或 `ENABLE_MYSQL` 为 true，并且其各自的转储工具缺失，则对于该备份类型是致命错误。
    -   **操作：** 这通常表明 Docker 镜像本身存在问题（例如，在构建过程中工具未正确安装）。如果您使用的是官方预构建镜像，这种情况应该很少见。如果自行构建，请检查您的 `Dockerfile`。

### 用于调试的工具版本 (Tool Versions for Debugging)

在每次 `backup.sh` 执行开始时（包括初始备份和计划备份），都会记录关键工具（`rclone`, `zip`, `pg_dump`, `mysqldump`, `mariadb-dump`）的版本。这些信息在以下情况下非常有用：
-   报告问题时。
-   检查与您的数据库版本或 rclone 远程存储的兼容性问题时。
-   确保预期的工具存在于容器中。

## 许可证

MIT
