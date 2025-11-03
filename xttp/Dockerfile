FROM ubuntu:22.04 AS builder

WORKDIR /app

RUN apt-get update; \
    apt-get install -y wget unzip; \
    wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip; \
    unzip Xray-linux-64.zip; \
    rm -f Xray-linux-64.zip; \
    mv xray xy; \
    # 下载哪吒探针
    wget -O nezha-agent.zip https://github.com/nezhahq/agent/releases/download/v1.14.1/nezha-agent_linux_amd64.zip; \
    unzip nezha-agent.zip; \
    rm nezha-agent.zip; \
    mv nezha-agent nz; \
    chmod +x nz; \
    wget -O td https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64; \
    chmod +x td; \
    wget -O supercronic https://github.com/aptible/supercronic/releases/latest/download/supercronic-linux-amd64; \
    chmod +x supercronic

############################################################

FROM ubuntu:22.04

LABEL org.opencontainers.image.source="https://github.com/vevc/one-node"

ENV TZ=Asia/Shanghai \
    UUID=2584b733-9095-4bec-a7d5-62b473540f7a \
    DOMAIN=vevc-fml.hf.space \
    # 哪吒探针环境变量（可选）
    NZ_SERVER= \
    NZ_CLIENT_SECRET= \
    NZ_TLS=false

COPY entrypoint.sh /entrypoint.sh
COPY app /app

RUN export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    # 确保supervisor正确安装
    apt-get install -y supervisor tzdata openssh-server curl ca-certificates wget vim net-tools unzip iputils-ping telnet git iproute2 --no-install-recommends; \
    # 验证supervisor安装
    which supervisord && echo "✓ supervisord installed" || echo "✗ supervisord not found"; \
    ls -la /usr/bin/supervis* && echo "✓ supervisord binaries found"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    chmod +x /entrypoint.sh; \
    chmod -R 777 /app; \
    useradd -u 1000 -g 0 -m -s /bin/bash user; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone; \
    # 创建哪吒探针配置目录
    mkdir -p /app/nz

COPY --from=builder /app/xy /usr/local/bin/xy
COPY --from=builder /app/nz /usr/local/bin/nz
COPY --from=builder /app/td /usr/local/bin/td
COPY --from=builder /app/supercronic /usr/local/bin/supercronic

EXPOSE 7860

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/app/supervisor/supervisord.conf"]