#!/bin/sh
# set -e # 延迟到trap设置之后

# --- 清理陷阱 ---
# 初始化一个字符串，用于存储需要清理的临时文件/目录的路径，以换行符分隔
TEMP_ITEMS_TO_CLEAN=""

# 脚本退出时执行的清理函数
cleanup_on_exit() {
  local exit_code=$? # 捕获脚本的退出码
  log "信息：脚本退出时执行清理 (退出码: $exit_code)..."
  
  # POSIX兼容的循环，用于处理以换行符分隔的字符串
  if [ -n "$TEMP_ITEMS_TO_CLEAN" ]; then
    _old_ifs="$IFS" # 保存当前IFS
    # shellcheck disable=SC2034 # IFS is used by read in the while loop below
    IFS='
' # 将IFS设置为空格和换行符，以便正确分割字符串
    
    # 使用printf将字符串提供给while read循环
    # 这能正确处理路径中的特殊字符
    printf "%s\n" "$TEMP_ITEMS_TO_CLEAN" | while IFS= read -r item; do
      # 确保item不为空，如果TEMP_ITEMS_TO_CLEAN有前导/尾随换行符，则可能发生这种情况
      # （尽管建议的添加逻辑应能防止这种情况）
      if [ -n "$item" ]; then 
        if [ -e "$item" ]; then # 检查文件/目录是否存在
          # 日志消息已翻译："信息：正在移除临时项: $item"
          log "信息：正在移除临时项: $item"
          rm -rf "$item"
        fi
      fi
    done
    IFS="$_old_ifs" # 恢复IFS
  fi
  
  log "信息：清理完成。"
  # 如果脚本因 'set -e' 捕获的错误或显式的 'exit N' 而退出，
  # 我们应该保留该退出码。
  # 然而，EXIT上的trap在脚本自身的退出处理之后运行。
  # 因此，除非我们想覆盖它，否则此处不需要显式地 'exit $exit_code'。
}

# 为EXIT、INT (Ctrl+C)、TERM信号设置陷阱
trap cleanup_on_exit EXIT INT TERM

# 现在启用错误时退出
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


#
# 数据库备份脚本
#
# 功能:
# - 支持 PostgreSQL 和 MySQL/MariaDB 数据库备份。
# - 支持备份到本地或通过 rclone 备份到远程存储。
# - 支持备份加密。
# - 支持自定义备份保留天数和自动清理过期备份。
#

# --- 全局设置与工具函数 ---

# 日志函数: 统一日志输出格式，包含时间戳。
# 参数 $1: 需要记录的日志信息。
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 检查加密配置: 如果启用了加密但未提供密码，则报错并退出。
check_encryption_config() {
  if [ "$ENABLE_ENCRYPTION" = "true" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
    log "错误：备份加密已启用但未提供加密密码 (ENCRYPTION_PASSWORD)。请设置密码或禁用加密。"
    exit 1 # 关键配置错误，直接退出
  fi
}

# 配置rclone: 检查或创建rclone配置文件，并测试连接。
# 如果rclone配置无效，脚本可以继续执行本地备份（如果远程存储不是必须的）。
configure_rclone() {
  # 检查用户是否提供了rclone配置文件
  if [ -f "$RCLONE_CONFIG_PATH" ]; then
    log "使用现有rclone配置文件: $RCLONE_CONFIG_PATH"
  else
    # 如果用户未提供配置文件，则创建一个默认配置，将备份存储在本地 /backup 目录
    log "配置文件不存在，创建默认的backup配置..."
    mkdir -p /backup  # 确保基础备份目录存在
    mkdir -p "$(dirname "$RCLONE_CONFIG_PATH")"  # 确保配置文件所在目录存在
    
    # 创建一个名为 [backup] 的rclone remote，类型为alias，指向本地 /backup 路径
    # 这使得脚本在没有外部rclone配置时也能工作，但仅限于本地备份。
    cat > "$RCLONE_CONFIG_PATH" <<EOF
[backup]
type = alias
remote = /backup
EOF
    log "已创建默认配置文件: $RCLONE_CONFIG_PATH，指向本地/backup目录"
  fi
  
  # 测试rclone是否能够访问名为 "backup:" 的远程存储
  # --no-check-certificate: 忽略SSL证书检查，便于使用自签名证书等情况
  log "测试backup存储系统连接..."
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate lsd backup:
  if [ $? -ne 0 ]; then
    log "错误: 无法连接到backup存储系统，请检查rclone配置 (路径: $RCLONE_CONFIG_PATH)"
    return 1 # rclone配置测试失败，返回错误码
  fi
  
  log "rclone backup配置验证成功"
  return 0 # rclone配置成功
}

# 检查并创建备份目录: 如果指定的目录不存在，则创建它。
# 参数 $1: 需要检查或创建的目录路径。
check_backup_dir() {
  local dir=$1
  if [ ! -d "$dir" ]; then
    log "创建备份目录: $dir"
    mkdir -p "$dir"
  fi
}

# --- 核心备份操作函数 ---

# 使用rclone上传文件: 将本地文件复制到rclone远程存储。
# 参数 $1 (local_file): 本地待上传文件的路径。
# 参数 $2 (remote_path): 在rclone远程存储上的目标路径 (通常包含文件名)。
upload_with_rclone() {
  local local_file=$1
  local remote_path=$2 # 例如 "pg/pg_backup_YYYYMMDD_HHMMSS.zip"
  
  # ${remote_path%/*} 用于提取远程路径中的目录部分 (例如 "pg/")
  log "上传文件到backup存储: $local_file -> backup:${remote_path%/*}/"
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate copy "$local_file" "backup:${remote_path%/*}/"
  if [ $? -ne 0 ]; then
    log "上传文件失败: $local_file"
    return 1 # 上传失败，返回错误码
  fi
  
  log "文件成功上传到backup存储: backup:$remote_path"
  
  # 上传成功后，删除本地的临时备份文件以节省空间
  rm -f "$local_file"
  log "已删除本地临时备份文件: $local_file"

  return 0 # 上传成功
}

# 压缩并上传备份: 将指定目录下的内容压缩成zip文件，可选加密，然后上传。
# 参数 $1 (temp_dir): 包含待压缩文件的临时目录。
# 参数 $2 (local_backup_path): 压缩后生成的本地zip文件的完整路径。
# 参数 $3 (remote_path): 在rclone远程存储上的目标路径 (包含文件名)。
compress_and_upload_backup() {
  local temp_dir=$1             # 例如 /tmp/pg_backup.XXXXXX
  local local_backup_path=$2    # 例如 /tmp/pg_backup.XXXXXX/pg_backup_YYYYMMDD_HHMMSS.zip
  local remote_path=$3          # 例如 pg/pg_backup_YYYYMMDD_HHMMSS.zip

  # 切换到临时目录进行压缩，这样zip包内的文件路径是相对的
  cd "$temp_dir" || { log "错误: 无法进入临时目录 $temp_dir"; return 1; }
  
  local zip_file_name
  zip_file_name=$(basename "$local_backup_path") # 提取zip文件名用于日志

  # 根据 ENABLE_ENCRYPTION 环境变量决定是否加密压缩
  if [ "$ENABLE_ENCRYPTION" = "true" ]; then
    log "开始加密压缩 $zip_file_name 到 $local_backup_path..."
    # -q: 安静模式; -r: 递归处理目录; -e: 加密; -P: 指定密码
    if ! zip -q -r -e -P "$ENCRYPTION_PASSWORD" "$local_backup_path" .; then
      log "错误: 加密压缩 $zip_file_name 失败。"
      rm -rf "$temp_dir" # 清理临时目录
      return 1 # 压缩失败，返回错误码
    fi
    log "备份文件已加密压缩: $local_backup_path"
  else
    log "开始压缩 $zip_file_name 到 $local_backup_path..."
    # -q: 安静模式; -r: 递归处理目录
    if ! zip -q -r "$local_backup_path" .; then
      log "错误: 压缩 $zip_file_name 失败。"
      rm -rf "$temp_dir" # 清理临时目录
      return 1 # 压缩失败，返回错误码
    fi
    log "备份文件已压缩: $local_backup_path"
  fi

  # 调用 upload_with_rclone 函数上传压缩好的备份文件
  if ! upload_with_rclone "$local_backup_path" "$remote_path"; then
    log "错误: 上传 $local_backup_path 失败。"
    # upload_with_rclone 成功后会删除 $local_backup_path。
    # 如果上传失败，该文件可能仍然存在。无论如何，都需要清理整个 $temp_dir。
    rm -rf "$temp_dir"
    return 1 # 上传失败，返回错误码
  fi
  
  # $local_backup_path (即 $temp_dir/$zip_file_name) 已被 upload_with_rclone 删除。
  # 此处清理 $temp_dir 是为了删除原始的转储文件 (如 .sql 或 .dump 文件)。
  rm -rf "$temp_dir"
  log "已清理临时工作目录: $temp_dir (包含原始转储文件)"
  
  return 0 # 压缩和上传均成功
}


# 清理过期备份: 删除远程存储中超过指定保留天数的备份。
# 参数 $1 (backup_dir): 本地基础备份目录名，用于推断远程路径前缀 (如 /backup/pg -> pg/)
cleanup_old_backups() {
  local backup_dir=$1 # 例如 /backup/pg 或 /backup/mysql
  
  # 从 $backup_dir 提取最后一个路径组件作为远程路径的前缀
  # 例如, /backup/pg -> pg. 这用于指定rclone操作的子目录。
  local prefix
  prefix=$(basename "$backup_dir") 
  
  log "清理backup存储中超过 ${RETENTION_DAYS} 天的备份文件 (路径前缀: $prefix/)"
  
  # 使用 rclone delete --min-age 删除早于 RETENTION_DAYS 的文件
  # set +e / set -e: 临时禁用 "exit on error"，以便捕获rclone的退出码并自定义处理。
  set +e 
  rclone --config "$RCLONE_CONFIG_PATH" --no-check-certificate delete --min-age "${RETENTION_DAYS}d" "backup:${prefix}/"
  local rclone_exit_code=$?
  set -e 

  if [ $rclone_exit_code -ne 0 ]; then
    log "错误: 清理backup存储中的过期备份失败 (命令退出码: $rclone_exit_code)。路径: backup:${prefix}/"
    return 1 # 清理失败，返回错误码
  fi
  
  log "成功清理过期备份: backup:${prefix}/"
  return 0 # 清理成功
}

# --- PostgreSQL特定备份函数 ---
backup_postgresql() {
  # 如果禁用了PostgreSQL备份，则记录信息并退出函数
  if [ "$ENABLE_PG" != "true" ]; then
    log "PostgreSQL备份已禁用 (ENABLE_PG != true)"
    return 0 # 并非错误，按预期跳过
  fi
  
  log "开始备份PostgreSQL数据库..."
  
  # 确保PostgreSQL的本地备份目录存在 (例如 /backup/pg)
  check_backup_dir "/backup/pg"
  
  # 创建一个唯一的临时目录来存储数据库转储文件
  local temp_dir
  temp_dir=$(mktemp -d -p "/tmp" "pg_backup.XXXXXX") # 在/tmp下创建，避免填满/backup
  # 为trap清理注册 (POSIX兼容方式)
  if [ -z "$TEMP_ITEMS_TO_CLEAN" ]; then
    TEMP_ITEMS_TO_CLEAN="$temp_dir"
  else
    TEMP_ITEMS_TO_CLEAN=$(printf "%s\n%s" "$TEMP_ITEMS_TO_CLEAN" "$temp_dir")
  fi
  log "信息：已为PostgreSQL创建临时目录: $temp_dir"
  local date_suffix
  date_suffix=$(date +"%Y%m%d_%H%M%S")
  local backup_file="pg_backup_$date_suffix" # 基础文件名，例如 pg_backup_20231027_103000
  local local_backup_path="$temp_dir/$backup_file.zip" # 压缩后的本地备份文件路径
  
  # 检查PostgreSQL密码是否已设置，密码是必需的
  if [ -z "$PG_PASSWORD" ]; then
    log "错误：PostgreSQL备份已启用但未提供密码 (PG_PASSWORD)。关键错误，退出脚本。"
    exit 1 # 密码缺失是关键错误，终止整个脚本
  fi
  # 将PG_PASSWORD导出为环境变量，pg_dump和psql会自动使用它

  export PGPASSWORD=$PG_PASSWORD
  log "信息：已为pg_dump/psql设置PGPASSWORD。"
  
  # --- 获取数据库列表 ---
  local db_list_retrieved_successfully=0 # 标记数据库列表是否成功获取
  local db_list # 存储待备份的数据库名称列表
  if [ "$PG_DATABASES" = "all" ]; then
    log "配置为备份所有PostgreSQL数据库 (PG_DATABASES=all)。正在获取数据库列表..."
    # 临时禁用 'exit on error' (set -e) 以便捕获psql的错误
    set +e
    # psql 命令:
    # -h, -p, -U: 主机、端口、用户
    # -t: 仅输出元组 (数据行)，无表头
    # -A: 不对齐输出 (每行一个数据库名，更易处理)
    # -c "SELECT ...": 执行SQL查询以获取非模板数据库的列表
    # 2>/dev/null: 抑制psql自身的错误输出，我们将通过退出码判断成功与否
    db_list=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -t -A -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres')" 2>/dev/null)
    local psql_exit_code=$?
    set -e # 重新启用 'exit on error'

    if [ $psql_exit_code -ne 0 ]; then
      log "错误: 无法获取PostgreSQL数据库列表 (psql退出码: $psql_exit_code)。请检查连接参数、网络、权限和PostgreSQL服务状态。"
      export PGPASSWORD="" # 清理密码环境变量
      rm -rf "$temp_dir"   # 清理临时目录
      return 1 # 获取列表失败，返回错误，这将导致main函数设置SCRIPT_HAS_ERRORS=1
    fi
    # 将psql输出的换行符替换为空格，以得到空格分隔的数据库列表
    db_list=$(echo "$db_list" | tr '\n' ' ')
    log "获取到的数据库列表: $db_list"
    db_list_retrieved_successfully=1
  else
    # 如果 PG_DATABASES 不是 "all"，则假定它是逗号分隔的数据库名列表
    log "配置为备份指定的PostgreSQL数据库: $PG_DATABASES"
    db_list=$(echo "$PG_DATABASES" | tr ',' ' ') # 将逗号替换为空格
    db_list_retrieved_successfully=1 # 假设用户提供的列表是有效的
  fi

  # 检查最终的数据库列表是否为空
  if [ "$db_list_retrieved_successfully" -eq 0 ] || [ -z "$(echo "$db_list" | tr -d ' ')" ]; then
    log "错误: PostgreSQL数据库列表为空或无法检索。请检查PG_DATABASES配置或数据库状态。"
    export PGPASSWORD="" # 清理密码
    rm -rf "$temp_dir"   # 清理临时目录
    return 1 # 列表为空，返回错误
  fi
  
  # --- 执行数据库备份 ---
  local overall_dump_success=1 # 标记所有数据库是否都成功转储 (1=成功, 0=失败)
  log "开始逐个备份以下PostgreSQL数据库: $db_list"
  for db in $db_list; do
    # 跳过列表中的空项 (如果输入有误，例如 "db1, ,db2")
    if [ -z "$db" ]; then
        continue
    fi
    log "正在备份PostgreSQL数据库: $db 到 $temp_dir/${db}.dump ..."
    # pg_dump 命令:
    # -F c: 自定义归档格式 (推荐，允许更灵活的恢复选项)
    # -b: 包含大对象 (BLOBs)
    # -v: 详细模式
    # -f: 输出文件名
    if ! pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -F c -b -v -f "$temp_dir/${db}.dump" "$db"; then
      log "错误: 备份PostgreSQL数据库 '$db' 失败。检查pg_dump日志输出。"
      overall_dump_success=0 # 标记至少有一个数据库备份失败
      # 继续尝试备份列表中的其他数据库
    else
      log "PostgreSQL数据库 '$db' 备份成功: $temp_dir/${db}.dump"
    fi
  done
  
  # 清理 PGPASSWORD 环境变量，避免其在后续命令中意外使用
  export PGPASSWORD=""

  # 如果任何一个数据库转储失败，则报告错误并中止此备份类型
  if [ $overall_dump_success -eq 0 ]; then
    log "错误: 一个或多个PostgreSQL数据库备份失败。请查看之前的错误日志。"
    rm -rf "$temp_dir" # 清理可能包含部分成功转储的临时目录
    return 1 # 指示PostgreSQL备份过程有错误
  fi

  # 检查是否有任何转储文件实际生成 (例如，如果列表是空的或所有db都无效)
  if [ -z "$(ls -A "$temp_dir" | grep '\.dump$')" ]; then
    log "警告: 在 '$temp_dir' 中没有找到成功的PostgreSQL数据库转储文件 (.dump)。可能是数据库列表为空或所有指定数据库均无法访问。"
    rm -rf "$temp_dir"
    return 1 # 没有文件可备份，视为失败
  fi

  # --- 压缩和上传 ---
  log "所有选定的PostgreSQL数据库均已成功转储。开始压缩和上传..."
  if ! compress_and_upload_backup "$temp_dir" "$local_backup_path" "pg/$backup_file.zip"; then
    log "错误: PostgreSQL备份压缩或上传失败 (目标: pg/$backup_file.zip)。"
    # temp_dir 由 compress_and_upload_backup 在成功或失败时清理
    return 1 # 压缩或上传失败，视为PostgreSQL备份过程的错误
  fi
  log "PostgreSQL备份压缩并成功上传到: pg/$backup_file.zip"
  
  # --- 清理旧备份 ---
  # 注意: 清理失败本身不应导致整个备份任务失败。
  if ! cleanup_old_backups "/backup/pg"; then
    log "警告: 清理旧的PostgreSQL备份失败。但这不会影响当前备份的成功状态。"
    # 不返回1，因为备份和上传本身是成功的
  fi
  
  log "PostgreSQL数据库备份过程成功完成。"
  return 0 # PostgreSQL备份全部成功
}

# --- MySQL/MariaDB特定备份函数 ---
backup_mysql() {
  # 如果禁用了MySQL备份，则记录信息并退出函数
  if [ "$ENABLE_MYSQL" != "true" ]; then
    log "MySQL/MariaDB备份已禁用 (ENABLE_MYSQL != true)"
    return 0 # 并非错误，按预期跳过
  fi
  
  log "开始备份MySQL/MariaDB数据库..."
  
  # 确保MySQL的本地备份目录存在 (例如 /backup/mysql)
  check_backup_dir "/backup/mysql"
  # 创建一个唯一的临时目录来存储数据库转储文件和临时配置文件
  local temp_dir
  temp_dir=$(mktemp -d -p "/tmp" "mysql_backup.XXXXXX") # 在/tmp下创建
  # 为trap清理注册 (POSIX兼容方式)
  if [ -z "$TEMP_ITEMS_TO_CLEAN" ]; then
    TEMP_ITEMS_TO_CLEAN="$temp_dir"
  else
    TEMP_ITEMS_TO_CLEAN=$(printf "%s\n%s" "$TEMP_ITEMS_TO_CLEAN" "$temp_dir")
  fi
  log "信息：已为MySQL/MariaDB创建临时目录: $temp_dir"
  local date_suffix
  date_suffix=$(date +"%Y%m%d_%H%M%S")
  local backup_file="mysql_backup_$date_suffix" # 基础文件名
  local local_backup_path="$temp_dir/$backup_file.zip" # 压缩后的本地备份文件路径
  
  # 检查MySQL密码是否已设置，密码是必需的
  if [ -z "$MYSQL_PASSWORD" ]; then
    log "错误：MySQL/MariaDB备份已启用但未提供密码 (MYSQL_PASSWORD)。关键错误，退出脚本。"
    exit 1 # 密码缺失是关键错误，终止整个脚本
  fi
  
  # 为MySQL客户端命令创建一个临时的my.cnf配置文件，包含连接参数和密码。
  # 这避免了在命令行中直接暴露密码，并允许统一配置。
  # skip-ssl = true: 默认跳过SSL，如果需要SSL，用户应在自定义RCLONE_CONFIG_PATH中配置
  log "在 $temp_dir/my.cnf 创建临时MySQL客户端配置文件..."
  cat > "$temp_dir/my.cnf" <<EOF
[client]
host=$MYSQL_HOST
port=$MYSQL_PORT
user=$MYSQL_USER
password=$MYSQL_PASSWORD
skip-ssl = true
EOF
  
  # --- 获取数据库列表 ---
  local db_list_retrieved_successfully=0 # 标记数据库列表是否成功获取
  local db_list # 存储待备份的数据库名称列表
  if [ "$MYSQL_DATABASES" = "all" ]; then
    log "配置为备份所有MySQL/MariaDB数据库 (MYSQL_DATABASES=all)。正在获取数据库列表..."
    # 临时禁用 'exit on error' (set -e) 以便捕获客户端命令的错误
    set +e
    # 尝试使用 mariadb 客户端获取数据库列表 (MariaDB 10.2+ 推荐)
    # -N: 跳过列名 (仅输出数据)
    # -e "SHOW DATABASES": 执行SQL查询
    # 2>/dev/null: 抑制客户端自身的错误输出
    log "尝试使用 'mariadb' 客户端获取数据库列表..."
    db_list=$(mariadb --defaults-file="$temp_dir/my.cnf" -N -e "SHOW DATABASES" 2>/dev/null)
    local mariadb_exit_code=$?
    
    if [ $mariadb_exit_code -ne 0 ]; then
      # 如果 mariadb 客户端失败 (例如未安装或版本问题)，则回退到 mysql 客户端
      log "使用 'mariadb' 客户端获取列表失败 (退出码: $mariadb_exit_code)。尝试使用 'mysql' 客户端..."
      db_list=$(mysql --defaults-file="$temp_dir/my.cnf" -N -e "SHOW DATABASES" 2>/dev/null)
      local mysql_exit_code=$?
      if [ $mysql_exit_code -ne 0 ]; then
        log "错误: 无法获取MySQL/MariaDB数据库列表 (mysql退出码: $mysql_exit_code)。请检查连接参数、凭据、网络、权限以及MySQL/MariaDB服务状态。"
        rm -f "$temp_dir/my.cnf" # 清理临时配置文件
        rm -rf "$temp_dir"       # 清理临时目录
        set -e # 重新启用 'exit on error'
        return 1 # 获取列表失败，返回错误
      fi
    fi
    set -e # 重新启用 'exit on error'

    # 过滤掉MySQL/MariaDB的内部系统数据库
    log "原始数据库列表: $db_list"
    db_list=$(echo "$db_list" | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" | tr '\n' ' ')
    log "过滤后的数据库列表: $db_list"
    db_list_retrieved_successfully=1
  else
    # 如果 MYSQL_DATABASES 不是 "all"，则假定它是逗号分隔的数据库名列表
    log "配置为备份指定的MySQL/MariaDB数据库: $MYSQL_DATABASES"
    db_list=$(echo "$MYSQL_DATABASES" | tr ',' ' ') # 将逗号替换为空格
    db_list_retrieved_successfully=1 # 假设用户提供的列表是有效的
  fi

  # 检查最终的数据库列表是否为空
  if [ "$db_list_retrieved_successfully" -eq 0 ] || [ -z "$(echo "$db_list" | tr -d ' ')" ]; then
    log "错误: MySQL/MariaDB数据库列表为空或无法检索。请检查MYSQL_DATABASES配置或数据库状态。"
    rm -f "$temp_dir/my.cnf" # 清理临时配置文件
    rm -rf "$temp_dir"       # 清理临时目录
    return 1 # 列表为空，返回错误
  fi
  
  # --- 执行数据库备份 ---
  local overall_dump_success=1 # 标记所有数据库是否都成功转储 (1=成功, 0=失败)
  log "开始逐个备份以下MySQL/MariaDB数据库: $db_list"
  for db in $db_list; do
    # 跳过列表中的空项
    if [ -z "$db" ]; then
        continue
    fi
    log "正在备份MySQL/MariaDB数据库: $db ..."
    local dump_log_file="$temp_dir/${db}.dump.log" # 用于捕获转储命令的错误输出
    local db_dump_successful=0 # 标记当前数据库是否成功转储

    # 转储参数:
    # --defaults-file: 指定包含凭据的配置文件
    # --databases: 指定要转储的数据库
    # --single-transaction: 对于InnoDB表，确保一致性备份，不长时间锁定表
    # --skip-lock-tables: (mariadb-dump特定) 避免使用LOCK TABLES，与--single-transaction一起使用时推荐
    # --routines: 备份存储过程和函数
    # --triggers: 备份触发器
    # --events: 备份计划事件
    # 输出重定向到 .sql 文件，错误输出到 .dump.log 文件

    log "尝试使用 'mariadb-dump' (带 --skip-lock-tables) 备份 '$db' 到 $temp_dir/${db}.sql ..."
    if mariadb-dump --defaults-file="$temp_dir/my.cnf" --databases "$db" \
      --single-transaction --skip-lock-tables --routines --triggers --events > "$temp_dir/${db}.sql" 2> "$dump_log_file"; then
      log "数据库 '$db' 使用 'mariadb-dump' (带 --skip-lock-tables) 备份成功。"
      db_dump_successful=1
    else
      log "使用 'mariadb-dump' (带 --skip-lock-tables) 备份 '$db' 失败。错误信息:"
      cat "$dump_log_file" # 显示错误日志
      
      log "尝试使用 'mariadb-dump' (不带 --skip-lock-tables) 备份 '$db'..."
      if mariadb-dump --defaults-file="$temp_dir/my.cnf" --databases "$db" \
        --single-transaction --routines --triggers --events > "$temp_dir/${db}.sql" 2> "$dump_log_file"; then
        log "数据库 '$db' 使用 'mariadb-dump' (不带 --skip-lock-tables) 备份成功。"
        db_dump_successful=1
      else
        log "使用 'mariadb-dump' (不带 --skip-lock-tables) 备份 '$db' 失败。错误信息:"
        cat "$dump_log_file" # 显示错误日志
        
        log "尝试使用 'mysqldump' 备份 '$db'..."
        if mysqldump --defaults-file="$temp_dir/my.cnf" --databases "$db" \
          --single-transaction --routines --triggers --events > "$temp_dir/${db}.sql" 2> "$dump_log_file"; then
          log "数据库 '$db' 使用 'mysqldump' 备份成功。"
          db_dump_successful=1
        else
          log "使用 'mysqldump' 备份 '$db' 失败。错误信息:"
          cat "$dump_log_file" # 显示错误日志
          log "错误: 备份MySQL/MariaDB数据库 '$db' 在所有尝试后均失败。"
          overall_dump_success=0 # 标记至少有一个数据库备份彻底失败
        fi
      fi
    fi
    rm -f "$dump_log_file" # 清理当前数据库的转储日志文件
  done

  # 清理所有可能的剩余转储日志文件和临时配置文件
  rm -f "$temp_dir"/*.dump.log 
  rm -f "$temp_dir/my.cnf"

  # 如果任何一个数据库转储失败，则报告错误并中止此备份类型
  if [ $overall_dump_success -eq 0 ]; then
    log "错误: 一个或多个MySQL/MariaDB数据库备份失败。请查看之前的错误日志。"
    rm -rf "$temp_dir" # 清理可能包含部分成功转储的临时目录
    return 1 # 指示MySQL备份过程有错误
  fi
  
  # 检查是否有任何 .sql 转储文件实际生成
  if [ -z "$(ls -A "$temp_dir" | grep '\.sql$')" ]; then
    log "警告: 在 '$temp_dir' 中没有找到成功的MySQL/MariaDB数据库转储文件 (.sql)。可能是数据库列表为空或所有指定数据库均无法访问。"
    rm -rf "$temp_dir"
    return 1 # 没有文件可备份，视为失败
  fi
  
  # --- 压缩和上传 ---
  log "所有选定的MySQL/MariaDB数据库均已成功转储。开始压缩和上传..."
  if ! compress_and_upload_backup "$temp_dir" "$local_backup_path" "mysql/$backup_file.zip"; then
    log "错误: MySQL/MariaDB备份压缩或上传失败 (目标: mysql/$backup_file.zip)。"
    # temp_dir 由 compress_and_upload_backup 在成功或失败时清理
    return 1 # 压缩或上传失败，视为MySQL备份过程的错误
  fi
  log "MySQL/MariaDB备份压缩并成功上传到: mysql/$backup_file.zip"

  # --- 清理旧备份 ---
  if ! cleanup_old_backups "/backup/mysql"; then
    log "警告: 清理旧的MySQL/MariaDB备份失败。但这不会影响当前备份的成功状态。"
  fi
  
  log "MySQL/MariaDB数据库备份过程成功完成。"
  return 0 # MySQL备份全部成功
}

# --- 主逻辑执行函数 ---
main() {
  # SCRIPT_HAS_ERRORS: 全局错误标志。0表示无错误，1表示至少有一个关键步骤失败。
  # 此标志用于决定脚本最终的退出状态码。
  # 此变量将由main函数的显式exit调用检查。
  # 如果它是最后一条命令，trap的exit_code将反映此情况。
  SCRIPT_HAS_ERRORS=0
  log "信息：数据库备份脚本已启动。" # 从 "数据库备份脚本开始执行..." 更改以保持一致性

  # --- 记录工具版本 ---
  log "--- 核心工具版本信息 ---"
  if command -v rclone >/dev/null 2>&1; then
    log "Rclone 版本: $(rclone --version | head -n 1)"
  else
    log "错误：rclone 命令未找到。Rclone是核心依赖项，脚本无法正确运行。"
    SCRIPT_HAS_ERRORS=1 # rclone至关重要
  fi
  if command -v zip >/dev/null 2>&1; then
    # zip -v 的输出是多行的，第一行是 "Zip ... by Info-ZIP"，第二行是 "Zip ... version ..."
    # 然而，如果可用，简单的 "zip --version" 更标准，或者使用 "zip -v" 并解析。
    # 我们尝试获取一个简洁的版本。Zip的版本输出可能比较棘手。
    # Info-ZIP的`zip`的一个常见模式是`zip -h`获取包含版本的帮助信息，或`zip -v`获取详细版本。
    # 我们假设`zip --version`可能有效，或者使用已知的`zip -v`解析方式。
    # 后备方案：`zip -v | head -n 1` 可能会给出 "Copyright (c) 1990-2008 Info-ZIP..."
    # `zip -v | grep "Info-ZIP"` 也是一个选项。
    # 目前，我们使用一种常用方法从 zip -v 获取版本行
    log "信息：Zip 版本: $(zip -v | head -n 2 | grep 'Zip' || echo '版本信息解析失败')"
  else
    log "错误：zip 命令未找到。Zip是核心依赖项，脚本无法正确运行。"
    SCRIPT_HAS_ERRORS=1 # zip至关重要
  fi
  if command -v unzip >/dev/null 2>&1; then
    log "信息：Unzip 版本: $(unzip -v | head -n 1 | awk '{print $2}' || echo '版本信息解析失败')" # 通常是 "UnZip X.Y ..."
  else
    log "警告：unzip 命令未找到。(对此脚本的直接操作不关键)"
    # 此脚本不直接使用unzip，但了解环境信息有好处。
  fi

  if [ "$ENABLE_PG" = "true" ]; then
    if command -v pg_dump >/dev/null 2>&1; then
      log "信息：pg_dump 版本: $(pg_dump --version)"
    else
      log "错误：pg_dump 命令未找到，但已启用PostgreSQL备份 (ENABLE_PG=true)。"
      SCRIPT_HAS_ERRORS=1 # 如果启用了PG，这是一个严重问题
    fi
  fi

  if [ "$ENABLE_MYSQL" = "true" ]; then
    if command -v mysqldump >/dev/null 2>&1; then
      log "信息：mysqldump 版本: $(mysqldump --version)"
    else
      log "警告：mysqldump 命令未找到。如果mariadb-dump也找不到，MySQL/MariaDB备份将失败。"
      # 尚不设置SCRIPT_HAS_ERRORS，因为mariadb-dump可能是主要的
    fi
    if command -v mariadb-dump >/dev/null 2>&1; then
      log "信息：mariadb-dump 版本: $(mariadb-dump --version)"
    else
      log "警告：mariadb-dump 命令未找到。如果mysqldump也找不到，MySQL/MariaDB备份将失败。"
      # 如果mysqldump也未找到，则这是一个错误。
      if ! command -v mysqldump >/dev/null 2>&1; then
        log "错误：mysqldump 和 mariadb-dump 命令均未找到，但已启用MySQL/MariaDB备份 (ENABLE_MYSQL=true)。"
        SCRIPT_HAS_ERRORS=1 # 两者都缺失，对MySQL备份至关重要
      fi
    fi
    # 确保在启用MYSQL时至少有一个转储工具可用
    if ! command -v mysqldump >/dev/null 2>&1 && ! command -v mariadb-dump >/dev/null 2>&1; then
        log "错误：已启用MySQL/MariaDB备份，但 'mysqldump' 和 'mariadb-dump' 均未找到。"
        SCRIPT_HAS_ERRORS=1
    fi
  fi
  log "---------------------------"

  # 确保顶层 /backup 目录存在
  check_backup_dir "/backup"
  
  log "信息：配置的备份保留天数: $RETENTION_DAYS 天。"
  
  # 验证加密相关的环境变量设置
  check_encryption_config # 如果加密启用但密码缺失，此函数将使脚本退出
  if [ "$ENABLE_ENCRYPTION" = "true" ]; then
    log "信息：备份加密已启用 (ENABLE_ENCRYPTION=true)。"
  else
    log "信息：备份加密未启用 (ENABLE_ENCRYPTION=false)。"
  fi
  
  # 设置并验证rclone配置。
  # 如果 configure_rclone 失败 (例如，无法连接到远程存储)，
  # 脚本仍可继续执行本地备份（如果远程存储不是强制性的）。
  # 实际上传操作的失败会在各自的备份函数中处理。
  log "信息：正在验证rclone和备份存储配置..."
  if ! configure_rclone; then
    log "警告：Rclone配置验证失败或 'backup:' 远程存储无法访问。如果rclone配置为远程存储，上传可能会失败。脚本将尝试继续，可能仅执行本地备份。"
    # 根据策略，这里可以设置 SCRIPT_HAS_ERRORS=1，但当前设计是让上传步骤本身去失败。
    # 默认的rclone配置是本地文件系统，所以 configure_rclone 通常会成功。
  fi
  
  # --- 执行各数据库类型的备份 ---
  # 仅当相应的ENABLE_ flag为 "true" 时才执行备份。
  
  # PostgreSQL 备份
  if [ "$ENABLE_PG" = "true" ]; then
    log "信息：开始执行PostgreSQL备份流程..."
    if ! backup_postgresql; then
      log "错误：PostgreSQL备份流程报告了错误。详情请查看之前的日志。"
      SCRIPT_HAS_ERRORS=1 # 标记脚本执行中发生错误
    else
      log "信息：PostgreSQL备份流程成功完成。"
    fi
  else
    log "信息：已跳过PostgreSQL备份 (ENABLE_PG 非 'true')。"
  fi

  # MySQL/MariaDB 备份
  if [ "$ENABLE_MYSQL" = "true" ]; then
    log "信息：开始执行MySQL/MariaDB备份流程..."
    if ! backup_mysql; then
      log "错误：MySQL/MariaDB备份流程报告了错误。详情请查看之前的日志。"
      SCRIPT_HAS_ERRORS=1 # 标记脚本执行中发生错误
    else
      log "信息：MySQL/MariaDB备份流程成功完成。"
    fi
  else
    log "信息：已跳过MySQL/MariaDB备份 (ENABLE_MYSQL 非 'true')。"
  fi
  
  # --- 最终退出状态 ---
  if [ "$SCRIPT_HAS_ERRORS" -ne 0 ]; then
    log "错误：数据库备份脚本执行完成，但出现了一个或多个错误。请检查日志以获取详细信息。"
    exit 1 # 以错误状态码退出
  else
    log "信息：所有启用的数据库备份任务均已成功完成！"
    exit 0 # 以成功状态码退出
  fi
}

# 执行主函数，开始备份过程
main