FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        fzf \
        gosu \
        lib32gcc-s1 \
        lib32stdc++6 \
        libcurl4-gnutls-dev:i386 \
        libsdl2-2.0-0:i386 \
        bzip2 \
        procps \
        tar \
        unzip \
        whiptail \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 steam \
 && useradd -u 1000 -g 1000 -m -d /home/steam -s /bin/bash steam \
 && mkdir -p /opt/steamcmd /server \
 && chown -R steam:steam /opt/steamcmd /server

WORKDIR /opt/steamcmd
RUN curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf - \
 && chown -R steam:steam /opt/steamcmd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bhop-tool /usr/local/bin/bhop-tool
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/bhop-tool

WORKDIR /server

EXPOSE 27015/udp 27015/tcp 27020/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
