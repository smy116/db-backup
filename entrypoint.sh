#!/bin/bash
set -e

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

# 默认的cron表达式（每天凌晨3点执行）
DEFAULT_CRON_SCHEDULE="0 3 * * *"

# 设置时区
set_timezone

log "配置数据库备份定时任务..."

# 获取cron调度表达式（或使用默认值）
CRON_SCHEDULE=${CRON_SCHEDULE:-$DEFAULT_CRON_SCHEDULE}

# 确保脚本可执行
chmod +x /app/backup.sh

# 写入新的crontab配置
log "设置Cron计划: $CRON_SCHEDULE"
echo "$CRON_SCHEDULE /app/backup.sh >> /var/log/cron.log 2>&1" > /etc/cron.d/db-backup
chmod 0644 /etc/cron.d/db-backup

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
crond -f &

# 立即执行一次备份（如果BACKUP_ON_START为true）
if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  log "执行初始备份..."
  /app/backup.sh
fi

# 输出日志到标准输出
log "启动日志监控..."
tail -f /var/log/cron.log