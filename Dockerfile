FROM debian:12-slim

LABEL org.opencontainers.image.source=https://github.com/smy116/db-backup
LABEL org.opencontainers.image.description="数据库定时备份容器，支持PostgreSQL、MySQL"
LABEL org.opencontainers.image.licenses="MIT"

# 添加 PostgreSQL 官方源
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/postgresql.list

# 安装必要的软件包
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    mariadb-client \
    zip \
    unzip \
    tzdata \
    cron \
    rclone \
    locales \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 设置本地化环境为中文
RUN sed -i '/zh_CN.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen zh_CN.UTF-8
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN:zh
ENV LC_ALL=zh_CN.UTF-8

# 设置默认时区
ENV TZ="Asia/Shanghai"
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone

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
ENV RCLONE_CONFIG_PATH="/backup/rclone.conf"
ENV RETENTION_DAYS="30"
ENV ENABLE_ENCRYPTION="false"

# 持久化备份目录
VOLUME ["/backup"]

# 设置工作目录
WORKDIR /app

# 入口脚本
ENTRYPOINT ["/app/entrypoint.sh"]
