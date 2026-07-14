<div align="center">

<img src="https://raw.githubusercontent.com/QuantumNous/new-api/main/web/default/public/logo.png" alt="New API Logo" width="110">

<h1>快速建站教程（Linux版）</h1>

<p>自动识别 Linux 发行版，安装 Docker、Docker Compose、Caddy，并部署 New API。</p>

<p>
  <img src="https://img.shields.io/badge/Linux-Auto_Detect-FCC624?logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/Docker-Compose_V2-2496ED?logo=docker&logoColor=white" alt="Docker Compose">
  <img src="https://img.shields.io/badge/Caddy-Auto_HTTPS-1F88C0?logo=caddy&logoColor=white" alt="Caddy">
  <a href="https://github.com/FeynmanNddbb/new-api-linux-deploy"><img src="https://img.shields.io/badge/Repository-FeynmanNddbb-181717?logo=github" alt="Repository"></a>
</p>

<p>
  <a href="#手动安装教程">手动教程</a> |
  <a href="#配置域名和-https">域名 HTTPS</a> |
  <a href="#常用管理命令">管理命令</a>
</p>

</div>

---

## 项目功能

- 自动识别 Debian、Ubuntu、CentOS、RHEL、Rocky Linux、AlmaLinux、Fedora。
- 安装 Docker Engine、Docker Compose v2、Git、Curl、Caddy、Logrotate。
- 使用 Docker Compose 启动 New API、PostgreSQL、Redis。
- 使用 Caddy 配置域名、反向代理和自动 HTTPS。
- 配置 Docker 容器日志和 New API 应用日志轮转。
- 支持 systemd 开机自动启动。

## 支持系统

- Debian
- Ubuntu
- CentOS
- Red Hat Enterprise Linux
- Rocky Linux
- AlmaLinux
- Fedora

建议使用具有 `sudo` 权限的普通用户或 `root` 用户执行安装。

## 手动安装教程

按顺序执行以下步骤即可完成建站。

> [!TIP]
> 每个代码块都可以整段复制执行，不需要逐行输入；必须连续执行的普通命令已使用 `&&` 合并为单行。

### 1. 安装前置软件

复制并执行下面的完整命令。脚本会读取 `/etc/os-release`，自动选择 APT、DNF 或 YUM 安装方式。

```bash
bash <<'INSTALL'
set -euo pipefail

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [ ! -r /etc/os-release ]; then
  echo "无法识别 Linux 发行版：/etc/os-release 不存在"
  exit 1
fi

. /etc/os-release
OS_ID="${ID,,}"

echo "检测到系统：${PRETTY_NAME:-$OS_ID}"

clear_stale_docker_proxy() {
  local env_proxy json_proxy proxy port tmp

  env_proxy="$(run_root systemctl show docker --property=Environment --value 2>/dev/null \
    | grep -oE 'https?://(127\.0\.0\.1|localhost):[0-9]+' \
    | head -n 1 || true)"
  json_proxy=""

  if [ -f /etc/docker/daemon.json ]; then
    json_proxy="$(run_root jq -r '.proxies["https-proxy"] // .proxies["http-proxy"] // empty' \
      /etc/docker/daemon.json 2>/dev/null || true)"
  fi

  proxy="${env_proxy:-$json_proxy}"

  case "$proxy" in
    http://127.0.0.1:*|https://127.0.0.1:*|http://localhost:*|https://localhost:*)
      port="${proxy##*:}"
      port="${port%%/*}"

      if command -v ss >/dev/null 2>&1 \
        && ss -lntH | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
        echo "检测到可用的本机 Docker 代理：${proxy}，保留当前配置。"
        return
      fi

      echo "检测到失效的本机 Docker 代理：${proxy}，正在清除。"
      run_root mkdir -p /etc/systemd/system/docker.service.d
      run_root tee /etc/systemd/system/docker.service.d/99-no-proxy.conf >/dev/null <<'PROXYEOF'
[Service]
Environment="HTTP_PROXY="
Environment="HTTPS_PROXY="
Environment="ALL_PROXY="
Environment="http_proxy="
Environment="https_proxy="
Environment="all_proxy="
PROXYEOF

      if [ -f /etc/docker/daemon.json ]; then
        run_root cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
        tmp="$(mktemp)"
        run_root jq 'if (((.proxies? // {}) | tostring) | test("127\\.0\\.0\\.1|localhost")) then del(.proxies) else . end' \
          /etc/docker/daemon.json > "$tmp"
        run_root install -m 0644 "$tmp" /etc/docker/daemon.json
        rm -f "$tmp"
      fi

      run_root systemctl daemon-reload
      run_root systemctl restart docker
      ;;
  esac
}

case "$OS_ID" in
  debian|ubuntu)
    run_root apt-get update
    run_root apt-get install -y ca-certificates curl gnupg git jq logrotate

    run_root install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
      | run_root gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    run_root chmod a+r /etc/apt/keyrings/docker.gpg

    ARCH="$(dpkg --print-architecture)"
    CODENAME="${VERSION_CODENAME:-}"

    if [ -z "$CODENAME" ]; then
      echo "无法识别系统版本代号 VERSION_CODENAME"
      exit 1
    fi

    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${CODENAME} stable" \
      | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null

    run_root apt-get update
    run_root apt-get install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin

    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/setup.deb.sh \
      | run_root bash
    run_root apt-get update
    run_root apt-get install -y caddy
    ;;

  centos|rhel|rocky|almalinux|fedora)
    if command -v dnf >/dev/null 2>&1; then
      PKG=dnf
    else
      PKG=yum
    fi

    run_root "$PKG" install -y ca-certificates curl git jq logrotate

    case "$OS_ID" in
      fedora) DOCKER_DIST=fedora ;;
      rhel) DOCKER_DIST=rhel ;;
      centos|rocky|almalinux) DOCKER_DIST=centos ;;
    esac

    curl -fsSL "https://download.docker.com/linux/${DOCKER_DIST}/docker-ce.repo" \
      | run_root tee /etc/yum.repos.d/docker-ce.repo >/dev/null

    run_root "$PKG" install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin

    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/setup.rpm.sh \
      | run_root bash
    run_root "$PKG" install -y caddy
    ;;

  *)
    echo "暂不支持自动安装：${PRETTY_NAME:-$OS_ID}"
    echo "请手动安装 Docker、Docker Compose v2、Git、Caddy 和 Logrotate。"
    exit 1
    ;;
esac

run_root systemctl enable --now docker
clear_stale_docker_proxy
run_root systemctl enable --now caddy

echo
echo "安装完成："
run_root docker --version
run_root docker compose version
caddy version
INSTALL
```

这段命令安装以下软件：

| 软件 | 功能 |
| --- | --- |
| Docker Engine | 运行 New API 和数据库容器 |
| Docker Compose v2 | 管理多个容器服务 |
| Git | 下载和更新 New API |
| Caddy | 域名反向代理和自动 HTTPS |
| jq | 安全修改 Docker JSON 配置 |
| Logrotate | 轮转和压缩 New API 应用日志 |

### 现有服务器一键修复失效代理

如果已经出现 `proxyconnect tcp: dial tcp 127.0.0.1:7890: connect: connection refused`，一次性复制执行以下单行命令：

```bash
sudo bash -c 'set -e; command -v jq >/dev/null 2>&1 || { if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq jq; elif command -v dnf >/dev/null 2>&1; then dnf install -y jq; else yum install -y jq; fi; }; mkdir -p /etc/systemd/system/docker.service.d; printf "%s\n" "[Service]" "Environment=\"HTTP_PROXY=\"" "Environment=\"HTTPS_PROXY=\"" "Environment=\"ALL_PROXY=\"" "Environment=\"http_proxy=\"" "Environment=\"https_proxy=\"" "Environment=\"all_proxy=\"" > /etc/systemd/system/docker.service.d/99-no-proxy.conf; if [ -f /etc/docker/daemon.json ] && grep -qiE "127\.0\.0\.1|localhost" /etc/docker/daemon.json; then cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"; tmp=$(mktemp); jq "del(.proxies)" /etc/docker/daemon.json > "$tmp"; install -m 0644 "$tmp" /etc/docker/daemon.json; rm -f "$tmp"; fi; systemctl daemon-reload && systemctl restart docker; systemctl show docker --property=Environment; docker info | grep -i proxy || true'
```

### 2. 下载 New API

```bash
git clone https://github.com/QuantumNous/new-api.git && cd new-api
```

### 3. 配置日志轮转

创建 Compose 覆盖配置，为 New API、PostgreSQL 和 Redis 设置容器日志轮转：

```bash
tee docker-compose.override.yml >/dev/null <<'EOF'
services:
  new-api:
    logging: &default-logging
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
  postgres:
    logging: *default-logging
  redis:
    logging: *default-logging
EOF
```

配置 New API 应用日志轮转：

```bash
NEW_API_DIR="$(pwd)"

sudo tee /etc/logrotate.d/new-api >/dev/null <<EOF
${NEW_API_DIR}/logs/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF
```

| 日志类型 | 轮转规则 |
| --- | --- |
| Docker 容器日志 | 单文件最大 `20 MB`，保留 `5` 个文件 |
| New API 应用日志 | 每天轮转，保留 `14` 份并压缩 |

日志轮转只处理运行日志文件，不会修改 PostgreSQL 数据库内容。

### 4. 拉取并启动 New API

```bash
sudo docker compose config >/dev/null && sudo docker compose pull && sudo docker compose up -d && sudo docker compose ps
```

查看实时日志：

```bash
sudo docker compose logs -f
```

按 `Ctrl+C` 退出日志查看，不会停止服务。

使用服务器 IP 访问：

```text
http://服务器公网IP:3000
```

首次访问后，按照页面提示初始化管理员，然后添加上游渠道和 API Key。

> [!WARNING]
> 上游默认 Compose 配置中的 PostgreSQL 和 Redis 密码为 `123456`。快速测试可以直接使用，正式站点建议后续修改默认密码。

## 配置域名和 HTTPS

先将域名的 `A` 记录解析到服务器公网 IP，并在云服务器安全组中放行 TCP `80` 和 `443` 端口。

将 `api.example.com` 修改为自己的域名：

```bash
DOMAIN="api.example.com"

sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
$DOMAIN {
  reverse_proxy 127.0.0.1:3000
}
EOF
```

检查并加载配置：

```bash
sudo caddy fmt --overwrite /etc/caddy/Caddyfile && sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl enable --now caddy && sudo systemctl reload caddy
```

等待 DNS 生效后访问：

```text
https://api.example.com
```

Caddy 会自动申请和续期 HTTPS 证书。

## 配置开机自动启动

Docker 和 Caddy 已通过 `systemctl enable` 设置为开机启动。New API 官方 Compose 配置中的容器使用 `restart: always`，Docker 启动后会自动恢复容器。

需要独立的 systemd 服务时，可以创建：

```bash
DOCKER_BIN="$(command -v docker)"
NEW_API_DIR="$(pwd)"

sudo tee /etc/systemd/system/new-api-compose.service >/dev/null <<EOF
[Unit]
Description=New API Docker Compose Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${NEW_API_DIR}
ExecStart=${DOCKER_BIN} compose up -d --remove-orphans
ExecStop=${DOCKER_BIN} compose stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable --now new-api-compose.service
```

查看自启服务：

```bash
sudo systemctl status docker --no-pager && sudo systemctl status caddy --no-pager && sudo systemctl status new-api-compose --no-pager
```

## 常用管理命令

以下 Docker 命令需要在 New API 项目目录执行：

```bash
cd new-api
```

| 功能 | 命令 |
| --- | --- |
| 查看状态 | `sudo docker compose ps` |
| 查看日志 | `sudo docker compose logs -f` |
| 重启容器 | `sudo docker compose restart` |
| 停止容器 | `sudo docker compose stop` |
| 启动容器 | `sudo docker compose start` |
| 删除容器但保留数据 | `sudo docker compose down` |

更新 New API：

```bash
cd new-api && git pull --ff-only && sudo docker compose pull && sudo docker compose up -d --remove-orphans
```

> [!CAUTION]
> 不要随意执行 `docker compose down -v`。参数 `-v` 会删除 PostgreSQL 数据卷。

## 可选：配置 Docker 镜像加速

如果拉取镜像超时，可以配置镜像地址：

```bash
sudo mkdir -p /etc/docker

sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.nju.edu.cn"
  ]
}
EOF

sudo systemctl daemon-reload && sudo systemctl restart docker
```

重新拉取镜像：

```bash
sudo docker compose pull && sudo docker compose up -d
```

> [!NOTE]
> 镜像站可用性可能变化。如果 `/etc/docker/daemon.json` 已有其他配置，需要手动合并，避免覆盖原有内容。

## 端口要求

| 端口 | 功能 | 是否需要开放公网 |
| --- | --- | --- |
| `22` | SSH 管理服务器 | 按实际需要 |
| `80` | Caddy HTTP 验证和跳转 | 使用域名时需要 |
| `443` | Caddy HTTPS | 使用域名时需要 |
| `3000` | New API 默认端口 | 仅使用 IP 直连时需要 |

使用域名和 Caddy 后，可以在云安全组中关闭公网 `3000` 端口，只保留 `80` 和 `443`。

## 站点与交流群

站点自用：[cc.midlight.top](https://cc.midlight.top)

建站以及上游对接交流群：

<p align="center">
  <img src="assets/qq-group.png" alt="建站以及上游对接交流群二维码" width="360">
</p>

## 许可证

本仓库原创的部署脚本和文档使用 [PolyForm Noncommercial License 1.0.0](LICENSE)。允许非商业用途；任何商业使用均须事先获得作者的书面授权。商业授权请通过 GitHub Issues 联系。

New API 及其他第三方组件仍适用其各自的许可证，本仓库许可证不会改变第三方项目的授权条件。

## 相关链接

- [本部署教程仓库](https://github.com/FeynmanNddbb/new-api-linux-deploy)
- [FeynmanNddbb GitHub 主页](https://github.com/FeynmanNddbb)
- [New API GitHub](https://github.com/QuantumNous/new-api)
- [New API 官方文档](https://docs.newapi.pro/)
- [Docker 官方文档](https://docs.docker.com/engine/install/)
- [Caddy 官方文档](https://caddyserver.com/docs/)

---

<div align="center">

由 [FeynmanNddbb](https://github.com/FeynmanNddbb) 整理。本教程用于快速建站，项目功能和配置变化请以上游 New API 官方文档为准。

</div>
