#!/bin/sh
set -e

CRON_SCHEDULE=${CRON_SCHEDULE:-"0 3 * * *"}

# 日志函数
log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# 设置时区
set_timezone() {
  if [ -n "$TZ" ]; then
    log "设置时区: $TZ"
    cp /usr/share/zoneinfo/$TZ /etc/localtime
    echo "$TZ" > /etc/timezone
  fi
}


# 设置时区
set_timezone

log "配置数据库备份定时任务..."



# 确保脚本可执行
chmod +x /app/backup.sh

# 写入新的crontab配置
log "设置Cron计划: $CRON_SCHEDULE"
echo "$CRON_SCHEDULE root /app/backup.sh >> /var/log/cron.log 2>&1" > /etc/cron.d/db-backup
chmod 0644 /etc/cron.d/db-backup
# Debian cron 需要换行符结尾
echo "" >> /etc/cron.d/db-backup

# 打印环境变量配置信息
log "---------------------------------------"
log "数据库备份配置信息:"
log "调度时间: $CRON_SCHEDULE"
log "PostgreSQL备份: ${ENABLE_PG:-false}"
log "MySQL备份: ${ENABLE_MYSQL:-false}"
log "备份保留天数: ${RETENTION_DAYS:-30}"
log "Rclone配置路径: ${RCLONE_CONFIG_PATH:-/backup/rclone.conf}"
log "---------------------------------------"

# 创建日志文件
touch /var/log/cron.log

# 启动cron服务
log "启动cron服务..."
cron &

# 等待cron服务启动
log "等待cron服务稳定..."
sleep 2 # 给cron一点时间来启动或失败

# 检查cron服务是否正在运行
if ! pgrep cron > /dev/null; then
  log "错误：cron服务未能启动或已意外退出。计划备份将无法运行。"
  exit 1 # 退出容器，因为核心功能已失败
else
  log "信息：cron服务已成功启动并正在运行。"
fi

# 立即执行一次备份（如果BACKUP_ON_START为true）
if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  log "信息：执行初始备份 (BACKUP_ON_START=true)..."
  # 临时禁用错误时退出，以便处理初始备份的失败情况
  set +e
  /app/backup.sh
  backup_exit_code=$?
  set -e # 重新启用错误时退出

  if [ $backup_exit_code -eq 0 ]; then
    log "信息：初始备份成功完成。"
  else
    log "警告：初始备份失败 (退出码: $backup_exit_code)。详情请查看以上日志。容器将继续运行，计划备份仍将尝试执行。"
  fi
fi

# 输出日志到标准输出
log "启动日志监控 (tail -f /var/log/cron.log)..."
tail -f /var/log/cron.log