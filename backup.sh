#!/bin/sh
set -e

# 读取环境变量
ENABLE_ENCRYPTION=${ENABLE_ENCRYPTION:-"false"}
ENCRYPTION_PASSWORD=${ENCRYPTION_PASSWORD:-""}
RCLONE_CONFIG_PATH=${RCLONE_CONFIG_PATH:-"/backup/rclone.conf"}
RETENTION_DAYS=${RETENTION_DAYS:-"30"}

ENABLE_PG=${ENABLE_PG:-"false"}
PG_HOST=${PG_HOST:-"localhost"}
PG_PORT=${PG_PORT:-"5432"}
PG_USER=${PG_USER:-"postgres"}
PG_PASSWORD=${PG_PASSWORD:-""}
PG_DATABASES=${PG_DATABASES:-"all"}

ENABLE_MYSQL=${ENABLE_MYSQL:-"false"}
MYSQL_HOST=${MYSQL_HOST:-"localhost"}
MYSQL_PORT=${MYSQL_PORT:-"3306"}
MYSQL_USER=${MYSQL_USER:-"root"}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-""}
MYSQL_DATABASES=${MYSQL_DATABASES:-"all"}


# 日志函数
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 检查加密配置
check_encryption_config() {
  
  # 检查加密配置
  if [ "$ENABLE_ENCRYPTION" = "true" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
    log "警告: 加密已启用但未设置密码，将使用默认密码"
    ENCRYPTION_PASSWORD="default_password"
  fi
}

# 配置rclone
configure_rclone() {
  
  # 检查rclone配置文件是否存在
  if [ -f "$RCLONE_CONFIG_PATH" ]; then
    log "使用现有rclone配置文件: $RCLONE_CONFIG_PATH"
  else
    log "配置文件不存在，创建默认的backup配置..."
    mkdir -p /backup  # 确保备份目录存在
    mkdir -p $(dirname "$RCLONE_CONFIG_PATH")  # 确保配置文件目录存在
    
    # 直接在RCLONE_CONFIG_PATH指定的位置创建默认配置
    cat > "$RCLONE_CONFIG_PATH" <<EOF
[backup]
type = alias
remote = /backup
EOF
    log "已创建默认配置文件: $RCLONE_CONFIG_PATH，指向本地/backup目录"
  fi
  
  # 测试backup存储是否可用
  log "测试backup存储系统连接..."
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate lsd backup:
  if [ $? -ne 0 ]; then
    log "错误: 无法连接到backup存储系统，请检查配置"
    return 1
  fi
  
  log "rclone backup配置验证成功"
  return 0
}

# 检查备份目录
check_backup_dir() {
  local dir=$1
  if [ ! -d "$dir" ]; then
    log "创建备份目录: $dir"
    mkdir -p "$dir"
  fi
}

# 使用rclone上传文件
upload_with_rclone() {
  local local_file=$1
  local remote_path=$2
  
  log "上传文件到backup存储: $local_file -> backup:${remote_path%/*}/"
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate copy "$local_file" "backup:${remote_path%/*}/"
  if [ $? -ne 0 ]; then
    log "上传文件失败: $local_file"
    return 1
  fi
  
  log "文件成功上传到backup存储"
  
  # 上传成功后删除本地文件
  rm -f "$local_file"
  log "已删除本地临时备份文件"

  return 0
}

# 压缩并上传备份
compress_and_upload_backup() {
  local temp_dir=$1
  local local_backup_path=$2
  local remote_path=$3

  cd "$temp_dir" || return 1
  if [ "$ENABLE_ENCRYPTION" = "true" ]; then
    zip -q -r -e -P "$ENCRYPTION_PASSWORD" "$local_backup_path" . || return 1
    log "备份文件已加密压缩"
  else
    zip -q -r "$local_backup_path" . || return 1
  fi

  upload_with_rclone "$local_backup_path" "$remote_path"
  rm -rf "$temp_dir"
}


# 清理过期备份
cleanup_old_backups() {
  local backup_dir=$1
  
  # 提取路径前缀 (从backup_dir中提取最后一个目录名)
  local prefix=$(basename "$backup_dir")
  
  # 清理远程backup存储的备份
  log "清理backup存储中超过${RETENTION_DAYS}天的备份文件: $prefix/"
  
  # 使用rclone删除超过保留天数的文件
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate delete --min-age ${RETENTION_DAYS}d "backup:${prefix}/"
  if [ $? -ne 0 ]; then
    log "清理backup存储中的过期备份失败"
    return 1
  fi
  
  log "成功清理过期备份"
}

# PostgreSQL备份函数
backup_postgresql() {
  if [ "$ENABLE_PG" != "true" ]; then
    log "PostgreSQL备份已禁用"
    return 0
  fi
  
  log "开始备份PostgreSQL数据库..."
  
  # 创建临时和备份目录
  check_backup_dir "/backup/pg"
  
  local temp_dir=$(mktemp -d)
  local date_suffix=$(date +"%Y%m%d_%H%M%S")
  local backup_file="pg_backup_$date_suffix"
  local local_backup_path="$temp_dir/$backup_file.zip"
  
  export PGPASSWORD=$PG_PASSWORD
  
  # 备份所有数据库或指定数据库
  if [ "$PG_DATABASES" = "all" ]; then
    log "获取PostgreSQL所有数据库列表..."
    local db_list=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres')" | tr -d ' ')
  else
    local db_list=$(echo "$PG_DATABASES" | tr ',' ' ')
  fi
  
  # 备份每个数据库
  for db in $db_list; do
    log "备份数据库: $db"
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -F c -b -v -f "$temp_dir/${db}.dump" "$db"
    if [ $? -ne 0 ]; then
      log "备份数据库 $db 失败"
      continue
    fi
    log "数据库 $db 备份成功"
  done
  
  compress_and_upload_backup "$temp_dir" "$local_backup_path" "pg/$backup_file.zip" || return 1
  cleanup_old_backups "/backup/pg"

}

# MySQL备份函数
backup_mysql() {
  if [ "$ENABLE_MYSQL" != "true" ]; then
    log "MySQL备份已禁用"
    return 0
  fi
  
  log "开始备份MySQL数据库..."
  
  # 创建临时和备份目录
  check_backup_dir "/backup/mysql"
  local temp_dir=$(mktemp -d)
  local date_suffix=$(date +"%Y%m%d_%H%M%S")
  local backup_file="mysql_backup_$date_suffix"
  local local_backup_path="$temp_dir/$backup_file.zip"
  
  # 创建默认配置文件
  cat > "$temp_dir/my.cnf" <<EOF
[client]
host=$MYSQL_HOST
port=$MYSQL_PORT
user=$MYSQL_USER
password=$MYSQL_PASSWORD
skip-ssl = true
EOF
  
  # 备份所有数据库或指定数据库
  if [ "$MYSQL_DATABASES" = "all" ]; then
    log "获取MySQL/MariaDB所有数据库列表..."
    local db_list
    # 尝试使用MariaDB 11兼容的方式获取数据库列表
    db_list=$(mariadb --defaults-file="$temp_dir/my.cnf" -N -e "SHOW DATABASES" 2>/dev/null)
    if [ $? -ne 0 ]; then
      # 回退到MySQL兼容模式
      log "尝试MySQL兼容模式..."
      db_list=$(mysql --defaults-file="$temp_dir/my.cnf" -N -e "SHOW DATABASES")
    fi
    # 过滤系统数据库
    db_list=$(echo "$db_list" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
  else
    local db_list=$(echo "$MYSQL_DATABASES" | tr ',' ' ')
  fi
  
  # 备份每个数据库
  for db in $db_list; do
    log "备份数据库: $db"
    # 尝试使用MariaDB 11兼容的备份参数，增加--skip-lock-tables以避免锁表问题
    mariadb-dump --defaults-file="$temp_dir/my.cnf" --databases "$db" \
      --single-transaction --skip-lock-tables --routines --triggers --events > "$temp_dir/${db}.sql"
    
    # 检查命令是否执行成功
    if [ $? -ne 0 ]; then
      log "使用MariaDB 11参数备份失败，尝试兼容模式..."
      # 回退使用基本参数
      mariadb-dump --defaults-file="$temp_dir/my.cnf" --databases "$db" \
        --single-transaction --routines --triggers --events > "$temp_dir/${db}.sql"
      
      if [ $? -ne 0 ]; then
        log "备份数据库 $db 失败，尝试使用mysql-dump命令..."
        # 尝试使用mysql-dump命令（MySQL兼容模式）
        mysqldump --defaults-file="$temp_dir/my.cnf" --databases "$db" \
          --single-transaction --routines --triggers --events > "$temp_dir/${db}.sql"
        
        if [ $? -ne 0 ]; then
          log "备份数据库 $db 失败"
          continue
        fi
      fi
    fi
    
    log "数据库 $db 备份成功"
  done

  rm -f "$temp_dir/my.cnf"
  
  compress_and_upload_backup "$temp_dir" "$local_backup_path" "mysql/$backup_file.zip" || return 1
  cleanup_old_backups "/backup/mysql"

}

# 主函数
main() {
  log "数据库备份开始执行..."
  
  # 确保备份目录存在
  check_backup_dir "/backup"
  
  log "备份保留天数: $RETENTION_DAYS 天"
  
  # 检查加密配置
  check_encryption_config
  if [ "$ENABLE_ENCRYPTION" = "true" ]; then
    log "备份加密已启用"
  else
    log "备份加密未启用"
  fi
  
  # 验证rclone配置
  log "验证backup存储配置..."
  if ! configure_rclone; then
    log "警告: backup存储配置验证失败，将仅使用本地/backup目录"
  fi
  
  # 执行各数据库的备份
  backup_postgresql
  backup_mysql
  
  log "所有数据库备份完成!"
}

# 执行主函数
main
