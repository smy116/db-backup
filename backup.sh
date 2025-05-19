#!/bin/bash
set -e

# 日志函数
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 检查加密配置
check_encryption_config() {
  # 设置默认值
  ENABLE_ENCRYPTION=${ENABLE_ENCRYPTION:-"false"}
  ENCRYPTION_PASSWORD=${ENCRYPTION_PASSWORD:-""}
  
  # 检查加密配置
  if [ "$ENABLE_ENCRYPTION" = "true" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
    log "警告: 加密已启用但未设置密码，将使用默认密码"
    ENCRYPTION_PASSWORD="default_password"
  fi
}

# 配置rclone
configure_rclone() {
  # 设置默认值
  RCLONE_CONFIG_PATH=${RCLONE_CONFIG_PATH:-"/backup/rclone.conf"}
  
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
  
  # 可选：上传成功后删除本地文件
  if [ "${KEEP_LOCAL:-true}" != "true" ]; then
    rm -f "$local_file"
    log "已删除本地备份文件"
  fi

  return 0
}

# 清理过期备份
cleanup_old_backups() {
  local backup_dir=$1
  local retention_days=${RETENTION_DAYS:-30}
  
  # 提取路径前缀 (从backup_dir中提取最后一个目录名)
  local prefix=$(basename "$backup_dir")
  
  # 清理远程backup存储的备份
  log "清理backup存储中超过${retention_days}天的备份文件: $prefix/"
  
  # 使用rclone删除超过保留天数的文件
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate delete --min-age ${retention_days}d "backup:${prefix}/"
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
  
  # 连接参数
  local pg_host=${PG_HOST:-"localhost"}
  local pg_port=${PG_PORT:-"5432"}
  local pg_user=${PG_USER:-"postgres"}
  local pg_password=${PG_PASSWORD:-""}
  local pg_databases=${PG_DATABASES:-"all"}
  
  export PGPASSWORD=$pg_password
  
  # 备份所有数据库或指定数据库
  if [ "$pg_databases" = "all" ]; then
    log "获取PostgreSQL所有数据库列表..."
    local db_list=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres')" | tr -d ' ')
  else
    local db_list=$(echo "$pg_databases" | tr ',' ' ')
  fi
  
  # 备份每个数据库
  for db in $db_list; do
    log "备份数据库: $db"
    pg_dump -h "$pg_host" -p "$pg_port" -U "$pg_user" -F c -b -v -f "$temp_dir/${db}.dump" "$db"
    if [ $? -ne 0 ]; then
      log "备份数据库 $db 失败"
      continue
    fi
  done
  
  # 压缩备份文件
  log "压缩PostgreSQL备份文件..."
  local local_backup_path="/backup/temp/$backup_file.zip"
  
  # 检查是否启用加密
  if [ "$ENABLE_ENCRYPTION" = "true" ]; then
    log "使用加密压缩PostgreSQL备份文件..."
    cd "$temp_dir" && zip -r -e -P "$ENCRYPTION_PASSWORD" "$local_backup_path" .
    if [ $? -ne 0 ]; then
      log "加密压缩备份文件失败"
      rm -rf "$temp_dir"
      unset PGPASSWORD
      return 1
    fi
    log "PostgreSQL备份文件已加密压缩"
  else
    cd "$temp_dir" && zip -r "$local_backup_path" .
    if [ $? -ne 0 ]; then
      log "压缩备份文件失败"
      rm -rf "$temp_dir"
      unset PGPASSWORD
      return 1
    fi
  fi
  
  # 清理临时文件
  rm -rf "$temp_dir"
  unset PGPASSWORD
  
  # 处理备份文件
  log "PostgreSQL备份完成: $local_backup_path"
  
  # 检查并配置rclone
  if configure_rclone; then
    # 上传到backup存储
    upload_with_rclone "$local_backup_path" "pg/$backup_file.zip"
    
    # 清理过期备份
    cleanup_old_backups "/backup/pg"

  fi
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
  
  # 连接参数
  local mysql_host=${MYSQL_HOST:-"localhost"}
  local mysql_port=${MYSQL_PORT:-"3306"}
  local mysql_user=${MYSQL_USER:-"root"}
  local mysql_password=${MYSQL_PASSWORD:-""}
  local mysql_databases=${MYSQL_DATABASES:-"all"}
  
  # 创建默认配置文件
  cat > "$temp_dir/my.cnf" <<EOF
[client]
host=$mysql_host
port=$mysql_port
user=$mysql_user
password=$mysql_password
skip-ssl = true
EOF
  
  # 备份所有数据库或指定数据库
  if [ "$mysql_databases" = "all" ]; then
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
    local db_list=$(echo "$mysql_databases" | tr ',' ' ')
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
  
  # 压缩备份文件
  log "压缩MySQL备份文件..."
  local local_backup_path="/backup/temp/$backup_file.zip"
  
  # 删除配置文件，避免包含敏感信息
  rm -f "$temp_dir/my.cnf"
  
  # 检查是否启用加密
  if [ "$ENABLE_ENCRYPTION" = "true" ]; then
    log "使用加密压缩MySQL备份文件..."
    cd "$temp_dir" && zip -r -e -P "$ENCRYPTION_PASSWORD" "$local_backup_path" .
    if [ $? -ne 0 ]; then
      log "加密压缩备份文件失败"
      rm -rf "$temp_dir"
      return 1
    fi
    log "MySQL备份文件已加密压缩"
  else
    cd "$temp_dir" && zip -r "$local_backup_path" .
    if [ $? -ne 0 ]; then
      log "压缩备份文件失败"
      rm -rf "$temp_dir"
      return 1
    fi
  fi
  
  # 清理临时文件
  rm -rf "$temp_dir"
  
  # 处理备份文件
  log "MySQL备份完成: $local_backup_path"
  
  # 检查并配置rclone
  if configure_rclone; then
    # 上传到backup存储
    upload_with_rclone "$local_backup_path" "mysql/$backup_file.zip"
    
    # 清理过期备份
    cleanup_old_backups "/backup/mysql"

  fi
}

# 主函数
main() {
  log "数据库备份开始执行..."
  
  # 确保备份主目录存在
  check_backup_dir "/backup"
  
  # 设置保留天数
  RETENTION_DAYS=${RETENTION_DAYS:-30}
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
