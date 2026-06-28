#!/usr/bin/env bash
# ============================================================
# VPN-script AIO — Single-file edition
# install.sh + bot.py embedded
# Usage: bash vpn-script-aio.sh
# ============================================================
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG="/var/log/vpn-script-install.log"
TOTAL=31
STEP=0
export DEBIAN_FRONTEND=noninteractive

# ── progress bar ─────────────────────────────────────────────
bar() {
  local current="$1" total="$2" label="$3" width=40
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local percent=$(( current * 100 / total ))
  printf "\r${CYAN}["
  printf "%${filled}s" | tr ' ' '#'
  printf "%${empty}s"  | tr ' ' '-'
  printf "] ${YELLOW}%3d%%${NC} %s" "$percent" "$label"
}

run_step() {
  STEP=$((STEP+1))
  local label="$1"; shift
  echo; bar "$STEP" "$TOTAL" "$label"; echo
  "$@" >> "$LOG" 2>&1
}

die() { echo -e "\n${RED}ERROR:${NC} $1"; echo "Log: $LOG"; exit 1; }

# ── checks ───────────────────────────────────────────────────
need_root() { [[ "$EUID" -eq 0 ]] || die "Run as root"; }

ask_inputs() {
  echo -e "${CYAN}VPN-script AIO Installer${NC}"
  echo "Terminal: English | Bot: Arabic"
  echo
  read -rp "Domain/subdomain: "           DOMAIN
  read -rp "Telegram BOT_TOKEN: "         BOT_TOKEN
  read -rp "Telegram ADMIN_ID: "          ADMIN_ID
  read -rp "Enable SlowDNS? [y/N]: "      ENABLE_SLOWDNS
  [[ -n "$DOMAIN"    ]] || die "Domain required"
  [[ -n "$BOT_TOKEN" ]] || die "BOT_TOKEN required"
  [[ -n "$ADMIN_ID"  ]] || die "ADMIN_ID required"
  mkdir -p /etc/vpn-script /etc/xray /etc/slowdns
  echo "$DOMAIN" > /etc/xray/domain
  cat > /etc/vpn-script/bot.env <<EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_ID
EOF
  chmod 600 /etc/vpn-script/bot.env
}

# ── steps ────────────────────────────────────────────────────
fix_apt() {
  dpkg --configure -a || true
  apt-get -f install -y || true
  apt-get clean || true
}

packages() {
  apt-get update -y
  apt-get install -y \
    ca-certificates curl wget unzip zip jq git sudo cron at \
    lsof htop iftop lnav screen nano sed iproute2 net-tools \
    dnsutils socat iptables ufw vnstat openssl build-essential \
    dirmngr gnupg python3 python3-venv python3-pip \
    nginx haproxy dropbear stunnel4 speedtest-cli figlet bc \
    ruby lsb-release passwd
}

dirs() {
  mkdir -p /etc/xray /etc/vpn-script /etc/vpn-script/quota \
           /var/log/xray /etc/noobzvpns /opt/vpn-script
  touch /var/log/xray/access.log /var/log/xray/error.log "$LOG"
}

ssh_dropbear() {
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-vpn-script.conf <<'EOF'
Port 22
Port 3303
PasswordAuthentication yes
PermitRootLogin yes
EOF
  systemctl restart ssh || systemctl restart sshd || true
  cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=111
DROPBEAR_EXTRA_ARGS="-p 109 -p 69"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
  echo "VPN-script Premium Server" > /etc/issue.net
  grep -qxF "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells
  systemctl enable dropbear
}

certs() {
  local dom; dom="$(cat /etc/xray/domain)"
  openssl genrsa -out /etc/xray/xray.key 2048
  openssl req -new -x509 -key /etc/xray/xray.key -out /etc/xray/xray.crt -days 1095 \
    -subj "/C=US/ST=NA/L=NA/O=VPN/OU=AIO/CN=$dom/emailAddress=admin@$dom"
  cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/xray/funny.pem
  chmod 600 /etc/xray/xray.key /etc/xray/funny.pem
  chmod 644 /etc/xray/xray.crt
}

xray_install() {
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || true
  local XRAY_BIN="/usr/local/bin/xray"
  [[ -x "$XRAY_BIN" ]] || XRAY_BIN="/usr/bin/xray"

  # Generate random credentials
  local SS_PASS;       SS_PASS=$(openssl rand -base64 16)
  local SS_PASS2;      SS_PASS2=$(openssl rand -base64 24)
  local REALITY_PRIV;  REALITY_PRIV=$("$XRAY_BIN" x25519 2>/dev/null | awk '/Private/{print $3}' || openssl rand -hex 32)
  local REALITY_PUB;   REALITY_PUB=$("$XRAY_BIN"  x25519 -i "$REALITY_PRIV" 2>/dev/null | awk '/Public/{print $3}' || echo "")
  local REALITY_SHORT; REALITY_SHORT=$(openssl rand -hex 4)

  # Save keys so the bot can read them
  cat > /etc/vpn-script/xray.keys <<KEYS
SS_PASS=$SS_PASS
SS_PASS2=$SS_PASS2
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SHORT=$REALITY_SHORT
KEYS
  chmod 600 /etc/vpn-script/xray.keys

  # Write config — using printf to allow variable expansion inside the JSON
  # Comments are stripped by xray at load time (it uses JSONC parser)
  cat > /etc/xray/config.json <<XEOF
{
  "log": {
    "access":   "/var/log/xray/access.log",
    "error":    "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [

    {
      "tag": "vmess-ws",
      "port": 10086, "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess" }
      }
    },

    {
      "tag": "vless-ws",
      "port": 10087, "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },

    {
      "tag": "trojan-ws",
      "port": 10088, "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan" }
      }
    },

    {
      "tag": "vmess-grpc",
      "port": 10089, "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "vmess-grpc" }
      }
    },

    {
      "tag": "vless-grpc",
      "port": 10090, "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "vless-grpc" }
      }
    },

    {
      "tag": "trojan-grpc",
      "port": 10091, "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": { "serviceName": "trojan-grpc" }
      }
    },

    {
      "tag": "vmess-tcp",
      "port": 8080,
      "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {
          "header": {
            "type": "http",
            "request": {
              "version": "1.1",
              "method":  "GET",
              "path":    ["/"],
              "headers": {
                "Host":            [""],
                "User-Agent":      ["Mozilla/5.0"],
                "Accept-Encoding": ["gzip, deflate"],
                "Connection":      ["keep-alive"]
              }
            }
          }
        }
      }
    },

    {
      "tag": "vless-reality",
      "port": 8443,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network":  "tcp",
        "security": "reality",
        "realitySettings": {
          "show":        false,
          "dest":        "www.google.com:443",
          "xver":        0,
          "serverNames": ["www.google.com", "www.microsoft.com"],
          "privateKey":  "$REALITY_PRIV",
          "shortIds":    ["$REALITY_SHORT"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    },

    {
      "tag":  "ss-2022",
      "port": 8388,
      "protocol": "shadowsocks",
      "settings": {
        "method":   "2022-blake3-aes-128-gcm",
        "password": "$SS_PASS",
        "network":  "tcp,udp"
      }
    },

    {
      "tag":  "ss-classic",
      "port": 8389,
      "protocol": "shadowsocks",
      "settings": {
        "method":   "aes-256-gcm",
        "password": "$SS_PASS2",
        "network":  "tcp,udp"
      }
    },

    {
      "tag": "socks5",
      "port": 1080, "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],

  "outbounds": [
    { "tag": "direct",  "protocol": "freedom",   "settings": {} },
    { "tag": "blocked", "protocol": "blackhole",  "settings": {} }
  ],

  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
}
XEOF

  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray
}

nginx_config() {
  # Upstream map for all WS inbounds
  cat > /etc/nginx/conf.d/vpn-script.conf <<'NGXEOF'

# ── Upstream backends ───────────────────────────────────────────
upstream vmess_ws   { server 127.0.0.1:10086; }
upstream vless_ws   { server 127.0.0.1:10087; }
upstream trojan_ws  { server 127.0.0.1:10088; }
upstream vmess_grpc { server 127.0.0.1:10089; }
upstream vless_grpc { server 127.0.0.1:10090; }
upstream trojan_grpc{ server 127.0.0.1:10091; }
upstream ssh_ws     { server 127.0.0.1:8880;  }

# ── Shared proxy snippet (WS) ───────────────────────────────────
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

# ═══════════════════════════════════════════════════════════════
# Port 80 — plain HTTP (WS only; no TLS)
# ═══════════════════════════════════════════════════════════════
server {
  listen 80 reuseport;
  server_name _;

  # Redirect everything else to HTTPS
  location / { return 301 https://$host$request_uri; }

  # VMess WebSocket — ws://host:80/vmess
  location /vmess {
    proxy_pass         http://vmess_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # VLESS WebSocket — ws://host:80/vless
  location /vless {
    proxy_pass         http://vless_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # Trojan WebSocket — ws://host:80/trojan
  location /trojan {
    proxy_pass         http://trojan_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # SSH WebSocket — ws://host:80/ssh
  location /ssh {
    proxy_pass         http://ssh_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }
}

# ═══════════════════════════════════════════════════════════════
# Port 443 — TLS (WS + gRPC)
# ═══════════════════════════════════════════════════════════════
server {
  listen 443 ssl http2 reuseport;
  server_name _;

  ssl_certificate     /etc/xray/xray.crt;
  ssl_certificate_key /etc/xray/xray.key;
  ssl_protocols       TLSv1.2 TLSv1.3;
  ssl_ciphers         HIGH:!aNULL:!MD5;
  ssl_session_cache   shared:SSL:10m;
  ssl_session_timeout 10m;

  location / { return 200 "ok\n"; }

  # ── WebSocket paths ────────────────────────────────────────

  # VMess WS — wss://host:443/vmess
  location /vmess {
    proxy_pass         http://vmess_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # VLESS WS — wss://host:443/vless
  location /vless {
    proxy_pass         http://vless_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # Trojan WS — wss://host:443/trojan
  location /trojan {
    proxy_pass         http://trojan_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # SSH WS — wss://host:443/ssh
  location /ssh {
    proxy_pass         http://ssh_ws;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_read_timeout 86400s;
  }

  # ── gRPC paths (HTTP/2 required) ──────────────────────────

  # VMess gRPC — grpc://host:443/vmess-grpc
  location /vmess-grpc {
    grpc_pass          grpc://vmess_grpc;
    grpc_set_header    Host $host;
    grpc_read_timeout  86400s;
    grpc_send_timeout  86400s;
  }

  # VLESS gRPC — grpc://host:443/vless-grpc
  location /vless-grpc {
    grpc_pass          grpc://vless_grpc;
    grpc_set_header    Host $host;
    grpc_read_timeout  86400s;
    grpc_send_timeout  86400s;
  }

  # Trojan gRPC — grpc://host:443/trojan-grpc
  location /trojan-grpc {
    grpc_pass          grpc://trojan_grpc;
    grpc_set_header    Host $host;
    grpc_read_timeout  86400s;
    grpc_send_timeout  86400s;
  }
}
NGXEOF

  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
}
stunnel_config() {
  cat > /etc/stunnel/stunnel.conf <<'EOF'
cert   = /etc/xray/funny.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[openssh]
accept  = 777
connect = 127.0.0.1:3303
[dropbear]
accept  = 447
connect = 127.0.0.1:109
[openvpn]
accept  = 444
connect = 127.0.0.1:1194
EOF
  sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null \
    || echo "ENABLED=1" > /etc/default/stunnel4
  systemctl enable stunnel4
}

ssh_ws() {
  cat > /usr/local/bin/ssh-ws.py <<'PY'
#!/usr/bin/env python3
import socket, threading
LISTEN = ("127.0.0.1", 8880)
TARGET = ("127.0.0.1", 22)

def pipe(a, b):
    try:
        while True:
            d = a.recv(4096)
            if not d: break
            b.sendall(d)
    except Exception: pass
    try: a.close(); b.close()
    except Exception: pass

def handle(c):
    try:
        c.recv(4096)
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        r = socket.create_connection(TARGET, timeout=10)
        threading.Thread(target=pipe, args=(c, r), daemon=True).start()
        pipe(r, c)
    except Exception:
        try: c.close()
        except Exception: pass

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(LISTEN); s.listen(200)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
  chmod +x /usr/local/bin/ssh-ws.py
  cat > /etc/systemd/system/ssh-ws.service <<'EOF'
[Unit]
Description=SSH WebSocket
After=network-online.target
[Service]
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ssh-ws
}

torrent_block() {
  cat > /usr/local/sbin/block-torrent <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CHAIN="BT_BLOCK"
iptables -N "$CHAIN" 2>/dev/null || true
iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD -j "$CHAIN"
iptables -C OUTPUT  -j "$CHAIN" 2>/dev/null || iptables -I OUTPUT  -j "$CHAIN"
for s in "BitTorrent" "bittorrent" "peer_id=" ".torrent" "info_hash"; do
  iptables -C "$CHAIN" -m string --string "$s" --algo bm -j DROP 2>/dev/null \
    || iptables -A "$CHAIN" -m string --string "$s" --algo bm -j DROP
done
for p in 6881 6882 6883 6884 6885 6886 6887 6888 6889 51413; do
  iptables -C "$CHAIN" -p tcp --dport "$p" -j DROP 2>/dev/null \
    || iptables -A "$CHAIN" -p tcp --dport "$p" -j DROP
  iptables -C "$CHAIN" -p udp --dport "$p" -j DROP 2>/dev/null \
    || iptables -A "$CHAIN" -p udp --dport "$p" -j DROP
done
EOF
  chmod +x /usr/local/sbin/block-torrent
  cat > /etc/systemd/system/block-torrent.service <<'EOF'
[Unit]
Description=Torrent Block
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/block-torrent
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable block-torrent
}

# ── embed bot.py then install it ─────────────────────────────
bot_install() {
  install -d /opt/vpn-script/bot /etc/vpn-script
  cat > /opt/vpn-script/bot/bot.py <<'BOTPY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, re, json, uuid, html, subprocess, secrets, string, base64, logging
from pathlib import Path
from datetime import datetime, timedelta
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (Application, CommandHandler, CallbackQueryHandler,
                           ConversationHandler, MessageHandler, ContextTypes, filters)

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(message)s",
    level=logging.INFO,
    handlers=[logging.FileHandler("/var/log/vpn-script-bot.log"),
              logging.StreamHandler()]
)
log = logging.getLogger(__name__)

ENV    = Path("/etc/vpn-script/bot.env")
BASE   = Path("/etc/vpn-script")
XRAY_CONFIG = Path("/etc/xray/config.json")
DOMAIN = Path("/etc/xray/domain")
BASE.mkdir(parents=True, exist_ok=True)

for line in (ENV.read_text(errors="ignore").splitlines() if ENV.exists() else []):
    if "=" in line:
        k, v = line.split("=", 1)
        os.environ[k.strip()] = v.strip()

TOKEN  = os.getenv("BOT_TOKEN", "")
ADMINS = [int(x) for x in os.getenv("ADMIN_IDS", "").split(",") if x.strip().isdigit()]
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
SSH_USER, SSH_PASS, SSH_DAYS, SSH_QUOTA = range(4)
XRAY_NAME, XRAY_DAYS, XRAY_PROTO = range(3, 6)


def run(cmd: str, timeout: int = 20) -> str:
    try:
        r = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
        return (r.stdout + r.stderr).strip() or "تم"
    except Exception as exc:
        log.error("run(%s): %s", cmd, exc)
        return str(exc)


def is_admin(u) -> bool:
    return bool(u.effective_user and u.effective_user.id in ADMINS)


def admin_only(fn):
    async def w(update, ctx):
        if not is_admin(update):
            await update.effective_message.reply_text("🚫 غير مصرح")
            return ConversationHandler.END
        return await fn(update, ctx)
    return w


def dom() -> str:
    return DOMAIN.read_text().strip() if DOMAIN.exists() else run("hostname -I | awk '{print $1}'")


def menu():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("👤 SSH",  callback_data="ssh_menu"),
         InlineKeyboardButton("🧬 Xray", callback_data="xray_menu")],
        [InlineKeyboardButton("📊 حالة السيرفر", callback_data="stats"),
         InlineKeyboardButton("⚙️ الخدمات",      callback_data="services")],
        [InlineKeyboardButton("🧭 البورتات", callback_data="ports"),
         InlineKeyboardButton("🔌 المتصلين", callback_data="online")],
        [InlineKeyboardButton("🚫 حظر التورنت", callback_data="torrent"),
         InlineKeyboardButton("♻️ إعادة تشغيل", callback_data="restart")],
    ])


def ssh_menu():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ إنشاء SSH",  callback_data="ssh_create")],
        [InlineKeyboardButton("📋 قائمة SSH",  callback_data="ssh_list")],
        [InlineKeyboardButton("🔙 رجوع",        callback_data="back")],
    ])


def xray_menu():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ إنشاء Xray", callback_data="xray_create")],
        [InlineKeyboardButton("📋 قائمة Xray", callback_data="xray_list")],
        [InlineKeyboardButton("🔙 رجوع",        callback_data="back")],
    ])


@admin_only
async def start(update, ctx):
    await update.effective_message.reply_text("✅ لوحة تحكم VPN-script", reply_markup=menu())


@admin_only
async def router(update, ctx):
    q = update.callback_query
    await q.answer()
    if q.data == "ssh_menu":
        await q.edit_message_text("👤 إدارة SSH", reply_markup=ssh_menu())
    elif q.data == "xray_menu":
        await q.edit_message_text("🧬 إدارة Xray", reply_markup=xray_menu())
    elif q.data == "back":
        await q.edit_message_text("✅ القائمة الرئيسية", reply_markup=menu())
    elif q.data == "stats":
        txt  = "📊 حالة السيرفر\n"
        txt += "IP:   " + run("hostname -I | awk '{print $1}'") + "\n"
        txt += "RAM:  " + run("free -h | awk '/^Mem:/{print $3\"/\"$2}'") + "\n"
        txt += "Disk: " + run("df -h / | awk 'NR==2{print $3\"/\"$2\" \"$5}'")
        await q.edit_message_text(txt, reply_markup=menu())
    elif q.data == "services":
        svcs = "ssh dropbear stunnel4 nginx xray ssh-ws block-torrent vpn-bot"
        out  = run(f"for s in {svcs}; do echo $s: $(systemctl is-active $s 2>/dev/null); done")
        await q.edit_message_text("⚙️ الخدمات\n" + out, reply_markup=menu())
    elif q.data == "ports":
        await q.edit_message_text(
            "🧭 البورتات\n"
            "Xray: 80/443  /vmess /vless /trojan\n"
            "SSH: 22/3303 | Dropbear: 69/109/111\n"
            "SSL: 444/447/777 | SSH WS: /ssh\n"
            "SlowDNS: 5300 UDP",
            reply_markup=menu()
        )
    elif q.data == "online":
        await q.edit_message_text(
            "🔌 المتصلين\n" + run("who; ss -tn state established | head -30")[:3500],
            reply_markup=menu()
        )
    elif q.data == "torrent":
        await q.edit_message_text("🚫 " + run("/usr/local/sbin/block-torrent")[:1000], reply_markup=menu())
    elif q.data == "restart":
        run("systemctl restart ssh dropbear stunnel4 nginx xray ssh-ws block-torrent 2>/dev/null || true", 60)
        await q.edit_message_text("♻️ تم إعادة التشغيل", reply_markup=menu())


# ── SSH conversation ──────────────────────────────────────────
@admin_only
async def ssh_create(update, ctx):
    q = update.callback_query; await q.answer()
    await q.edit_message_text("👤 أدخل اسم المستخدم:")
    return SSH_USER

async def ssh_user(update, ctx):
    u = update.message.text.strip()
    if not USER_RE.match(u):
        await update.message.reply_text("❌ اسم غير صالح (حروف صغيرة، أرقام، _  -)"); return SSH_USER
    ctx.user_data["u"] = u
    await update.message.reply_text("🔑 أدخل كلمة المرور:")
    return SSH_PASS

async def ssh_pass(update, ctx):
    ctx.user_data["p"] = update.message.text.strip()
    await update.message.reply_text("📅 عدد الأيام:")
    return SSH_DAYS

async def ssh_days(update, ctx):
    try:
        ctx.user_data["days"] = int(update.message.text.strip())
    except ValueError:
        await update.message.reply_text("❌ أدخل رقماً صحيحاً"); return SSH_DAYS
    await update.message.reply_text("📶 الكوتا بالـ GB أو 0 للتعطيل:")
    return SSH_QUOTA

async def ssh_quota(update, ctx):
    u    = ctx.user_data["u"]
    p    = ctx.user_data["p"]
    days = ctx.user_data["days"]
    exp  = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    run(f"useradd -M -s /usr/sbin/nologin -e {exp} {u} 2>&1")
    run(f"printf '%s:%s\\n' '{u}' '{p}' | chpasswd")
    log.info("SSH created: user=%s exp=%s", u, exp)
    await update.message.reply_text(
        f"✅ تم إنشاء حساب SSH\n"
        f"User:   {u}\nPass:   {p}\n"
        f"Expire: {exp}\nHost:   {dom()}"
    )
    await update.message.reply_text("👤 إدارة SSH", reply_markup=ssh_menu())
    return ConversationHandler.END


@admin_only
async def ssh_list(update, ctx):
    q = update.callback_query; await q.answer()
    out = run("awk -F: '$3>=1000 && $1!=\"nobody\"{print $1}' /etc/passwd")
    await q.edit_message_text("📋 مستخدمو SSH\n" + out, reply_markup=ssh_menu())


# ── Xray conversation ─────────────────────────────────────────
# ── Xray conversation ─────────────────────────────────────────
# Flow: اسم → أيام → اختيار بروتوكول → يُعطى كل روابطه


def _read_keys():
    keys = {}
    p = Path("/etc/vpn-script/xray.keys")
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                keys[k.strip()] = v.strip()
    return keys

def _build_vmess(uid, name, d):
    import json as _json, base64 as _b64
    def lnk(port, tls, net, path_or_svc, tag):
        cfg = {"v":"2","ps":f"{name}-{tag}","add":d,"port":str(port),
               "id":uid,"aid":"0","net":net,"type":"none" if net!="tcp" else "http",
               "host":d,"path":path_or_svc,"tls":"tls" if tls else ""}
        return "vmess://" + _b64.b64encode(_json.dumps(cfg).encode()).decode()
    lines  = "🔷 VMess — كل الروابط\n"
    lines += f"\nWS HTTP  :80\n{lnk(80,  False,'ws','/vmess','ws-80')}"
    lines += f"\nWS TLS   :443\n{lnk(443, True, 'ws','/vmess','ws-443')}"
    lines += f"\ngRPC TLS :443\n{lnk(443, True,'grpc','vmess-grpc','grpc')}"
    lines += f"\nTCP obfs :8080\n{lnk(8080,False,'tcp','/','tcp')}"
    return lines

def _build_vless(uid, name, d, pub, short):
    lines  = "🟢 VLESS — كل الروابط\n"
    lines += (f"\nWS HTTP  :80\n"
              f"vless://{uid}@{d}:80?type=ws&security=none&host={d}&path=%2Fvless#{name}-ws-80")
    lines += (f"\nWS TLS   :443\n"
              f"vless://{uid}@{d}:443?type=ws&security=tls&host={d}&path=%2Fvless&sni={d}#{name}-ws-443")
    lines += (f"\ngRPC TLS :443\n"
              f"vless://{uid}@{d}:443?type=grpc&security=tls&host={d}&serviceName=vless-grpc&sni={d}#{name}-grpc")
    lines += (f"\nReality  :8443\n"
              f"vless://{uid}@{d}:8443?type=tcp&security=reality&pbk={pub}&sid={short}"
              f"&sni=www.google.com&fp=chrome&flow=xtls-rprx-vision#{name}-reality")
    return lines

def _build_trojan(pwd, name, d):
    lines  = "🔴 Trojan — كل الروابط\n"
    lines += (f"\nWS HTTP  :80\n"
              f"trojan://{pwd}@{d}:80?type=ws&security=none&host={d}&path=%2Ftrojan#{name}-ws-80")
    lines += (f"\nWS TLS   :443\n"
              f"trojan://{pwd}@{d}:443?type=ws&security=tls&host={d}&path=%2Ftrojan&sni={d}#{name}-ws-443")
    lines += (f"\ngRPC TLS :443\n"
              f"trojan://{pwd}@{d}:443?type=grpc&security=tls&host={d}&serviceName=trojan-grpc&sni={d}#{name}-grpc")
    return lines

def proto_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🔷 VMess",  callback_data="xp_vmess"),
         InlineKeyboardButton("🟢 VLESS",  callback_data="xp_vless"),
         InlineKeyboardButton("🔴 Trojan", callback_data="xp_trojan")],
        [InlineKeyboardButton("❌ إلغاء",   callback_data="xp_cancel")],
    ])

@admin_only
async def xray_create(update, ctx):
    q = update.callback_query; await q.answer()
    await q.edit_message_text("🧬 أدخل اسم الحساب:")
    return XRAY_NAME

async def xray_name(update, ctx):
    name = update.message.text.strip()
    if not name:
        await update.message.reply_text("❌ الاسم لا يكون فارغاً"); return XRAY_NAME
    ctx.user_data["xname"] = name
    await update.message.reply_text("📅 عدد الأيام:")
    return XRAY_DAYS

async def xray_days(update, ctx):
    try:
        ctx.user_data["xdays"] = int(update.message.text.strip())
    except ValueError:
        await update.message.reply_text("❌ أدخل رقماً صحيحاً"); return XRAY_DAYS
    await update.message.reply_text("🔌 اختر البروتوكول:", reply_markup=proto_keyboard())
    return XRAY_PROTO

async def xray_proto(update, ctx):
    q = update.callback_query; await q.answer()
    data  = q.data            # xp_vmess / xp_vless / xp_trojan / xp_cancel

    if data == "xp_cancel":
        await q.edit_message_text("تم الإلغاء", reply_markup=menu())
        return ConversationHandler.END

    name  = ctx.user_data["xname"]
    days  = ctx.user_data["xdays"]
    uid   = str(uuid.uuid4())
    pwd   = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
    exp   = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    d     = dom()
    keys  = _read_keys()
    pub   = keys.get("REALITY_PUB",   "")
    short = keys.get("REALITY_SHORT",  "")

    if   data == "xp_vmess":  body = _build_vmess(uid, name, d)
    elif data == "xp_vless":  body = _build_vless(uid, name, d, pub, short)
    elif data == "xp_trojan": body = _build_trojan(pwd, name, d)
    else:
        await q.edit_message_text("❌ اختيار غير معروف", reply_markup=xray_menu())
        return ConversationHandler.END

    log.info("Xray created: name=%s proto=%s exp=%s", name, data, exp)

    header = f"✅ {name} | Expire: {exp}\n\n"
    msg    = header + body
    await q.edit_message_text(msg, disable_web_page_preview=True)
    # إذا الرسالة طويلة أرسل بقيتها
    if len(msg) > 4096:
        for chunk in [msg[i:i+4000] for i in range(4000, len(msg), 4000)]:
            await update.effective_chat.send_message(chunk, disable_web_page_preview=True)

    await update.effective_chat.send_message("🧬 إدارة Xray", reply_markup=xray_menu())
    return ConversationHandler.END

@admin_only
async def xray_list(update, ctx):
    q = update.callback_query; await q.answer()
    await q.edit_message_text("📋 حسابات Xray تحفظ في النسخة القادمة", reply_markup=xray_menu())


async def cancel(update, ctx):
    await update.message.reply_text("تم الإلغاء", reply_markup=menu())
    return ConversationHandler.END


def main():
    if not TOKEN:
        log.error("BOT_TOKEN not set"); return
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start",  start))
    app.add_handler(CommandHandler("cancel", cancel))
    # SSH conversation
    app.add_handler(ConversationHandler(
        entry_points=[CallbackQueryHandler(ssh_create, pattern="^ssh_create$")],
        states={
            SSH_USER:  [MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_user)],
            SSH_PASS:  [MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_pass)],
            SSH_DAYS:  [MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_days)],
            SSH_QUOTA: [MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_quota)],
        },
        fallbacks=[CommandHandler("cancel", cancel)],
    ))
    # Xray conversation
    app.add_handler(ConversationHandler(
        entry_points=[CallbackQueryHandler(xray_create, pattern="^xray_create$")],
        states={
            XRAY_NAME:  [MessageHandler(filters.TEXT & ~filters.COMMAND, xray_name)],
            XRAY_DAYS:  [MessageHandler(filters.TEXT & ~filters.COMMAND, xray_days)],
            XRAY_PROTO: [CallbackQueryHandler(xray_proto, pattern="^xp_")],
        },
        fallbacks=[CommandHandler("cancel", cancel)],
    ))
    app.add_handler(CallbackQueryHandler(ssh_list,  pattern="^ssh_list$"))
    app.add_handler(CallbackQueryHandler(xray_list, pattern="^xray_list$"))
    app.add_handler(CallbackQueryHandler(router))
    log.info("VPN-script bot starting …")
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__":
    main()
BOTPY
  chmod 700 /opt/vpn-script/bot/bot.py

  python3 -m venv /opt/vpn-script/venv
  /opt/vpn-script/venv/bin/pip install --upgrade pip -q
  /opt/vpn-script/venv/bin/pip install "python-telegram-bot>=22,<23" -q
  /opt/vpn-script/venv/bin/python -m py_compile /opt/vpn-script/bot/bot.py

  cat > /etc/systemd/system/vpn-bot.service <<'EOF'
[Unit]
Description=VPN Script Telegram Bot
After=network-online.target
[Service]
User=root
EnvironmentFile=/etc/vpn-script/bot.env
WorkingDirectory=/opt/vpn-script/bot
ExecStart=/opt/vpn-script/venv/bin/python /opt/vpn-script/bot/bot.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vpn-bot
}

firewall() {
  ufw default deny incoming  || true
  ufw default allow outgoing || true
  for p in 22 3303 69 109 111 80 443 444 447 777 8080 8443 8880 8388 8389 1194; do
    ufw allow "$p/tcp" || true
  done
  for p in 5300 7300; do ufw allow "$p/udp" || true; done
  yes | ufw enable || true
}

services_start() {
  systemctl daemon-reload
  # Start block-torrent first (oneshot) then the rest
  systemctl restart block-torrent >> "$LOG" 2>&1 || true
  for s in ssh dropbear stunnel4 nginx xray ssh-ws vpn-bot cron; do
    systemctl restart "$s" >> "$LOG" 2>&1 || true
  done
  # Give services 3 seconds to settle before verification
  sleep 3
}

verify_services() {
  echo
  echo -e "${CYAN}── Service status ──────────────────────────────${NC}"
  local all_ok=1
  local services=(ssh dropbear stunnel4 nginx xray ssh-ws block-torrent vpn-bot)
  for s in "${services[@]}"; do
    local state; state=$(systemctl is-active "$s" 2>/dev/null || echo "not-found")
    if [[ "$state" == "active" ]]; then
      printf "  ${GREEN}✓${NC} %-20s %s\n" "$s" "$state"
    elif [[ "$state" == "not-found" ]]; then
      printf "  ${YELLOW}?${NC} %-20s %s\n" "$s" "not installed"
    else
      printf "  ${RED}✗${NC} %-20s %s\n" "$s" "$state"
      # Print last 5 journal lines for failed service
      echo "    $(journalctl -u "$s" -n 5 --no-pager 2>/dev/null | tail -5 | sed 's/^/    /')"
      all_ok=0
    fi
  done
  echo -e "${CYAN}────────────────────────────────────────────────${NC}"

  # Port checks
  echo -e "${CYAN}── Port checks ─────────────────────────────────${NC}"
  # tcp ports to verify
  declare -A port_map
  port_map[22]="SSH"
  port_map[3303]="SSH-alt"
  port_map[69]="Dropbear"
  port_map[109]="Dropbear"
  port_map[111]="Dropbear"
  port_map[80]="Nginx HTTP (VMess/VLESS/Trojan WS)"
  port_map[443]="Nginx TLS (WS + gRPC)"
  port_map[8080]="VMess TCP-obfs"
  port_map[8443]="VLESS Reality"
  port_map[8388]="Shadowsocks 2022"
  port_map[8389]="Shadowsocks classic"
  port_map[8880]="SSH-WS"
  port_map[444]="Stunnel OpenVPN"
  port_map[447]="Stunnel Dropbear"
  port_map[777]="Stunnel SSH"
  for port in 22 3303 80 443 8080 8443 8388 8389 8880 777 447 444 111 109 69; do
    local label="${port_map[$port]}"
    if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
      printf "  ${GREEN}✓${NC} %-6s %s\n" "$port" "$label"
    else
      printf "  ${RED}✗${NC} %-6s %s — NOT listening\n" "$port" "$label"
      all_ok=0
    fi
  done
  echo -e "${CYAN}────────────────────────────────────────────────${NC}"
  if [[ "$all_ok" -eq 1 ]]; then
    echo -e "${GREEN}✅ All services are running correctly${NC}"
  else
    echo -e "${YELLOW}⚠  Some services have issues — check: journalctl -u <service> -n 30${NC}"
    echo    "   Full install log: $LOG"
  fi
}

summary() {
  echo
  echo -e "${GREEN}✅ Installation completed${NC}"
  local D; D=$(cat /etc/xray/domain)
  local PUB; PUB=$(grep REALITY_PUB /etc/vpn-script/xray.keys 2>/dev/null | cut -d= -f2 || echo "n/a")
  local SS;  SS=$(grep  SS_PASS=    /etc/vpn-script/xray.keys 2>/dev/null | head -1 | cut -d= -f2 || echo "n/a")
  echo "Domain   : $D"
  echo ""
  echo "── Xray protocols ───────────────────────────────"
  echo "VMess  WS   HTTP  ws://$D:80/vmess"
  echo "VMess  WS   TLS   wss://$D:443/vmess"
  echo "VMess  TCP  obfs  $D:8080"
  echo "VMess  gRPC TLS   $D:443 svc=vmess-grpc"
  echo "VLESS  WS   HTTP  ws://$D:80/vless"
  echo "VLESS  WS   TLS   wss://$D:443/vless"
  echo "VLESS  gRPC TLS   $D:443 svc=vless-grpc"
  echo "VLESS  Reality    $D:8443  pubkey=$PUB"
  echo "Trojan WS   HTTP  ws://$D:80/trojan"
  echo "Trojan WS   TLS   wss://$D:443/trojan"
  echo "Trojan gRPC TLS   $D:443 svc=trojan-grpc"
  echo "SS 2022           $D:8388  pass=$SS"
  echo "SS classic        $D:8389"
  echo "── Other services ───────────────────────────────"
  echo "SSH: 22/3303 | Dropbear: 69/109/111"
  echo "SSL/Stunnel: 444/447/777 | SSH-WS: /ssh"
  echo "SlowDNS: 5300 UDP | BadVPN: 7300 UDP"
  echo "Bot      : send /start to your Telegram bot"
  echo "Keys     : /etc/vpn-script/xray.keys"
  echo "Log      : $LOG"
}

# ── main ─────────────────────────────────────────────────────
main() {
  need_root
  : > "$LOG"
  ask_inputs
  run_step  "Fix apt"                  fix_apt
  run_step  "Install packages"         packages
  run_step  "Prepare directories"      dirs
  run_step  "Configure SSH+Dropbear"   ssh_dropbear
  run_step  "Create certificates"      certs
  run_step  "Install Xray"             xray_install
  run_step  "Configure Nginx"          nginx_config
  run_step  "Configure Stunnel"        stunnel_config
  run_step  "Install SSH WebSocket"    ssh_ws
  run_step  "Install torrent blocker"  torrent_block
  run_step  "Install Telegram bot"     bot_install
  run_step  "Configure firewall"       firewall
  run_step  "Start all services"       services_start
  run_step  "Verify all services"      verify_services
  while [[ "$STEP" -lt "$TOTAL" ]]; do
    STEP=$((STEP+1)); bar "$STEP" "$TOTAL" "Finalizing"; echo
  done
  summary
}
main "$@"
