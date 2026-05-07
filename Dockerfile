# ==================== 阶段1: 构建阶段 ====================
FROM ubuntu:22.04 AS builder

# 设置环境变量，避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 更换为阿里云镜像源，加速软件包下载
RUN sed -i 's@//.*archive.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list && \
    sed -i 's@//.*security.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list

# 安装Node.js和构建工具
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    build-essential \
    python3 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 安装pnpm包管理器
RUN npm install -g pnpm@9.4.0

# 设置工作目录
WORKDIR /app

# 复制package.json和lock文件，利用Docker缓存加速构建
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY front-end/package.json ./front-end/
COPY back-end/package.json ./back-end/

# 安装所有依赖
RUN pnpm install --frozen-lockfile

# 复制源代码
COPY . .

# 构建后端项目
WORKDIR /app/back-end
RUN pnpm run build

# 构建前端项目
WORKDIR /app/front-end
RUN pnpm run build

# ==================== 阶段2: 生产阶段 ====================
FROM ubuntu:22.04 AS production

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV NODE_ENV=production

# 更换为阿里云镜像源
RUN sed -i 's@//.*archive.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list && \
    sed -i 's@//.*security.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list

# 安装Node.js运行时和supervisor进程管理器
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    supervisor \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 安装pnpm（生产环境需要用来运行workspace）
RUN npm install -g pnpm@9.4.0

# 设置工作目录
WORKDIR /app

# 复制package.json和lock文件
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY front-end/package.json ./front-end/
COPY back-end/package.json ./back-end/

# 从构建阶段复制后端构建产物
COPY --from=builder /app/back-end/dist ./back-end/dist

# 从构建阶段复制前端构建产物
COPY --from=builder /app/front-end/dist ./front-end/dist

# 安装生产依赖（pnpm会自动处理workspace链接）
RUN pnpm install --prod --frozen-lockfile

# 创建supervisor配置文件，管理前后端进程
RUN mkdir -p /var/log/supervisor
COPY <<EOF /etc/supervisor/conf.d/wuziqi.conf
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:backend]
command=node dist/main.js
directory=/app/back-end
autostart=true
autorestart=true
startsecs=5
stderr_logfile=/var/log/supervisor/backend.err.log
stdout_logfile=/var/log/supervisor/backend.out.log
environment=NODE_ENV="production",PORT="3000"

[program:frontend]
command=npx serve -s . -l 8888
directory=/app/front-end/dist
autostart=true
autorestart=true
startsecs=5
stderr_logfile=/var/log/supervisor/frontend.err.log
stdout_logfile=/var/log/supervisor/frontend.out.log
environment=NODE_ENV="production"
EOF

# 安装serve用于前端静态文件服务
RUN npm install -g serve

# 暴露端口：前端8888，后端3000
EXPOSE 8888 3000

# 创建健康检查脚本
RUN echo '#!/bin/bash\ncurl -f http://localhost:3000 > /dev/null 2>&1 && curl -f http://localhost:8888 > /dev/null 2>&1' > /healthcheck.sh && \
    chmod +x /healthcheck.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /healthcheck.sh || exit 1

# 启动supervisor，管理前后端服务
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/wuziqi.conf"]
