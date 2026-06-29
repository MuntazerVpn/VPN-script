#!/usr/bin/env bash
# ============================================================
# VPN-script AIO — Single-file edition (Fixed)
# ============================================================
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG="/var/log/vpn-script-install.log"
TOTAL=14
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
  echo -e "${CYAN}VPN-script AIO Installer (FIXED VERSION)${NC}"
  echo
  read -rp "Domain/subdomain: "           DOMAIN
  read -rp "Telegram BOT_TOKEN: "         BOT_TOKEN
  read -rp "Telegram ADMIN_ID: "          ADMIN_ID
  
  [[ -n "$DOMAIN"    ]] || die "Domain required"
  [[ -n "$BOT_TOKEN" ]] || die "BOT_TOKEN required"
  [[ -n "$ADMIN_ID"  ]] || die "ADMIN_ID required"
  
  mkdir -p /etc/vpn-script /etc/xray
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
    nginx haproxy dropbear stunnel4 speedtest-cli bc lsb-release passwd
}

dirs() {
  mkdir -p /etc/xray /etc/vpn-script /var/log/xray /opt/vpn-script
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

  local SS_PASS;       SS_PASS=$(openssl rand -base64 16)
  local SS_PASS2;      SS_PASS2=$(openssl rand -base64 24)
  local REALITY_PRIV;  REALITY_PRIV=$("$XRAY_BIN" x25519 2>/dev/null | awk '/Private/{print $3}' || openssl rand -hex 32)
  local REALITY_PUB;   REALITY_PUB=$("$XRAY_BIN"  x25519 -i "$REALITY_PRIV" 2>/dev/null | awk '/Public/{print $3}' || echo "")
  local REALITY_SHORT; REALITY_SHORT=$(openssl rand -hex 4)

  cat > /etc/vpn-script/xray.keys <<KEYS
SS_PASS=$SS_PASS
SS_PASS2=$SS_PASS2
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SHORT=$REALITY_SHORT
KEYS
  chmod 600 /etc/vpn-script/xray.keys

  cat > /etc/xray/config.json <<XEOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vmess-ws", "port": 10086, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } }
    },
    {
      "tag": "vless-ws", "port": 10087, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless" } }
    },
    {
      "tag": "trojan-ws", "port": 10088, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan" } }
    },
    {
      "tag": "vless-reality", "port": 8443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.google.com:443", "xver": 0, "serverNames": ["www.google.com", "www.microsoft.com"],
          "privateKey": "$REALITY_PRIV", "shortIds": ["$REALITY_SHORT"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": {} },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ]
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
# تم تصحيح الأمر ليعمل مع الإصدارات الحديثة من Xray
ExecStart=$XRAY_BIN run -config /etc/xray/config.json 
Restart=on-failure
RestartPreventExitStatus=23
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray
}

nginx_config() {
  cat > /etc/nginx/conf.d/vpn-script.conf <<'NGXEOF'
upstream vmess_ws   { server 127.0.0.1:10086; }
upstream vless_ws   { server 127.0.0.1:10087; }
upstream trojan_ws  { server 127.0.0.1:10088; }
upstream ssh_ws     { server 127.0.0.1:8880;  }

map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
  listen 80 reuseport;
  server_name _;
  location / { return 301 https://$host$request_uri; }
  location /vmess { proxy_pass http://vmess_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; proxy_read_timeout 86400s; }
  location /vless { proxy_pass http://vless_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; proxy_read_timeout 86400s; }
  location /trojan { proxy_pass http://trojan_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; proxy_read_timeout 86400s; }
  location /ssh { proxy_pass http://ssh_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; proxy_read_timeout 86400s; }
}

server {
  listen 443 ssl http2 reuseport;
  server_name _;
  ssl_certificate /etc/xray/xray.crt;
  ssl_certificate_key /etc/xray/xray.key;
  ssl_protocols TLSv1.2 TLSv1.3;
  
  location / { return 200 "ok\n"; }
  location /vmess { proxy_pass http://vmess_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; }
  location /vless { proxy_pass http://vless_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; }
  location /trojan { proxy_pass http://trojan_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; }
  location /ssh { proxy_pass http://ssh_ws; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_set_header Host $host; }
}
NGXEOF

  rm -f /etc/nginx/sites-enabled/default
  nginx -t || true
  systemctl enable nginx
}

stunnel_config() {
  cat > /etc/stunnel/stunnel.conf <<'EOF'
cert = /etc/xray/funny.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[openssh]
accept = 777
connect = 127.0.0.1:3303
[dropbear]
accept = 447
connect = 127.0.0.1:109
EOF
  sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || echo "ENABLED=1" > /etc/default/stunnel4
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
    except: pass
    try: a.close(); b.close()
    except: pass

def handle(c):
    try:
        c.recv(4096)
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        r = socket.create_connection(TARGET, timeout=10)
        threading.Thread(target=pipe, args=(c, r), daemon=True).start()
        pipe(r, c)
    except:
        try: c.close()
        except: pass

s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
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
CHAIN="BT_BLOCK"
iptables -N "$CHAIN" 2>/dev/null || true
iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD -j "$CHAIN"
iptables -C OUTPUT  -j "$CHAIN" 2>/dev/null || iptables -I OUTPUT  -j "$CHAIN"
for s in "BitTorrent" "bittorrent" "peer_id=" ".torrent" "info_hash"; do
  iptables -C "$CHAIN" -m string --string "$s" --algo bm -j DROP 2>/dev/null || iptables -A "$CHAIN" -m string --string "$s" --algo bm -j DROP
done
for p in 6881 6882 6883 6884 6885 6886 6887 6888 6889 51413; do
  iptables -C "$CHAIN" -p tcp --dport "$p" -j DROP 2>/dev/null || iptables -A "$CHAIN" -p tcp --dport "$p" -j DROP
  iptables -C "$CHAIN" -p udp --dport "$p" -j DROP 2>/dev/null || iptables -A "$CHAIN" -p udp --dport "$p" -j DROP
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
  systemctl enable block-torrent
}

bot_install() {
  install -d /opt/vpn-script/bot /etc/vpn-script
  cat > /opt/vpn-script/bot/bot.py <<'BOTPY'
#!/usr/bin/env python3
import os, re, json, uuid, subprocess, secrets, string, base64, logging
from pathlib import Path
from datetime import datetime, timedelta
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ConversationHandler, MessageHandler, ContextTypes, filters

logging.basicConfig(format="%(asctime)s %(message)s", level=logging.INFO)
log = logging.getLogger(__name__)

ENV = Path("/etc/vpn-script/bot.env")
DOMAIN = Path("/etc/xray/domain")
if ENV.exists():
    for line in ENV.read_text().splitlines():
        if "=" in line: k, v = line.split("=", 1); os.environ[k.strip()] = v.strip()

TOKEN = os.getenv("BOT_TOKEN", "")
ADMINS = [int(x) for x in os.getenv("ADMIN_IDS", "").split(",") if x.strip().isdigit()]
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
SSH_USER, SSH_PASS, SSH_DAYS, SSH_QUOTA = range(4)
XRAY_NAME, XRAY_DAYS, XRAY_PROTO = range(4, 7)

def run(cmd):
    try: return subprocess.run(cmd, shell=True, text=True, capture_output=True).stdout.strip() or "تم"
    except Exception as e: return str(e)

def dom(): return DOMAIN.read_text().strip() if DOMAIN.exists() else run("hostname -I | awk '{print $1}'")

def admin_only(fn):
    async def w(update, ctx):
        if not (update.effective_user and update.effective_user.id in ADMINS): return
        return await fn(update, ctx)
    return w

def menu():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("👤 SSH", callback_data="ssh_menu"), InlineKeyboardButton("🧬 Xray", callback_data="xray_menu")],
        [InlineKeyboardButton("♻️ إعادة تشغيل", callback_data="restart")]
    ])

@admin_only
async def start(update, ctx): await update.message.reply_text("✅ لوحة التحكم", reply_markup=menu())

@admin_only
async def router(update, ctx):
    q = update.callback_query; await q.answer()
    if q.data == "ssh_menu": await q.edit_message_text("👤 SSH", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("➕ إنشاء SSH", callback_data="ssh_create")],[InlineKeyboardButton("🔙 رجوع", callback_data="back")]]))
    elif q.data == "xray_menu": await q.edit_message_text("🧬 Xray", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("➕ إنشاء Xray", callback_data="xray_create")],[InlineKeyboardButton("🔙 رجوع", callback_data="back")]]))
    elif q.data == "back": await q.edit_message_text("✅ القائمة", reply_markup=menu())
    elif q.data == "restart":
        run("systemctl restart xray nginx ssh stunnel4 dropbear ssh-ws")
        await q.edit_message_text("♻️ تم", reply_markup=menu())

# === دالة حقن حسابات Xray بالكونفج (تمت الإضافة) ===
def inject_xray_user(proto, credential, name):
    cfg_file = "/etc/xray/config.json"
    with open(cfg_file, 'r') as f: data = json.load(f)
    for ib in data.get("inbounds", []):
        tag = ib.get("tag", "")
        if proto in tag:
            clients = ib.setdefault("settings", {}).setdefault("clients", [])
            if proto == "vmess": clients.append({"id": credential, "alterId": 0, "email": name})
            elif proto == "vless": 
                c = {"id": credential, "email": name}
                if "reality" in tag: c["flow"] = "xtls-rprx-vision"
                clients.append(c)
            elif proto == "trojan": clients.append({"password": credential, "email": name})
    with open(cfg_file, 'w') as f: json.dump(data, f, indent=2)
    run("systemctl restart xray")

@admin_only
async def ssh_create(update, ctx):
    q = update.callback_query; await q.answer(); await q.edit_message_text("👤 اسم المستخدم:"); return SSH_USER

async def ssh_user(update, ctx):
    ctx.user_data["u"] = update.message.text.strip(); await update.message.reply_text("🔑 الباسورد:"); return SSH_PASS
async def ssh_pass(update, ctx):
    ctx.user_data["p"] = update.message.text.strip(); await update.message.reply_text("📅 الأيام:"); return SSH_DAYS
async def ssh_days(update, ctx):
    ctx.user_data["days"] = int(update.message.text.strip()); await update.message.reply_text("📶 الكوتا (0 للتعطيل):"); return SSH_QUOTA
async def ssh_quota(update, ctx):
    u, p, days = ctx.user_data["u"], ctx.user_data["p"], ctx.user_data["days"]
    exp = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    run(f"useradd -M -s /usr/sbin/nologin -e {exp} {u} && printf '%s:%s\\n' '{u}' '{p}' | chpasswd")
    await update.message.reply_text(f"✅ تم\nUser: {u}\nPass: {p}\nHost: {dom()}")
    return ConversationHandler.END

@admin_only
async def xray_create(update, ctx):
    q = update.callback_query; await q.answer(); await q.edit_message_text("🧬 اسم الحساب:"); return XRAY_NAME
async def xray_name(update, ctx):
    ctx.user_data["xname"] = update.message.text.strip(); await update.message.reply_text("📅 الأيام:"); return XRAY_DAYS
async def xray_days(update, ctx):
    ctx.user_data["xdays"] = int(update.message.text.strip())
    mk = InlineKeyboardMarkup([[InlineKeyboardButton("🔷 VMess", callback_data="xp_vmess"), InlineKeyboardButton("🟢 VLESS", callback_data="xp_vless"), InlineKeyboardButton("🔴 Trojan", callback_data="xp_trojan")]])
    await update.message.reply_text("🔌 البروتوكول:", reply_markup=mk); return XRAY_PROTO

async def xray_proto(update, ctx):
    q = update.callback_query; await q.answer()
    data = q.data; name = ctx.user_data["xname"]; uid = str(uuid.uuid4()); pwd = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
    d = dom(); exp = (datetime.now() + timedelta(days=ctx.user_data["xdays"])).strftime("%Y-%m-%d")
    keys = {k.strip(): v.strip() for line in Path("/etc/vpn-script/xray.keys").read_text().splitlines() if "=" in line for k, v in [line.split("=", 1)]}
    pub, short = keys.get("REALITY_PUB", ""), keys.get("REALITY_SHORT", "")

    # إضافة allowInsecure=1 لحل مشكلة شهادات SSL الذاتية
    if data == "xp_vmess":
        inject_xray_user("vmess", uid, name)
        cfg = {"v":"2","ps":name,"add":d,"port":"443","id":uid,"aid":"0","net":"ws","type":"none","host":d,"path":"/vmess","tls":"tls"}
        msg = "🔷 VMess WS TLS:\nvmess://" + base64.b64encode(json.dumps(cfg).encode()).decode()
    elif data == "xp_vless":
        inject_xray_user("vless", uid, name)
        msg = f"🟢 VLESS Reality:\nvless://{uid}@{d}:8443?type=tcp&security=reality&pbk={pub}&sid={short}&sni=www.google.com&fp=chrome&flow=xtls-rprx-vision#{name}\n\n"
        msg += f"🟢 VLESS WS TLS:\nvless://{uid}@{d}:443?type=ws&security=tls&host={d}&path=%2Fvless&sni={d}&allowInsecure=1#{name}"
    elif data == "xp_trojan":
        inject_xray_user("trojan", pwd, name)
        msg = f"🔴 Trojan WS TLS:\ntrojan://{pwd}@{d}:443?type=ws&security=tls&host={d}&path=%2Ftrojan&sni={d}&allowInsecure=1#{name}"
    
    await q.edit_message_text(f"✅ {name} | Exp: {exp}\n\n{msg}", disable_web_page_preview=True)
    return ConversationHandler.END

async def cancel(update, ctx): return ConversationHandler.END

def main():
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(ConversationHandler(entry_points=[CallbackQueryHandler(ssh_create, pattern="^ssh_create$")], states={SSH_USER:[MessageHandler(filters.TEXT, ssh_user)], SSH_PASS:[MessageHandler(filters.TEXT, ssh_pass)], SSH_DAYS:[MessageHandler(filters.TEXT, ssh_days)], SSH_QUOTA:[MessageHandler(filters.TEXT, ssh_quota)]}, fallbacks=[CommandHandler("cancel", cancel)]))
    app.add_handler(ConversationHandler(entry_points=[CallbackQueryHandler(xray_create, pattern="^xray_create$")], states={XRAY_NAME:[MessageHandler(filters.TEXT, xray_name)], XRAY_DAYS:[MessageHandler(filters.TEXT, xray_days)], XRAY_PROTO:[CallbackQueryHandler(xray_proto, pattern="^xp_")]}, fallbacks=[CommandHandler("cancel", cancel)]))
    app.add_handler(CallbackQueryHandler(router))
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__": main()
BOTPY

  chmod 700 /opt/vpn-script/bot/bot.py
  python3 -m venv /opt/vpn-script/venv
  /opt/vpn-script/venv/bin/pip install --upgrade pip -q
  /opt/vpn-script/venv/bin/pip install "python-telegram-bot>=22,<23" -q

  cat > /etc/systemd/system/vpn-bot.service <<'EOF'
[Unit]
Description=VPN Bot
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
  for p in 22 3303 69 109 111 80 443 444 447 777 8080 8443 8880 8388 8389; do ufw allow "$p/tcp" || true; done
  yes | ufw enable || true
}

services_start() {
  systemctl daemon-reload
  systemctl restart block-torrent >> "$LOG" 2>&1 || true
  for s in ssh dropbear stunnel4 nginx xray ssh-ws vpn-bot cron; do systemctl restart "$s" >> "$LOG" 2>&1 || true; done
  sleep 3
}

main() {
  need_root
  : > "$LOG"
  ask_inputs
  run_step  "Fix apt"                  fix_apt
  run_step  "Install packages"         packages
  run_step  "Prepare directories"      dirs
  run_step  "Configure SSH"            ssh_dropbear
  run_step  "Create certificates"      certs
  run_step  "Install Xray"             xray_install
  run_step  "Configure Nginx"          nginx_config
  run_step  "Configure Stunnel"        stunnel_config
  run_step  "Install SSH WS"           ssh_ws
  run_step  "Install Torrent blocker"  torrent_block
  run_step  "Install Telegram bot"     bot_install
  run_step  "Configure firewall"       firewall
  run_step  "Start services"           services_start
  
  echo -e "\n${GREEN}✅ Installation completed successfully!${NC}"
  echo "Bot is ready. Send /start in Telegram."
}
main "$@"
