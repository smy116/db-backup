#!/bin/bash
set -e

# 日志函数
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 检查S3配置
check_s3_config() {
  # 设置默认值
  S3_URL=${S3_URL:-""}
  S3_BUCKET=${S3_BUCKET:-""}
  S3_ACCESS_KEY=${S3_ACCESS_KEY:-""}
  S3_SECRET_KEY=${S3_SECRET_KEY:-""}
  S3_REGION=${S3_REGION:-"us-east-1"}
  S3_USE_PATH_STYLE=${S3_USE_PATH_STYLE:-"false"}
  
  # 检查必需的配置
  if [ -z "$S3_URL" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    log "错误: S3配置不完整，请检查S3_URL, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY环境变量"
    return 1
  fi

  local use_https_value="No"
  if [[ "${S3_URL}" == https://* ]]; then
    use_https_value="Yes"
  fi
  
  # 创建s3cmd配置文件
  mkdir -p ~/.s3cmd
  cat > ~/.s3cfg <<EOF
[default]
access_key = ${S3_ACCESS_KEY}
secret_key = ${S3_SECRET_KEY}
host_base = ${S3_URL#*//}
host_bucket = ${S3_BUCKET}.${S3_URL#*//}
bucket_location = ${S3_REGION}
use_https = ${use_https_value}
EOF

  if [ "$S3_USE_PATH_STYLE" = "true" ]; then
    echo "host_bucket = ${S3_URL#*//}/${S3_BUCKET}" >> ~/.s3cfg
  fi
  
  # 测试连接
  s3cmd ls s3://${S3_BUCKET}
  if [ $? -ne 0 ]; then
    log "错误: 无法连接到S3存储，请检查配置和网络连接"
    return 1
  fi
  
  log "S3配置验证成功"
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

# 上传文件到S3
upload_to_s3() {
  local local_file=$1
  local s3_path=$2
  
  log "上传文件到S3: $local_file -> s3://${S3_BUCKET}/${s3_path}"
  s3cmd put "$local_file" "s3://${S3_BUCKET}/${s3_path}"
  if [ $? -ne 0 ]; then
    log "上传文件到S3失败: $local_file"
    return 1
  fi
  
  log "文件成功上传到S3"
  return 0
}

# 删除过期备份
cleanup_old_backups() {
  local backup_dir=$1
  local storage_type=${STORAGE_TYPE:-"local"}
  local retention_days=${RETENTION_DAYS:-30}
  
  if [ "$storage_type" = "local" ]; then
    log "清理本地超过${retention_days}天的备份文件: $backup_dir"
    find "$backup_dir" -name "*.tar.gz" -type f -mtime +${retention_days} -delete
  elif [ "$storage_type" = "s3" ]; then
    # 提取S3路径前缀 (从backup_dir中提取最后一个目录名)
    local prefix=$(basename "$backup_dir")
    
    log "清理S3超过${retention_days}天的备份文件: $prefix/"
    # 获取当前时间戳（秒）
    local now=$(date +%s)
    # 计算retention_days天前的时间戳（秒）
    local cutoff=$((now - retention_days * 24 * 60 * 60))
    
    # 获取所有S3文件列表并进行过滤
    s3cmd ls "s3://${S3_BUCKET}/${prefix}/" | while read -r line; do
      # 提取日期和文件名
      # 格式通常是: YYYY-MM-DD HH:MM file_size s3://bucket/path
      if [[ $line =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}:[0-9]{2})\ +([0-9]+)\ (s3://.*) ]]; then
        local file_date="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        local file_path="${BASH_REMATCH[4]}"
        
        # 将日期转换为时间戳
        local file_timestamp=$(date -d "$file_date" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ $file_timestamp -lt $cutoff ]; then
          log "删除过期S3备份: $file_path"
          s3cmd rm "$file_path"
        fi
      fi
    done
  fi
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
  local local_backup_path="/backup/pg/$backup_file.tar.gz"
  cd "$temp_dir" && tar -czf "$local_backup_path" .
  
  # 清理临时文件
  rm -rf "$temp_dir"
  unset PGPASSWORD
  
  # 根据存储类型处理备份文件
  local storage_type=${STORAGE_TYPE:-"local"}
  if [ "$storage_type" = "local" ]; then
    # 清理本地过期备份
    cleanup_old_backups "/backup/pg"
    log "PostgreSQL备份完成: $local_backup_path"
  elif [ "$storage_type" = "s3" ]; then
    # 上传到S3
    if check_s3_config; then
      upload_to_s3 "$local_backup_path" "pg/$backup_file.tar.gz"
      # 清理S3过期备份
      cleanup_old_backups "/backup/pg"
      # 可选：上传成功后删除本地文件
      if [ "${S3_KEEP_LOCAL:-false}" != "true" ]; then
        rm -f "$local_backup_path"
        log "已删除本地备份文件"
      fi
    else
      log "警告: S3配置错误，使用本地存储作为备份"
      cleanup_old_backups "/backup/pg"
    fi
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
EOF
  
  # 备份所有数据库或指定数据库
  if [ "$mysql_databases" = "all" ]; then
    log "获取MySQL所有数据库列表..."
    local db_list=$(mysql --defaults-file="$temp_dir/my.cnf" -N -e "SHOW DATABASES" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$")
  else
    local db_list=$(echo "$mysql_databases" | tr ',' ' ')
  fi
  
  # 备份每个数据库
  for db in $db_list; do
    log "备份数据库: $db"
    mysqldump --defaults-file="$temp_dir/my.cnf" --databases "$db" --single-transaction --routines --triggers --events > "$temp_dir/${db}.sql"
    if [ $? -ne 0 ]; then
      log "备份数据库 $db 失败"
      continue
    fi
  done
  
  # 压缩备份文件
  log "压缩MySQL备份文件..."
  local local_backup_path="/backup/mysql/$backup_file.tar.gz"
  cd "$temp_dir" && rm -f my.cnf && tar -czf "$local_backup_path" .
  
  # 清理临时文件
  rm -rf "$temp_dir"
  
  # 根据存储类型处理备份文件
  local storage_type=${STORAGE_TYPE:-"local"}
  if [ "$storage_type" = "local" ]; then
    # 清理本地过期备份
    cleanup_old_backups "/backup/mysql"
    log "MySQL备份完成: $local_backup_path"
  elif [ "$storage_type" = "s3" ]; then
    # 上传到S3
    if check_s3_config; then
      upload_to_s3 "$local_backup_path" "mysql/$backup_file.tar.gz"
      # 清理S3过期备份
      cleanup_old_backups "/backup/mysql"
      # 可选：上传成功后删除本地文件
      if [ "${S3_KEEP_LOCAL:-false}" != "true" ]; then
        rm -f "$local_backup_path"
        log "已删除本地备份文件"
      fi
    else
      log "警告: S3配置错误，使用本地存储作为备份"
      cleanup_old_backups "/backup/mysql"
    fi
  fi
}

# Redis备份功能已移除

# 主函数
main() {
  log "数据库备份开始执行..."
  
  # 确保备份主目录存在
  check_backup_dir "/backup"
  
  # 设置保留天数
  RETENTION_DAYS=${RETENTION_DAYS:-30}
  log "备份保留天数: $RETENTION_DAYS 天"
  
  # 检查存储类型
  local storage_type=${STORAGE_TYPE:-"local"}
  log "当前存储类型: $storage_type"
  
  # 如果使用S3存储，预先验证S3配置
  if [ "$storage_type" = "s3" ]; then
    log "验证S3配置..."
    if ! check_s3_config; then
      log "警告: S3配置验证失败，将使用本地存储作为备份"
      export STORAGE_TYPE="local"
    fi
  fi
  
  # 执行各数据库的备份
  backup_postgresql
  backup_mysql
  
  log "所有数据库备份完成!"
}

# 执行主函数
main
