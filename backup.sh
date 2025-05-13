#!/bin/bash
set -e

# 日志函数
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 检查是否启用S3存储
is_s3_enabled() {
  [ "${STORAGE_TYPE:-local}" = "s3" ]
}

# 检查S3配置是否完整
check_s3_config() {
  if is_s3_enabled; then
    if [ -z "${S3_BUCKET}" ]; then
      log "错误: 启用S3存储但未设置S3_BUCKET - 将使用本地存储"
      return 1
    fi
    if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
      log "错误: 启用S3存储但未设置AWS凭证 - 将使用本地存储"
      return 1
    fi
    return 0
  fi
  return 1
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
  
  if ! check_s3_config; then
    log "S3配置不完整，跳过上传: $local_file"
    return 1
  fi
  
  log "上传文件到S3: s3://${S3_BUCKET}/${s3_path}"
  
  # 设置AWS命令行环境变量（如果未设置）
  export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
  export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
  export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-"us-east-1"}
  export AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-""}
  
  # 构建AWS CLI命令
  local aws_cmd="aws s3 cp $local_file s3://${S3_BUCKET}/${s3_path}"
  if [ -n "$AWS_ENDPOINT_URL" ]; then
    aws_cmd="$aws_cmd --endpoint-url $AWS_ENDPOINT_URL"
  fi
  # 添加path-style支持
  if [ "${AWS_USE_PATH_STYLE:-false}" = "true" ]; then
    aws_cmd="$aws_cmd --use-path-style"
  fi
  
  # 执行上传
  if eval "$aws_cmd"; then
    log "上传成功: s3://${S3_BUCKET}/${s3_path}"
    
    # 如果设置了自动删除本地文件，上传成功后删除
    if [ "${S3_DELETE_LOCAL_AFTER_UPLOAD:-false}" = "true" ]; then
      log "上传成功，删除本地文件: $local_file"
      rm -f "$local_file"
    fi
    
    return 0
  else
    log "上传失败: $local_file -> s3://${S3_BUCKET}/${s3_path}"
    return 1
  fi
}

# 清理S3上的过期备份（保留30天）
cleanup_old_s3_backups() {
  local s3_prefix=$1
  
  if ! check_s3_config; then
    log "S3配置不完整，跳过S3清理"
    return 1
  fi
  
  log "清理S3中超过30天的备份文件: s3://${S3_BUCKET}/${s3_prefix}"
  
  # 设置AWS命令行环境变量
  export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
  export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
  export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-"us-east-1"}
  export AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-""}
  
  # 获取30天前的日期（ISO8601格式）
  local threshold_date=$(date -d "30 days ago" "+%Y-%m-%dT%H:%M:%S")
  
  # 构建AWS CLI命令
  local list_cmd="aws s3api list-objects-v2 --bucket ${S3_BUCKET} --prefix ${s3_prefix}"
  if [ -n "$AWS_ENDPOINT_URL" ]; then
    list_cmd="$list_cmd --endpoint-url $AWS_ENDPOINT_URL"
  fi
  # 添加path-style支持
  if [ "${AWS_USE_PATH_STYLE:-false}" = "true" ]; then
    list_cmd="$list_cmd --use-path-style"
  fi
  
  # 获取对象列表并筛选超过30天的文件
  local objects=$(eval "$list_cmd" | grep -E '"LastModified": "[^"]+"' | awk -F'"' '{print $4 "," $8}')
  if [ -z "$objects" ]; then
    log "S3路径中没有找到备份文件: s3://${S3_BUCKET}/${s3_prefix}"
    return 0
  fi
  
  # 遍历并删除过期文件
  echo "$objects" | while IFS=',' read -r last_modified key; do
    if [ -n "$key" ] && [[ "$key" == *".tar.gz" ]] && [[ "$last_modified" < "$threshold_date" ]]; then
      log "删除过期S3备份: s3://${S3_BUCKET}/${key} (修改时间: $last_modified)"
      
      local delete_cmd="aws s3 rm s3://${S3_BUCKET}/${key}"
      if [ -n "$AWS_ENDPOINT_URL" ]; then
        delete_cmd="$delete_cmd --endpoint-url $AWS_ENDPOINT_URL"
      fi
      # 添加path-style支持
      if [ "${AWS_USE_PATH_STYLE:-false}" = "true" ]; then
        delete_cmd="$delete_cmd --use-path-style"
      fi
      
      if eval "$delete_cmd"; then
        log "成功删除过期S3备份: ${key}"
      else
        log "删除过期S3备份失败: ${key}"
      fi
    fi
  done
}

# 删除过期本地备份（保留30天）
cleanup_old_local_backups() {
  local backup_dir=$1
  log "清理本地超过30天的备份文件: $backup_dir"
  find "$backup_dir" -name "*.tar.gz" -type f -mtime +30 -delete
}

# 清理过期备份（根据存储类型）
cleanup_old_backups() {
  local backup_dir=$1
  local s3_prefix=$2
  
  # 清理本地备份
  cleanup_old_local_backups "$backup_dir"
  
  # 如果启用S3，清理S3备份
  if is_s3_enabled && check_s3_config; then
    cleanup_old_s3_backups "$s3_prefix"
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
  cd "$temp_dir" && tar -czf "/backup/pg/$backup_file.tar.gz" .
  
  # 清理
  rm -rf "$temp_dir"
  unset PGPASSWORD
  
  local backup_path="/backup/pg/$backup_file.tar.gz"
  
  # 清理过期备份
  cleanup_old_backups "/backup/pg" "pg"
  
  log "PostgreSQL备份完成: $backup_path"
  
  # 如果启用S3存储，上传备份文件到S3
  if is_s3_enabled && check_s3_config; then
    upload_to_s3 "$backup_path" "pg/$backup_file.tar.gz"
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
  cd "$temp_dir" && rm -f my.cnf && tar -czf "/backup/mysql/$backup_file.tar.gz" .
  
  # 清理
  rm -rf "$temp_dir"
  
  local backup_path="/backup/mysql/$backup_file.tar.gz"
  
  # 清理过期备份
  cleanup_old_backups "/backup/mysql" "mysql"
  
  log "MySQL备份完成: $backup_path"
  
  # 如果启用S3存储，上传备份文件到S3
  if is_s3_enabled && check_s3_config; then
    upload_to_s3 "$backup_path" "mysql/$backup_file.tar.gz"
  fi
}

# Redis备份函数
backup_redis() {
  if [ "$ENABLE_REDIS" != "true" ]; then
    log "Redis备份已禁用"
    return 0
  fi
  
  log "开始备份Redis数据库..."
  
  # 创建临时和备份目录
  check_backup_dir "/backup/redis"
  local temp_dir=$(mktemp -d)
  local date_suffix=$(date +"%Y%m%d_%H%M%S")
  local backup_file="redis_backup_$date_suffix"
  
  # 连接参数
  local redis_host=${REDIS_HOST:-"localhost"}
  local redis_port=${REDIS_PORT:-"6379"}
  local redis_password=${REDIS_PASSWORD:-""}
  local redis_db_numbers=${REDIS_DB_NUMBERS:-"all"}
  
  # 准备认证参数
  local auth_param=""
  if [ -n "$redis_password" ]; then
    auth_param="-a $redis_password"
  fi
  
  # 备份所有数据库或指定数据库
  if [ "$redis_db_numbers" = "all" ]; then
    log "获取Redis数据库数量..."
    # 获取Redis数据库数量
    local db_count=$(redis-cli -h "$redis_host" -p "$redis_port" $auth_param info keyspace | grep -o "db[0-9]*" | sort -V | tail -1 | sed 's/db//')
    if [ -z "$db_count" ]; then
      db_count=15  # 默认数据库数量
    fi
    local db_list=$(seq 0 "$db_count")
  else
    local db_list=$(echo "$redis_db_numbers" | tr ',' ' ')
  fi
  
  # 备份每个数据库
  for db in $db_list; do
    log "备份Redis数据库: $db"
    redis-cli -h "$redis_host" -p "$redis_port" $auth_param -n "$db" --rdb "$temp_dir/dump_${db}.rdb"
    if [ $? -ne 0 ]; then
      log "备份Redis数据库 $db 失败"
      continue
    fi
  done
  
  # 压缩备份文件
  log "压缩Redis备份文件..."
  cd "$temp_dir" && tar -czf "/backup/redis/$backup_file.tar.gz" .
  
  # 清理
  rm -rf "$temp_dir"
  
  local backup_path="/backup/redis/$backup_file.tar.gz"
  
  # 清理过期备份
  cleanup_old_backups "/backup/redis" "redis"
  
  log "Redis备份完成: $backup_path"
  
  # 如果启用S3存储，上传备份文件到S3
  if is_s3_enabled && check_s3_config; then
    upload_to_s3 "$backup_path" "redis/$backup_file.tar.gz"
  fi
}

# 主函数
main() {
  log "数据库备份开始执行..."
  
  # 确保备份主目录存在
  check_backup_dir "/backup"
  
  # 执行各数据库的备份
  backup_postgresql
  backup_mysql
  backup_redis
  
  log "所有数据库备份完成!"
}

# 执行主函数
main