FROM alpine:latest

LABEL org.opencontainers.image.source=https://github.com/owner/db-backup
LABEL org.opencontainers.image.description="数据库定时备份容器，支持PostgreSQL、MySQL和Redis"
LABEL org.opencontainers.image.licenses="MIT"

# 安装必要的软件包
# 添加构建依赖的示例
RUN apk update && \
    apk add --no-cache \
        # 您现有的包
        postgresql-client \
        mysql-client \
        redis \
        tar \
        tzdata \
        dcron \
        ca-certificates \
        bash \
        python3 \
        py3-pip \
        # 添加构建依赖
        build-base \
        python3-dev \
        musl-dev \
        libffi-dev \
        openssl-dev \
        cargo \
        # 可能还有其他 awscli 特定的需求
    && pip3 install --no-cache-dir awscli && \
    # 可选：pip 安装成功后删除构建依赖，以保持镜像大小
    apk del build-base python3-dev musl-dev libffi-dev openssl-dev cargo

# 设置默认时区
ENV TZ="Asia/Shanghai"
RUN cp /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone

# 设置本地化环境为中文
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN:zh
ENV LC_ALL=zh_CN.UTF-8

# 创建应用目录和备份目录
RUN mkdir -p /app /backup /backup/pg /backup/mysql /backup/redis

# 拷贝脚本
COPY backup.sh /app/
COPY entrypoint.sh /app/

# 设置脚本执行权限
RUN chmod +x /app/backup.sh /app/entrypoint.sh

# 设置环境变量默认值
ENV CRON_SCHEDULE="0 3 * * *"
ENV ENABLE_PG="false"
ENV ENABLE_MYSQL="false"
ENV ENABLE_REDIS="false"
ENV BACKUP_ON_START="false"

# S3存储相关环境变量
ENV STORAGE_TYPE="local"
ENV S3_BUCKET=""
ENV AWS_ACCESS_KEY_ID=""
ENV AWS_SECRET_ACCESS_KEY=""
ENV AWS_DEFAULT_REGION="us-east-1"
ENV AWS_ENDPOINT_URL=""
ENV AWS_USE_PATH_STYLE="false"
ENV S3_DELETE_LOCAL_AFTER_UPLOAD="false"

# 持久化备份目录
VOLUME ["/backup"]

# 设置工作目录
WORKDIR /app

# 入口脚本
ENTRYPOINT ["/app/entrypoint.sh"]
