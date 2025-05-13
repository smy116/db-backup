#!/bin/bash
set -e

# 日志函数
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 检查备份目录
check_backup_dir() {
  local dir=$1
  if [ ! -d "$dir" ]; then
    log "创建备份目录: $dir"
    mkdir -p "$dir"
  fi
}

# 删除过期备份（保留30天）
cleanup_old_backups() {
  local backup_dir=$1
  log "清理超过30天的备份文件: $backup_dir"
  find "$backup_dir" -name "*.tar.gz" -type f -mtime +30 -delete
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
  
  # 清理过期备份
  cleanup_old_backups "/backup/pg"
  
  log "PostgreSQL备份完成: /backup/pg/$backup_file.tar.gz"
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
  
  # 清理过期备份
  cleanup_old_backups "/backup/mysql"
  
  log "MySQL备份完成: /backup/mysql/$backup_file.tar.gz"
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
  
  # 清理过期备份
  cleanup_old_backups "/backup/redis"
  
  log "Redis备份完成: /backup/redis/$backup_file.tar.gz"
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