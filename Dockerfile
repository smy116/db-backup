FROM alpine:latest

LABEL org.opencontainers.image.source=https://github.com/owner/db-backup
LABEL org.opencontainers.image.description="数据库定时备份容器，支持PostgreSQL、MySQL和Redis"
LABEL org.opencontainers.image.licenses="MIT"

# 安装必要的软件包
RUN apk update && apk add --no-cache \
    postgresql-client \
    mysql-client \
    tar \
    zip \
    unzip \
    tzdata \
    dcron \
    ca-certificates \
    bash \
    s3cmd \
    py3-pip

# 设置默认时区
ENV TZ="Asia/Shanghai"
RUN cp /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone

# 设置本地化环境为中文
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN:zh
ENV LC_ALL=zh_CN.UTF-8

# 创建应用目录和备份目录
RUN mkdir -p /app /backup /backup/pg /backup/mysql

# 拷贝脚本
COPY backup.sh /app/
COPY entrypoint.sh /app/

# 设置脚本执行权限
RUN chmod +x /app/backup.sh /app/entrypoint.sh

# 设置环境变量默认值
ENV CRON_SCHEDULE="0 3 * * *"
ENV ENABLE_PG="false"
ENV ENABLE_MYSQL="false"
ENV BACKUP_ON_START="false"
ENV STORAGE_TYPE="local"
ENV S3_USE_PATH_STYLE="false"
ENV RETENTION_DAYS="30"

# 持久化备份目录
VOLUME ["/backup"]

# 设置工作目录
WORKDIR /app

# 入口脚本
ENTRYPOINT ["/app/entrypoint.sh"]