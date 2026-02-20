FROM ubuntu:22.04

# 安装基础依赖
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    ca-certificates \
    netcat \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# 创建工作目录
WORKDIR /opt/zc

# 复制测试配置
COPY testdata/config/ /opt/zc/configs/

# 下载 zc 最新 release（或从本地复制）
RUN curl -fsSL https://github.com/ekil1100/zclash/releases/latest/download/zclash-linux-amd64.tar.gz | tar -xz -C /usr/local/bin/

# 验证安装
RUN zc --version

# 暴露默认端口
EXPOSE 7890 7891 7892 9090

# 默认命令
CMD ["zc", "--help"]
