#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
LOG="/var/log/aio-vpn-install.log"
TOTAL_STEPS=22
CURRENT_STEP=0
export DEBIAN_FRONTEND=noninteractive

progress_bar() {
    local current="$1"; local total="$2"; local label="$3"
    local width=40
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local percent=$(( current * 100 / total ))
    printf "\r${CYAN}["
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "] ${YELLOW}%3d%%${NC} %s" "$percent" "$label"
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local label="$1"; shift
    echo
    progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "$label"
    echo
    "$@" >>"$LOG" 2>&1
}

die() { echo -e "\n${RED}ERROR:${NC} $1"; echo "Check log: $LOG"; exit 1; }
need_root() { [[ "$EUID" -eq 0 ]] || die "Run as root."; }

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in ubuntu|debian) ;; *) echo "Warning: untested OS: $PRETTY_NAME" ;; esac
    fi
}

ask_inputs() {
    echo -e "${CYAN}AIO VPN Manager 2026 Installer${NC}"
    echo "Installer output is English only. Telegram bot UI is Arabic."
    echo
    read -rp "Domain/subdomain pointing to VPS: " DOMAIN
    [[ -n "$DOMAIN" ]] || die "Domain is required"
    read -rp "Telegram BOT_TOKEN: " BOT_TOKEN
    [[ -n "$BOT_TOKEN" ]] || die "BOT_TOKEN is required"
    read -rp "Telegram ADMIN_ID or comma-separated IDs: " ADMIN_IDS
    [[ -n "$ADMIN_IDS" ]] || die "ADMIN_IDS is required"
    read -rp "Enable SlowDNS placeholder? Requires NS record. [y/N]: " ENABLE_SLOWDNS
    if [[ "${ENABLE_SLOWDNS,,}" == "y" ]]; then
        read -rp "SlowDNS NS domain, e.g. ns.example.com: " NS_DOMAIN
    else
        NS_DOMAIN=""
    fi
    mkdir -p /etc/aio-bot /etc/xray /etc/slowdns
    echo "$DOMAIN" > /etc/xray/domain
    echo "$NS_DOMAIN" > /etc/slowdns/nsdomain
    cat > /etc/aio-bot/.env <<EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_IDS
EOF
    chmod 600 /etc/aio-bot/.env
}

fix_apt() {
    dpkg --configure -a || true
    apt-get -f install -y || true
    apt-get clean || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock || true
}

install_packages() {
    apt-get update -y
    apt-get install -y ca-certificates curl wget unzip zip jq git sudo cron at lsof htop iftop lnav screen nano sed \
        iproute2 net-tools dnsutils socat iptables ufw vnstat openssl build-essential dirmngr gnupg \
        python3 python3-venv python3-pip nginx haproxy dropbear stunnel4 speedtest-cli figlet bc ruby lsb-release passwd
}

prepare_dirs() {
    mkdir -p /etc/xray /etc/aio-bot /etc/aio-bot/quota /var/log/xray /etc/noobzvpns /usr/local/aio
    touch /var/log/xray/access.log /var/log/xray/error.log "$LOG"
    chmod 644 /var/log/xray/*.log
    curl -fsS ifconfig.me > /etc/xray/.ip || hostname -I | awk '{print $1}' > /etc/xray/.ip
}

configure_ssh() {
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-aio-ports.conf <<'EOF'
Port 22
Port 3303
PasswordAuthentication yes
PermitRootLogin yes
EOF
    systemctl restart ssh || systemctl restart sshd || true
    cat > /etc/issue.net <<'EOF'
====================================
        AIO VPN Premium Server
====================================
EOF
    cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=111
DROPBEAR_EXTRA_ARGS="-p 109 -p 69"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
    grep -qxF "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells
    grep -qxF "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells
    systemctl enable dropbear
    systemctl restart dropbear || true
}

make_cert() {
    DOMAIN="$(cat /etc/xray/domain)"
    openssl genrsa -out /etc/xray/xray.key 2048
    openssl req -new -x509 -key /etc/xray/xray.key -out /etc/xray/xray.crt -days 1095 \
      -subj "/C=US/ST=NA/L=NA/O=AIO/OU=VPN/CN=$DOMAIN/emailAddress=admin@$DOMAIN"
    cat /etc/xray/xray.key /etc/xray/xray.crt > /etc/xray/funny.pem
    cp /etc/xray/xray.crt /etc/noobzvpns/cert.pem
    cp /etc/xray/xray.key /etc/noobzvpns/key.pem
    chmod 600 /etc/xray/xray.key /etc/xray/funny.pem /etc/noobzvpns/key.pem
    chmod 644 /etc/xray/xray.crt /etc/noobzvpns/cert.pem
}

install_xray() {
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root || true
    XRAY_BIN="/usr/local/bin/xray"
    [[ -x "$XRAY_BIN" ]] || XRAY_BIN="/usr/bin/xray"
    cat /proc/sys/kernel/random/uuid > /etc/xray/.key
    chmod 600 /etc/xray/.key
    cat > /etc/xray/config.json <<'EOF'
{
  "log": {"access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning"},
  "inbounds": [
    {"tag": "vmess-ws", "port": 10086, "listen": "127.0.0.1", "protocol": "vmess", "settings": {"clients": []}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess"}}},
    {"tag": "vless-ws", "port": 10087, "listen": "127.0.0.1", "protocol": "vless", "settings": {"clients": [], "decryption": "none"}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless"}}},
    {"tag": "trojan-ws", "port": 10088, "listen": "127.0.0.1", "protocol": "trojan", "settings": {"clients": []}, "streamSettings": {"network": "ws", "wsSettings": {"path": "/trojan"}}}
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF
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

configure_nginx() {
    rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default
    cat > /etc/nginx/conf.d/aio-vpn.conf <<'EOF'
server {
    listen 80;
    server_name _;
    location / { return 200 "AIO VPN Manager is running\n"; }
    location /vmess { proxy_pass http://127.0.0.1:10086; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
    location /vless { proxy_pass http://127.0.0.1:10087; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
    location /trojan { proxy_pass http://127.0.0.1:10088; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
    location /ssh { proxy_pass http://127.0.0.1:8880; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
}
server {
    listen 443 ssl http2;
    server_name _;
    ssl_certificate /etc/xray/xray.crt;
    ssl_certificate_key /etc/xray/xray.key;
    location / { return 200 "AIO VPN Manager TLS is running\n"; }
    location /vmess { proxy_pass http://127.0.0.1:10086; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
    location /vless { proxy_pass http://127.0.0.1:10087; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
    location /trojan { proxy_pass http://127.0.0.1:10088; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
    location /ssh { proxy_pass http://127.0.0.1:8880; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; }
}
EOF
    nginx -t
    systemctl enable nginx
}

configure_stunnel() {
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
[openvpn]
accept = 444
connect = 127.0.0.1:1194
EOF
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || echo "ENABLED=1" > /etc/default/stunnel4
    systemctl enable stunnel4
}

install_ssh_ws() {
    cat > /usr/local/bin/ssh-ws-proxy.py <<'PY'
#!/usr/bin/env python3
import socket, threading
LISTEN=("127.0.0.1", 8880)
TARGET=("127.0.0.1", 22)
def pipe(a,b):
    try:
        while True:
            d=a.recv(4096)
            if not d: break
            b.sendall(d)
    except Exception: pass
    try: a.close(); b.close()
    except Exception: pass
def handle(c):
    try:
        c.recv(4096)
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        r=socket.create_connection(TARGET, timeout=10)
        threading.Thread(target=pipe,args=(c,r),daemon=True).start()
        pipe(r,c)
    except Exception:
        try: c.close()
        except Exception: pass
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(LISTEN); s.listen(200)
while True:
    c,_=s.accept(); threading.Thread(target=handle,args=(c,),daemon=True).start()
PY
    chmod +x /usr/local/bin/ssh-ws-proxy.py
    cat > /etc/systemd/system/ssh-ws.service <<'EOF'
[Unit]
Description=SSH WebSocket proxy
After=network-online.target
[Service]
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws-proxy.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ssh-ws
}

install_noobz_badvpn() {
    curl -fsSL https://github.com/noobz-id/noobzvpns/raw/master/noobzvpns.x86_64 -o /usr/bin/noobzvpns || true
    chmod +x /usr/bin/noobzvpns || true
    cat > /etc/noobzvpns/config.json <<'EOF'
{"tcp_std":[8080],"tcp_ssl":[8443],"ssl_cert":"/etc/noobzvpns/cert.pem","ssl_key":"/etc/noobzvpns/key.pem","ssl_version":"AUTO","conn_timeout":60,"dns_resolver":"/etc/resolv.conf","http_ok":"HTTP/1.1 101 Switching Protocols[crlf]Upgrade: websocket[crlf][crlf]"}
EOF
    cat > /etc/systemd/system/noobzvpns.service <<'EOF'
[Unit]
Description=NoobzVPN Server
After=network-online.target
[Service]
User=root
ExecStart=/usr/bin/noobzvpns -c /etc/noobzvpns/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    curl -fsSL https://raw.githubusercontent.com/powermx/badvpn/master/badvpn-udpgw -o /usr/bin/badvpn || true
    chmod +x /usr/bin/badvpn || true
    cat > /etc/systemd/system/badvpn.service <<'EOF'
[Unit]
Description=BadVPN UDPGW
After=network-online.target
[Service]
User=root
ExecStart=/usr/bin/badvpn --listen-addr 127.0.0.1:7300 --max-clients 500
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable noobzvpns badvpn || true
}

slowdns_prepare() {
    NS_DOMAIN="$(cat /etc/slowdns/nsdomain 2>/dev/null || true)"
    if [[ -n "$NS_DOMAIN" ]]; then
        curl -fsSL https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh -o /usr/local/aio/dnstt-deploy.sh || true
        chmod +x /usr/local/aio/dnstt-deploy.sh 2>/dev/null || true
    fi
}

torrent_block() {
    cat > /usr/local/sbin/block-torrent <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CHAIN="BT_BLOCK"
ensure_chain(){ iptables -N "$CHAIN" 2>/dev/null || true; iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD -j "$CHAIN"; iptables -C OUTPUT -j "$CHAIN" 2>/dev/null || iptables -I OUTPUT -j "$CHAIN"; }
add_rule(){ iptables -C "$CHAIN" "$@" 2>/dev/null || iptables -A "$CHAIN" "$@"; }
apply_rules(){ ensure_chain; for s in "BitTorrent" "BitTorrent protocol" "bittorrent" "peer_id=" ".torrent" "info_hash"; do add_rule -m string --string "$s" --algo bm -j DROP; done; for p in 6881 6882 6883 6884 6885 6886 6887 6888 6889 51413; do add_rule -p tcp --dport "$p" -j DROP; add_rule -p udp --dport "$p" -j DROP; done; mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null || true; echo applied; }
remove_rules(){ iptables -D FORWARD -j "$CHAIN" 2>/dev/null || true; iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || true; iptables -F "$CHAIN" 2>/dev/null || true; iptables -X "$CHAIN" 2>/dev/null || true; echo removed; }
case "${1:-apply}" in apply) apply_rules;; remove) remove_rules;; *) echo "Usage: $0 {apply|remove}"; exit 2;; esac
EOF
    chmod +x /usr/local/sbin/block-torrent
    cat > /etc/systemd/system/block-torrent.service <<'EOF'
[Unit]
Description=AIO torrent block
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/block-torrent apply
ExecStop=/usr/local/sbin/block-torrent remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable block-torrent || true
}

quota_checker() {
    cat > /usr/local/sbin/aio-quota-check <<'EOF'
#!/usr/bin/env bash
DIR=/etc/aio-bot/quota
mkdir -p "$DIR"
for f in "$DIR"/*.quota; do
  [[ -f "$f" ]] || continue
  u="$(basename "$f" .quota)"
  limit="$(awk -F= '$1=="LIMIT"{print $2}' "$f")"
  used="$(awk -F= '$1=="USED"{print $2}' "$f")"
  if [[ "$limit" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ && "$limit" -gt 0 && "$used" -ge "$limit" ]]; then
    pkill -u "$u" 2>/dev/null || true
    usermod -e 1970-01-02 "$u" 2>/dev/null || true
  fi
done
EOF
    chmod +x /usr/local/sbin/aio-quota-check
    cat > /etc/cron.d/aio-quota <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/sbin/aio-quota-check
EOF
}

install_bot() {
    mkdir -p /opt/aio-bot /etc/aio-bot
    base64 -d > /opt/aio-bot/bot.py <<'B64BOT'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoKaW1wb3J0IG9zLCByZSwganNvbiwgdXVpZCwgaHRtbCwgc2VjcmV0cywgc3RyaW5nLCBzdWJwcm9jZXNzLCBiYXNlNjQKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lLCB0aW1lZGVsdGEKZnJvbSB0ZWxlZ3JhbSBpbXBvcnQgVXBkYXRlLCBJbmxpbmVLZXlib2FyZEJ1dHRvbiwgSW5saW5lS2V5Ym9hcmRNYXJrdXAKZnJvbSB0ZWxlZ3JhbS5leHQgaW1wb3J0IEFwcGxpY2F0aW9uLCBDb21tYW5kSGFuZGxlciwgQ2FsbGJhY2tRdWVyeUhhbmRsZXIsIENvbnZlcnNhdGlvbkhhbmRsZXIsIE1lc3NhZ2VIYW5kbGVyLCBDb250ZXh0VHlwZXMsIGZpbHRlcnMKCkVOViA9IFBhdGgoIi9ldGMvYWlvLWJvdC8uZW52IikKQkFTRSA9IFBhdGgoIi9ldGMvYWlvLWJvdCIpClhSQVkgPSBQYXRoKCIvZXRjL3hyYXkvY29uZmlnLmpzb24iKQpTU0hfREIgPSBCQVNFIC8gInNzaF91c2Vycy5qc29uIgpYUkFZX0RCID0gQkFTRSAvICJ4cmF5X3VzZXJzLmpzb24iClFVT1RBID0gQkFTRSAvICJxdW90YSIKRE9NQUlOX0ZJTEUgPSBQYXRoKCIvZXRjL3hyYXkvZG9tYWluIikKQkFTRS5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpClFVT1RBLm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSkKCmlmIEVOVi5leGlzdHMoKToKICAgIGZvciBsaW5lIGluIEVOVi5yZWFkX3RleHQoZXJyb3JzPSJpZ25vcmUiKS5zcGxpdGxpbmVzKCk6CiAgICAgICAgaWYgIj0iIGluIGxpbmUgYW5kIG5vdCBsaW5lLnN0cmlwKCkuc3RhcnRzd2l0aCgiIyIpOgogICAgICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgICAgIG9zLmVudmlyb25bay5zdHJpcCgpXSA9IHYuc3RyaXAoKS5zdHJpcCgnIicpLnN0cmlwKCInIikKClRPS0VOID0gb3MuZ2V0ZW52KCJCT1RfVE9LRU4iLCAiIikuc3RyaXAoKQpBRE1JTlMgPSBbaW50KHgpIGZvciB4IGluIG9zLmdldGVudigiQURNSU5fSURTIiwgIiIpLnJlcGxhY2UoIiAiLCAiIikuc3BsaXQoIiwiKSBpZiB4LmlzZGlnaXQoKV0KVVNFUl9SRSA9IHJlLmNvbXBpbGUociJeW2Etel9dW2EtejAtOV8tXXswLDMxfSQiKQpTU0hfVVNFUiwgU1NIX1BBU1MsIFNTSF9EQVlTLCBTU0hfUVVPVEEsIFhSQVlfTkFNRSwgWFJBWV9EQVlTLCBFWFRfREFZUywgTkVXX1BBU1MgPSByYW5nZSg4KQpTRVJWSUNFUyA9IFsic3NoIiwgImRyb3BiZWFyIiwgInN0dW5uZWw0IiwgIm5naW54IiwgInhyYXkiLCAic3NoLXdzIiwgIm5vb2J6dnBucyIsICJiYWR2cG4iLCAiYmxvY2stdG9ycmVudCIsICJhaW8tYm90IiwgImRuc3R0Il0KCgpkZWYgcnVuKGNtZCwgdGltZW91dD0yNSk6CiAgICB0cnk6CiAgICAgICAgciA9IHN1YnByb2Nlc3MucnVuKGNtZCwgc2hlbGw9VHJ1ZSwgdGV4dD1UcnVlLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0aW1lb3V0PXRpbWVvdXQpCiAgICAgICAgcmV0dXJuIChyLnN0ZG91dCArIHIuc3RkZXJyKS5zdHJpcCgpIG9yICLYqtmFIgogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHJldHVybiBmItiu2LfYozoge2V9IgoKCmRlZiBhZG1pbih1cGRhdGUpOgogICAgcmV0dXJuIHVwZGF0ZS5lZmZlY3RpdmVfdXNlciBhbmQgdXBkYXRlLmVmZmVjdGl2ZV91c2VyLmlkIGluIEFETUlOUwoKCmRlZiBhZG1pbl9vbmx5KGZuKToKICAgIGFzeW5jIGRlZiB3cmFwKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgICAgIGlmIG5vdCBhZG1pbih1cGRhdGUpOgogICAgICAgICAgICBpZiB1cGRhdGUuZWZmZWN0aXZlX21lc3NhZ2U6CiAgICAgICAgICAgICAgICBhd2FpdCB1cGRhdGUuZWZmZWN0aXZlX21lc3NhZ2UucmVwbHlfdGV4dCgi8J+aqyDYutmK2LEg2YXYtdix2K0iKQogICAgICAgICAgICByZXR1cm4gQ29udmVyc2F0aW9uSGFuZGxlci5FTkQKICAgICAgICByZXR1cm4gYXdhaXQgZm4odXBkYXRlLCBjdHgpCiAgICByZXR1cm4gd3JhcAoKCmRlZiBqcmVhZChwYXRoLCBkZWZhdWx0KToKICAgIHRyeToKICAgICAgICByZXR1cm4ganNvbi5sb2FkcyhwYXRoLnJlYWRfdGV4dChlcnJvcnM9Imlnbm9yZSIpKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4gZGVmYXVsdAoKCmRlZiBqd3JpdGUocGF0aCwgZGF0YSk6CiAgICBwYXRoLnBhcmVudC5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCiAgICBwYXRoLndyaXRlX3RleHQoanNvbi5kdW1wcyhkYXRhLCBlbnN1cmVfYXNjaWk9RmFsc2UsIGluZGVudD0yKSkKICAgIHBhdGguY2htb2QoMG82MDApCgoKZGVmIGRvbWFpbigpOgogICAgaWYgRE9NQUlOX0ZJTEUuZXhpc3RzKCkgYW5kIERPTUFJTl9GSUxFLnJlYWRfdGV4dCgpLnN0cmlwKCk6CiAgICAgICAgcmV0dXJuIERPTUFJTl9GSUxFLnJlYWRfdGV4dCgpLnN0cmlwKCkKICAgIHJldHVybiBydW4oImhvc3RuYW1lIC1JIHwgYXdrICd7cHJpbnQgJDF9JyIpCgoKZGVmIHZhbGlkX3VzZXIodSk6CiAgICByZXR1cm4gYm9vbChVU0VSX1JFLm1hdGNoKHUpKSBhbmQgbm90IHUuc3RhcnRzd2l0aCgiLSIpCgoKZGVmIHVzZXJfZXhpc3RzKHUpOgogICAgcmV0dXJuIHN1YnByb2Nlc3MuY2FsbChmImlkIHt1fSA+L2Rldi9udWxsIDI+JjEiLCBzaGVsbD1UcnVlKSA9PSAwCgoKZGVmIHVzZXJzKCk6CiAgICBvdXQgPSBydW4oImF3ayAtRjogJyQzPj0xMDAwICYmICQxIT1cIm5vYm9keVwie3ByaW50ICQxfScgL2V0Yy9wYXNzd2QiKQogICAgcmV0dXJuIHNvcnRlZChbeC5zdHJpcCgpIGZvciB4IGluIG91dC5zcGxpdGxpbmVzKCkgaWYgeC5zdHJpcCgpXSkKCgpkZWYgcm5kKG49MTApOgogICAgY2hhcnMgPSBzdHJpbmcuYXNjaWlfbGV0dGVycyArIHN0cmluZy5kaWdpdHMKICAgIHJldHVybiAiIi5qb2luKHNlY3JldHMuY2hvaWNlKGNoYXJzKSBmb3IgXyBpbiByYW5nZShuKSkKCgpkZWYgcWZpbGUodSk6CiAgICByZXR1cm4gUVVPVEEgLyBmInt1fS5xdW90YSIKCgpkZWYgd3JpdGVfcXVvdGEodSwgZ2IsIGV4cCk6CiAgICBpZiBnYiA8PSAwOgogICAgICAgIHJldHVybgogICAgcWZpbGUodSkud3JpdGVfdGV4dChmIlVTRVJOQU1FPXt1fVxuTElNSVQ9e2ludChnYioxMDI0KjEwMjQqMTAyNCl9XG5MSU1JVF9HQj17Z2I6Z31cblVTRUQ9MFxuRVhQSVJFPXtleHB9XG4iKQogICAgcWZpbGUodSkuY2htb2QoMG82MDApCgoKZGVmIHJlYWRfcXVvdGEodSk6CiAgICBmID0gcWZpbGUodSkKICAgIGQgPSB7fQogICAgaWYgbm90IGYuZXhpc3RzKCk6CiAgICAgICAgcmV0dXJuIGQKICAgIGZvciBsaW5lIGluIGYucmVhZF90ZXh0KGVycm9ycz0iaWdub3JlIikuc3BsaXRsaW5lcygpOgogICAgICAgIGlmICI9IiBpbiBsaW5lOgogICAgICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgICAgIGRba10gPSB2CiAgICByZXR1cm4gZAoKCmRlZiBodW1hbihuKToKICAgIHRyeTogbiA9IGZsb2F0KG4pCiAgICBleGNlcHQ6IG4gPSAwCiAgICBmb3IgdW5pdCBpbiBbIkIiLCAiS0IiLCAiTUIiLCAiR0IiLCAiVEIiXToKICAgICAgICBpZiBuIDwgMTAyNDoKICAgICAgICAgICAgcmV0dXJuIGYie246LjJmfSB7dW5pdH0iCiAgICAgICAgbiAvPSAxMDI0CiAgICByZXR1cm4gZiJ7bjouMmZ9IFBCIgoKCmRlZiBtZW51X21haW4oKToKICAgIHJldHVybiBJbmxpbmVLZXlib2FyZE1hcmt1cChbCiAgICAgICAgW0lubGluZUtleWJvYXJkQnV0dG9uKCLwn5GkINit2LPYp9io2KfYqiBTU0giLCBjYWxsYmFja19kYXRhPSJtX3NzaCIpLCBJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+nrCDYrdiz2KfYqNin2KogWHJheSIsIGNhbGxiYWNrX2RhdGE9Im1feHJheSIpXSwKICAgICAgICBbSW5saW5lS2V5Ym9hcmRCdXR0b24oIvCfk4og2K3Yp9mE2Kkg2KfZhNiz2YrYsdmB2LEiLCBjYWxsYmFja19kYXRhPSJzdGF0cyIpLCBJbmxpbmVLZXlib2FyZEJ1dHRvbigi4pqZ77iPINin2YTYrtiv2YXYp9iqIiwgY2FsbGJhY2tfZGF0YT0ic2VydmljZXMiKV0sCiAgICAgICAgW0lubGluZUtleWJvYXJkQnV0dG9uKCLwn6etINin2YTYqNmI2LHYqtin2KoiLCBjYWxsYmFja19kYXRhPSJwb3J0cyIpLCBJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UjCDYp9mE2YXYqti12YTZitmGIiwgY2FsbGJhY2tfZGF0YT0ib25saW5lIildLAogICAgICAgIFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+aqyDYrdi42LEg2KfZhNiq2YjYsdmG2KoiLCBjYWxsYmFja19kYXRhPSJ0b3JyZW50X29uIiksIElubGluZUtleWJvYXJkQnV0dG9uKCLinIUg2LHZgdi5INin2YTYrdi42LEiLCBjYWxsYmFja19kYXRhPSJ0b3JyZW50X29mZiIpXSwKICAgICAgICBbSW5saW5lS2V5Ym9hcmRCdXR0b24oIvCfp7kg2KrZhti42YrZgSDYp9mE2YPYp9i0IiwgY2FsbGJhY2tfZGF0YT0iY2FjaGUiKSwgSW5saW5lS2V5Ym9hcmRCdXR0b24oIuKZu++4jyDYpdi52KfYr9ipINiq2LTYutmK2YQg2KfZhNmD2YQiLCBjYWxsYmFja19kYXRhPSJyZXN0YXJ0X2FsbCIpXQogICAgXSkKCgpkZWYgbWVudV9zc2goKToKICAgIHJldHVybiBJbmxpbmVLZXlib2FyZE1hcmt1cChbCiAgICAgICAgW0lubGluZUtleWJvYXJkQnV0dG9uKCLinpUg2KXZhti02KfYoSBTU0giLCBjYWxsYmFja19kYXRhPSJzc2hfY3JlYXRlIildLAogICAgICAgIFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+TiyDZgtin2KbZhdipIFNTSCIsIGNhbGxiYWNrX2RhdGE9InNzaF9saXN0IiksIElubGluZUtleWJvYXJkQnV0dG9uKCLwn5O2INin2YTZg9mI2KrYpyIsIGNhbGxiYWNrX2RhdGE9InNzaF9xdW90YSIpXSwKICAgICAgICBbSW5saW5lS2V5Ym9hcmRCdXR0b24oIvCflIQg2KrZhdiv2YrYryIsIGNhbGxiYWNrX2RhdGE9InNzaF9leHRfbWVudSIpLCBJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UkSDYqti62YrZitixINio2KfYs9mI2LHYryIsIGNhbGxiYWNrX2RhdGE9InNzaF9wYXNzX21lbnUiKV0sCiAgICAgICAgW0lubGluZUtleWJvYXJkQnV0dG9uKCLwn5eRINit2LDZgSIsIGNhbGxiYWNrX2RhdGE9InNzaF9kZWxfbWVudSIpXSwKICAgICAgICBbSW5saW5lS2V5Ym9hcmRCdXR0b24oIvCflJkg2LHYrNmI2LkiLCBjYWxsYmFja19kYXRhPSJiYWNrIildCiAgICBdKQoKCmRlZiBtZW51X3hyYXkoKToKICAgIHJldHVybiBJbmxpbmVLZXlib2FyZE1hcmt1cChbCiAgICAgICAgW0lubGluZUtleWJvYXJkQnV0dG9uKCLinpUg2KXZhti02KfYoSBYcmF5IiwgY2FsbGJhY2tfZGF0YT0ieHJheV9jcmVhdGUiKV0sCiAgICAgICAgW0lubGluZUtleWJvYXJkQnV0dG9uKCLwn5OLINmC2KfYptmF2KkgWHJheSIsIGNhbGxiYWNrX2RhdGE9InhyYXlfbGlzdCIpLCBJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UlyDYp9mE2LHZiNin2KjYtyIsIGNhbGxiYWNrX2RhdGE9InhyYXlfbGlua3NfbWVudSIpXSwKICAgICAgICBbSW5saW5lS2V5Ym9hcmRCdXR0b24oIvCfl5Eg2K3YsNmBIFhyYXkiLCBjYWxsYmFja19kYXRhPSJ4cmF5X2RlbF9tZW51IiksIElubGluZUtleWJvYXJkQnV0dG9uKCLimbvvuI8gUmVzdGFydCBYcmF5IiwgY2FsbGJhY2tfZGF0YT0ieHJheV9yZXN0YXJ0IildLAogICAgICAgIFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UmSDYsdis2YjYuSIsIGNhbGxiYWNrX2RhdGE9ImJhY2siKV0KICAgIF0pCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHN0YXJ0KHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgYXdhaXQgdXBkYXRlLmVmZmVjdGl2ZV9tZXNzYWdlLnJlcGx5X3RleHQoIuKchSDYo9mH2YTYp9mLINio2YMg2YHZiiDZhNmI2K3YqSDYqtit2YPZhSDYp9mE2LPZitix2YHYsVxu2KfYrtiq2LEg2YXZhiDYp9mE2YLYp9im2YXYqToiLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIG1lbnVzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcSA9IHVwZGF0ZS5jYWxsYmFja19xdWVyeQogICAgYXdhaXQgcS5hbnN3ZXIoKQogICAgaWYgcS5kYXRhID09ICJtX3NzaCI6CiAgICAgICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgi8J+RpCDYpdiv2KfYsdipINit2LPYp9io2KfYqiBTU0giLCByZXBseV9tYXJrdXA9bWVudV9zc2goKSkKICAgIGVsaWYgcS5kYXRhID09ICJtX3hyYXkiOgogICAgICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoIvCfp6wg2KXYr9in2LHYqSDYrdiz2KfYqNin2KogWHJheSIsIHJlcGx5X21hcmt1cD1tZW51X3hyYXkoKSkKICAgIGVsc2U6CiAgICAgICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgi4pyFINin2YTZgtin2KbZhdipINin2YTYsdim2YrYs9mK2KkiLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHNzaF9jcmVhdGUodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5CiAgICBhd2FpdCBxLmFuc3dlcigpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KCLwn5GkINij2K/YrtmEINin2LPZhSDYp9mE2YXYs9iq2K7Yr9mFOiIpCiAgICByZXR1cm4gU1NIX1VTRVIKCgphc3luYyBkZWYgc3NoX3VzZXIodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICB1ID0gdXBkYXRlLm1lc3NhZ2UudGV4dC5zdHJpcCgpCiAgICBpZiBub3QgdmFsaWRfdXNlcih1KToKICAgICAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLinYwg2KfYs9mFINi62YrYsSDYtdin2YTYrSDZhdir2KfZhCB1c2VyMSIpCiAgICAgICAgcmV0dXJuIFNTSF9VU0VSCiAgICBpZiB1c2VyX2V4aXN0cyh1KToKICAgICAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLimqDvuI8g2KfZhNmF2LPYqtiu2K/ZhSDZhdmI2KzZiNivIikKICAgICAgICByZXR1cm4gU1NIX1VTRVIKICAgIGN0eC51c2VyX2RhdGFbInUiXSA9IHUKICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIvCflJEg2KPYr9iu2YQg2YPZhNmF2Kkg2KfZhNmF2LHZiNixINij2YggYXV0bzoiKQogICAgcmV0dXJuIFNTSF9QQVNTCgoKYXN5bmMgZGVmIHNzaF9wYXNzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcCA9IHVwZGF0ZS5tZXNzYWdlLnRleHQuc3RyaXAoKQogICAgaWYgcC5sb3dlcigpID09ICJhdXRvIjoKICAgICAgICBwID0gcm5kKCkKICAgIGN0eC51c2VyX2RhdGFbInAiXSA9IHAKICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIvCfk4Ug2KPYr9iu2YQg2YXYr9ipINin2YTYrdiz2KfYqCDYqNin2YTYo9mK2KfZhToiKQogICAgcmV0dXJuIFNTSF9EQVlTCgoKYXN5bmMgZGVmIHNzaF9kYXlzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgdHJ5OgogICAgICAgIGRheXMgPSBpbnQodXBkYXRlLm1lc3NhZ2UudGV4dC5zdHJpcCgpKQogICAgICAgIGFzc2VydCAxIDw9IGRheXMgPD0gMzY1MAogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLinYwg2KPYr9iu2YQg2LHZgtmFINmF2YYgMSDYpdmE2YkgMzY1MCIpCiAgICAgICAgcmV0dXJuIFNTSF9EQVlTCiAgICBjdHgudXNlcl9kYXRhWyJkYXlzIl0gPSBkYXlzCiAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLwn5O2INij2K/YrtmEINin2YTZg9mI2KrYpyBHQiDYo9mIIDAg2KjZhNinINit2K86IikKICAgIHJldHVybiBTU0hfUVVPVEEKCgphc3luYyBkZWYgc3NoX3F1b3RhX2dvdCh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHRyeToKICAgICAgICBxZ2IgPSBmbG9hdCh1cGRhdGUubWVzc2FnZS50ZXh0LnN0cmlwKCkpCiAgICAgICAgYXNzZXJ0IHFnYiA+PSAwCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIuKdjCDYo9iv2K7ZhCDYsdmC2YUg2LXYrdmK2K0iKQogICAgICAgIHJldHVybiBTU0hfUVVPVEEKICAgIHUsIHAsIGRheXMgPSBjdHgudXNlcl9kYXRhWyJ1Il0sIGN0eC51c2VyX2RhdGFbInAiXSwgY3R4LnVzZXJfZGF0YVsiZGF5cyJdCiAgICBleHAgPSAoZGF0ZXRpbWUubm93KCkgKyB0aW1lZGVsdGEoZGF5cz1kYXlzKSkuc3RyZnRpbWUoIiVZLSVtLSVkIikKICAgIG91dCA9IHJ1bihmInVzZXJhZGQgLU0gLXMgL3Vzci9zYmluL25vbG9naW4gLWUge2V4cH0ge3V9IDI+JjEiKQogICAgcnVuKGYicHJpbnRmICclczolc1xcbicgJ3t1fScgJ3twfScgfCBjaHBhc3N3ZCIpCiAgICB3cml0ZV9xdW90YSh1LCBxZ2IsIGV4cCkKICAgIGRiID0ganJlYWQoU1NIX0RCLCB7fSkKICAgIGRiW3VdID0geyJwYXNzd29yZCI6IHAsICJleHBpcmUiOiBleHAsICJxdW90YV9nYiI6IHFnYn0KICAgIGp3cml0ZShTU0hfREIsIGRiKQogICAgdGV4dCA9ICgKICAgICAgICAi4pyFINiq2YUg2KXZhti02KfYoSDYrdiz2KfYqCBTU0hcbuKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgVxuIgogICAgICAgIGYi8J+RpCBVc2VyOiA8Y29kZT57aHRtbC5lc2NhcGUodSl9PC9jb2RlPlxu8J+UkSBQYXNzOiA8Y29kZT57aHRtbC5lc2NhcGUocCl9PC9jb2RlPlxu8J+ThSBFeHBpcmU6IDxjb2RlPntleHB9PC9jb2RlPlxuIgogICAgICAgIGYi8J+TtiBRdW90YTogPGNvZGU+eydVbmxpbWl0ZWQnIGlmIHFnYiA9PSAwIGVsc2Ugc3RyKHFnYikrJyBHQid9PC9jb2RlPlxu8J+MkCBIb3N0OiA8Y29kZT57aHRtbC5lc2NhcGUoZG9tYWluKCkpfTwvY29kZT5cbiIKICAgICAgICAiU1NIOiA8Y29kZT4yMiAvIDMzMDM8L2NvZGU+XG5Ecm9wYmVhcjogPGNvZGU+NjkgLyAxMDkgLyAxMTE8L2NvZGU+XG5TU0w6IDxjb2RlPjQ0NCAvIDQ0NyAvIDc3NzwvY29kZT5cbldTOiA8Y29kZT44MCAvIDQ0MyBwYXRoIC9zc2g8L2NvZGU+IgogICAgKQogICAgYXdhaXQgdXBkYXRlLm1lc3NhZ2UucmVwbHlfdGV4dCh0ZXh0LCBwYXJzZV9tb2RlPSJIVE1MIikKICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIvCfkaQg2KXYr9in2LHYqSDYrdiz2KfYqNin2KogU1NIIiwgcmVwbHlfbWFya3VwPW1lbnVfc3NoKCkpCiAgICByZXR1cm4gQ29udmVyc2F0aW9uSGFuZGxlci5FTkQKCgpAYWRtaW5fb25seQphc3luYyBkZWYgc3NoX2xpc3QodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5CiAgICBhd2FpdCBxLmFuc3dlcigpCiAgICB1cyA9IHVzZXJzKCkKICAgIGxpbmVzID0gWyLwn5OLINit2LPYp9io2KfYqiBTU0hcbuKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgSJdCiAgICBmb3IgdSBpbiB1czoKICAgICAgICBleHAgPSBydW4oZiJjaGFnZSAtbCB7dX0gMj4vZGV2L251bGwgfCBhd2sgLUY6ICcvQWNjb3VudCBleHBpcmVzL3t7cHJpbnQgJDJ9fSciKS5zdHJpcCgpCiAgICAgICAgZCA9IHJlYWRfcXVvdGEodSkKICAgICAgICBxdSA9ICLimb4g2KjZhNinINit2K8iIGlmIG5vdCBkIGVsc2UgZiJ7aHVtYW4oZC5nZXQoJ1VTRUQnLCcwJykpfS97ZC5nZXQoJ0xJTUlUX0dCJywnPycpfUdCIgogICAgICAgIGxpbmVzLmFwcGVuZChmIvCfkaQge3V9IHwg8J+ThSB7ZXhwfSB8IPCfk7Yge3F1fSIpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KCJcbiIuam9pbihsaW5lcylbOjM5MDBdIGlmIHVzIGVsc2UgItmE2Kcg2KrZiNis2K8g2K3Ys9in2KjYp9iqIiwgcmVwbHlfbWFya3VwPW1lbnVfc3NoKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHNzaF9xdW90YV9saXN0KHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcSA9IHVwZGF0ZS5jYWxsYmFja19xdWVyeQogICAgYXdhaXQgcS5hbnN3ZXIoKQogICAgbGluZXMgPSBbIvCfk7Yg2KfZhNmD2YjYqtinXG7ilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIEiXQogICAgZm9yIHUgaW4gdXNlcnMoKToKICAgICAgICBkID0gcmVhZF9xdW90YSh1KQogICAgICAgIGxpbmVzLmFwcGVuZChmIvCfkaQge3V9OiDimb4g2KjZhNinINit2K8iIGlmIG5vdCBkIGVsc2UgZiLwn5GkIHt1fToge2h1bWFuKGQuZ2V0KCdVU0VEJywnMCcpKX0ve2QuZ2V0KCdMSU1JVF9HQicsJz8nKX1HQiIpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KCJcbiIuam9pbihsaW5lcylbOjM5MDBdLCByZXBseV9tYXJrdXA9bWVudV9zc2goKSkKCgpAYWRtaW5fb25seQphc3luYyBkZWYgc3NoX2RlbF9tZW51KHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcSA9IHVwZGF0ZS5jYWxsYmFja19xdWVyeQogICAgYXdhaXQgcS5hbnN3ZXIoKQogICAga2IgPSBbW0lubGluZUtleWJvYXJkQnV0dG9uKGYi8J+XkSB7dX0iLCBjYWxsYmFja19kYXRhPWYic3NoX2RlbDp7dX0iKV0gZm9yIHUgaW4gdXNlcnMoKV0KICAgIGtiLmFwcGVuZChbSW5saW5lS2V5Ym9hcmRCdXR0b24oIvCflJkg2LHYrNmI2LkiLCBjYWxsYmFja19kYXRhPSJtX3NzaCIpXSkKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoItin2K7YqtixINin2YTYrdiz2KfYqCDZhNmE2K3YsNmBOiIsIHJlcGx5X21hcmt1cD1JbmxpbmVLZXlib2FyZE1hcmt1cChrYikpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHNzaF9kZWwodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5CiAgICBhd2FpdCBxLmFuc3dlcigpCiAgICB1ID0gcS5kYXRhLnNwbGl0KCI6IiwxKVsxXQogICAgcnVuKGYicGtpbGwgLXUge3V9IDI+L2Rldi9udWxsIHx8IHRydWU7IHVzZXJkZWwgLXIge3V9IDI+JjEgfHwgdHJ1ZSIpCiAgICBpZiBxZmlsZSh1KS5leGlzdHMoKToKICAgICAgICBxZmlsZSh1KS51bmxpbmsoKQogICAgZGIgPSBqcmVhZChTU0hfREIsIHt9KQogICAgZGIucG9wKHUsIE5vbmUpCiAgICBqd3JpdGUoU1NIX0RCLCBkYikKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoZiLwn5eRINiq2YUg2K3YsNmBIHt1fSIsIHJlcGx5X21hcmt1cD1tZW51X3NzaCgpKQoKCkBhZG1pbl9vbmx5CmFzeW5jIGRlZiBzc2hfZXh0X21lbnUodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5CiAgICBhd2FpdCBxLmFuc3dlcigpCiAgICBrYiA9IFtbSW5saW5lS2V5Ym9hcmRCdXR0b24oZiLwn5SEIHt1fSIsIGNhbGxiYWNrX2RhdGE9ZiJzc2hfZXh0Ont1fSIpXSBmb3IgdSBpbiB1c2VycygpXQogICAga2IuYXBwZW5kKFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UmSDYsdis2YjYuSIsIGNhbGxiYWNrX2RhdGE9Im1fc3NoIildKQogICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgi2KfYrtiq2LEg2KfZhNit2LPYp9ioOiIsIHJlcGx5X21hcmt1cD1JbmxpbmVLZXlib2FyZE1hcmt1cChrYikpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHNzaF9leHRfcGljayh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHEgPSB1cGRhdGUuY2FsbGJhY2tfcXVlcnkKICAgIGF3YWl0IHEuYW5zd2VyKCkKICAgIGN0eC51c2VyX2RhdGFbImV4dF91c2VyIl0gPSBxLmRhdGEuc3BsaXQoIjoiLDEpWzFdCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KCLwn5OFINij2K/YrtmEINi52K/YryDYp9mE2KPZitin2YUg2KfZhNis2K/Zitiv2Kkg2YXZhiDYp9mE2YrZiNmFOiIpCiAgICByZXR1cm4gRVhUX0RBWVMKCgphc3luYyBkZWYgc3NoX2V4dF9kYXlzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgdHJ5OgogICAgICAgIGRheXMgPSBpbnQodXBkYXRlLm1lc3NhZ2UudGV4dC5zdHJpcCgpKQogICAgZXhjZXB0OgogICAgICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIuKdjCDYsdmC2YUg2LrZitixINi12K3ZititIikKICAgICAgICByZXR1cm4gRVhUX0RBWVMKICAgIHUgPSBjdHgudXNlcl9kYXRhWyJleHRfdXNlciJdCiAgICBleHAgPSAoZGF0ZXRpbWUubm93KCkrdGltZWRlbHRhKGRheXM9ZGF5cykpLnN0cmZ0aW1lKCIlWS0lbS0lZCIpCiAgICBydW4oZiJ1c2VybW9kIC1lIHtleHB9IHt1fSIpCiAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KGYi4pyFINiq2YUg2KrZhdiv2YrYryB7dX0g2K3YqtmJIHtleHB9IikKICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIvCfkaQg2KXYr9in2LHYqSDYrdiz2KfYqNin2KogU1NIIiwgcmVwbHlfbWFya3VwPW1lbnVfc3NoKCkpCiAgICByZXR1cm4gQ29udmVyc2F0aW9uSGFuZGxlci5FTkQKCgpAYWRtaW5fb25seQphc3luYyBkZWYgc3NoX3Bhc3NfbWVudSh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHEgPSB1cGRhdGUuY2FsbGJhY2tfcXVlcnkKICAgIGF3YWl0IHEuYW5zd2VyKCkKICAgIGtiID0gW1tJbmxpbmVLZXlib2FyZEJ1dHRvbihmIvCflJEge3V9IiwgY2FsbGJhY2tfZGF0YT1mInNzaF9wYXNzOnt1fSIpXSBmb3IgdSBpbiB1c2VycygpXQogICAga2IuYXBwZW5kKFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UmSDYsdis2YjYuSIsIGNhbGxiYWNrX2RhdGE9Im1fc3NoIildKQogICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgi2KfYrtiq2LEg2KfZhNit2LPYp9ioOiIsIHJlcGx5X21hcmt1cD1JbmxpbmVLZXlib2FyZE1hcmt1cChrYikpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHNzaF9wYXNzX3BpY2sodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5CiAgICBhd2FpdCBxLmFuc3dlcigpCiAgICBjdHgudXNlcl9kYXRhWyJwYXNzX3VzZXIiXSA9IHEuZGF0YS5zcGxpdCgiOiIsMSlbMV0KICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoIvCflJEg2KPYr9iu2YQg2YPZhNmF2Kkg2KfZhNmF2LHZiNixINin2YTYrNiv2YrYr9ipINij2YggYXV0bzoiKQogICAgcmV0dXJuIE5FV19QQVNTCgoKYXN5bmMgZGVmIHNzaF9uZXdfcGFzcyh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHAgPSB1cGRhdGUubWVzc2FnZS50ZXh0LnN0cmlwKCkKICAgIGlmIHAubG93ZXIoKSA9PSAiYXV0byI6CiAgICAgICAgcCA9IHJuZCgpCiAgICB1ID0gY3R4LnVzZXJfZGF0YVsicGFzc191c2VyIl0KICAgIHJ1bihmInByaW50ZiAnJXM6JXNcXG4nICd7dX0nICd7cH0nIHwgY2hwYXNzd2QiKQogICAgYXdhaXQgdXBkYXRlLm1lc3NhZ2UucmVwbHlfdGV4dChmIuKchSDYqtmFINiq2LrZitmK2LEg2YPZhNmF2Kkg2KfZhNmF2LHZiNixXG7wn5GkIHt1fVxu8J+UkSB7cH0iKQogICAgYXdhaXQgdXBkYXRlLm1lc3NhZ2UucmVwbHlfdGV4dCgi8J+RpCDYpdiv2KfYsdipINit2LPYp9io2KfYqiBTU0giLCByZXBseV9tYXJrdXA9bWVudV9zc2goKSkKICAgIHJldHVybiBDb252ZXJzYXRpb25IYW5kbGVyLkVORAoKCmRlZiB4Y2ZnKCk6CiAgICByZXR1cm4ganJlYWQoWFJBWSwgeyJpbmJvdW5kcyI6IFtdLCAib3V0Ym91bmRzIjogW3sicHJvdG9jb2wiOiJmcmVlZG9tIn1dfSkKCgpkZWYgc2F2ZV94Y2ZnKGMpOgogICAgWFJBWS53cml0ZV90ZXh0KGpzb24uZHVtcHMoYywgaW5kZW50PTIpKQogICAgcnVuKCJzeXN0ZW1jdGwgcmVzdGFydCB4cmF5IiwgNDApCgoKZGVmIGFkZF94cmF5KG5hbWUsIHVpZCwgcHdkKToKICAgIGMgPSB4Y2ZnKCkKICAgIGZvciBpYiBpbiBjLmdldCgiaW5ib3VuZHMiLCBbXSk6CiAgICAgICAgdGFnID0gaWIuZ2V0KCJ0YWciLCAiIikKICAgICAgICBjbGllbnRzID0gaWIuc2V0ZGVmYXVsdCgic2V0dGluZ3MiLCB7fSkuc2V0ZGVmYXVsdCgiY2xpZW50cyIsIFtdKQogICAgICAgIGlmIHRhZy5zdGFydHN3aXRoKCJ2bWVzcyIpIGFuZCBub3QgYW55KHguZ2V0KCJlbWFpbCIpPT1uYW1lIGZvciB4IGluIGNsaWVudHMpOgogICAgICAgICAgICBjbGllbnRzLmFwcGVuZCh7ImlkIjogdWlkLCAiYWx0ZXJJZCI6IDAsICJlbWFpbCI6IG5hbWV9KQogICAgICAgIGlmIHRhZy5zdGFydHN3aXRoKCJ2bGVzcyIpIGFuZCBub3QgYW55KHguZ2V0KCJlbWFpbCIpPT1uYW1lIGZvciB4IGluIGNsaWVudHMpOgogICAgICAgICAgICBjbGllbnRzLmFwcGVuZCh7ImlkIjogdWlkLCAiZW1haWwiOiBuYW1lLCAiZmxvdyI6ICIifSkKICAgICAgICBpZiB0YWcuc3RhcnRzd2l0aCgidHJvamFuIikgYW5kIG5vdCBhbnkoeC5nZXQoImVtYWlsIik9PW5hbWUgZm9yIHggaW4gY2xpZW50cyk6CiAgICAgICAgICAgIGNsaWVudHMuYXBwZW5kKHsicGFzc3dvcmQiOiBwd2QsICJlbWFpbCI6IG5hbWV9KQogICAgc2F2ZV94Y2ZnKGMpCgoKZGVmIGRlbF94cmF5KG5hbWUpOgogICAgYyA9IHhjZmcoKQogICAgZm9yIGliIGluIGMuZ2V0KCJpbmJvdW5kcyIsIFtdKToKICAgICAgICBzdCA9IGliLmdldCgic2V0dGluZ3MiLCB7fSkKICAgICAgICBpZiAiY2xpZW50cyIgaW4gc3Q6CiAgICAgICAgICAgIHN0WyJjbGllbnRzIl0gPSBbeCBmb3IgeCBpbiBzdFsiY2xpZW50cyJdIGlmIHguZ2V0KCJlbWFpbCIpICE9IG5hbWVdCiAgICBzYXZlX3hjZmcoYykKCgpkZWYgeGxpbmtzKG5hbWUsIHVpZCwgcHdkKToKICAgIGQgPSBkb21haW4oKQogICAgb2JqODAgPSB7InYiOiIyIiwicHMiOmYie25hbWV9LXZtZXNzLTgwIiwiYWRkIjpkLCJwb3J0IjoiODAiLCJpZCI6dWlkLCJhaWQiOiIwIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOmQsInBhdGgiOiIvdm1lc3MiLCJ0bHMiOiIifQogICAgb2JqNDQzID0gZGljdChvYmo4MCk7IG9iajQ0M1sicHMiXT1mIntuYW1lfS12bWVzcy00NDMiOyBvYmo0NDNbInBvcnQiXT0iNDQzIjsgb2JqNDQzWyJ0bHMiXT0idGxzIgogICAgdm04MCA9ICJ2bWVzczovLyIgKyBiYXNlNjQuYjY0ZW5jb2RlKGpzb24uZHVtcHMob2JqODApLmVuY29kZSgpKS5kZWNvZGUoKQogICAgdm00NDMgPSAidm1lc3M6Ly8iICsgYmFzZTY0LmI2NGVuY29kZShqc29uLmR1bXBzKG9iajQ0MykuZW5jb2RlKCkpLmRlY29kZSgpCiAgICB2bDgwID0gZiJ2bGVzczovL3t1aWR9QHtkfTo4MD90eXBlPXdzJnNlY3VyaXR5PW5vbmUmaG9zdD17ZH0mcGF0aD0lMkZ2bGVzcyN7bmFtZX0tdmxlc3MtODAiCiAgICB2bDQ0MyA9IGYidmxlc3M6Ly97dWlkfUB7ZH06NDQzP3R5cGU9d3Mmc2VjdXJpdHk9dGxzJmhvc3Q9e2R9JnBhdGg9JTJGdmxlc3Mmc25pPXtkfSN7bmFtZX0tdmxlc3MtNDQzIgogICAgdHI4MCA9IGYidHJvamFuOi8ve3B3ZH1Ae2R9OjgwP3R5cGU9d3Mmc2VjdXJpdHk9bm9uZSZob3N0PXtkfSZwYXRoPSUyRnRyb2phbiN7bmFtZX0tdHJvamFuLTgwIgogICAgdHI0NDMgPSBmInRyb2phbjovL3twd2R9QHtkfTo0NDM/dHlwZT13cyZzZWN1cml0eT10bHMmaG9zdD17ZH0mcGF0aD0lMkZ0cm9qYW4mc25pPXtkfSN7bmFtZX0tdHJvamFuLTQ0MyIKICAgIHJldHVybiBmIvCfp6wg2LHZiNin2KjYtyB7bmFtZX1cblxuVk1lc3MgODA6XG48Y29kZT57aHRtbC5lc2NhcGUodm04MCl9PC9jb2RlPlxuXG5WTWVzcyA0NDM6XG48Y29kZT57aHRtbC5lc2NhcGUodm00NDMpfTwvY29kZT5cblxuVkxFU1MgODA6XG48Y29kZT57aHRtbC5lc2NhcGUodmw4MCl9PC9jb2RlPlxuXG5WTEVTUyA0NDM6XG48Y29kZT57aHRtbC5lc2NhcGUodmw0NDMpfTwvY29kZT5cblxuVHJvamFuIDgwOlxuPGNvZGU+e2h0bWwuZXNjYXBlKHRyODApfTwvY29kZT5cblxuVHJvamFuIDQ0Mzpcbjxjb2RlPntodG1sLmVzY2FwZSh0cjQ0Myl9PC9jb2RlPiIKCgpAYWRtaW5fb25seQphc3luYyBkZWYgeHJheV9jcmVhdGUodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5OyBhd2FpdCBxLmFuc3dlcigpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KCLwn6esINij2K/YrtmEINin2LPZhSDYrdiz2KfYqCBYcmF5OiIpCiAgICByZXR1cm4gWFJBWV9OQU1FCgoKYXN5bmMgZGVmIHhyYXlfbmFtZSh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIG4gPSB1cGRhdGUubWVzc2FnZS50ZXh0LnN0cmlwKCkKICAgIGlmIG5vdCB2YWxpZF91c2VyKG4pOgogICAgICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIuKdjCDYp9iz2YUg2LrZitixINi12KfZhNitIikKICAgICAgICByZXR1cm4gWFJBWV9OQU1FCiAgICBkYiA9IGpyZWFkKFhSQVlfREIsIHt9KQogICAgaWYgbiBpbiBkYjoKICAgICAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLimqDvuI8g2YXZiNis2YjYryDZhdiz2KjZgtin2YsiKQogICAgICAgIHJldHVybiBYUkFZX05BTUUKICAgIGN0eC51c2VyX2RhdGFbInhuYW1lIl0gPSBuCiAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLwn5OFINij2K/YrtmEINmF2K/YqSDYp9mE2K3Ys9in2Kgg2KjYp9mE2KPZitin2YU6IikKICAgIHJldHVybiBYUkFZX0RBWVMKCgphc3luYyBkZWYgeHJheV9kYXlzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgdHJ5OgogICAgICAgIGRheXMgPSBpbnQodXBkYXRlLm1lc3NhZ2UudGV4dC5zdHJpcCgpKQogICAgZXhjZXB0OgogICAgICAgIGF3YWl0IHVwZGF0ZS5tZXNzYWdlLnJlcGx5X3RleHQoIuKdjCDYsdmC2YUg2LrZitixINi12K3ZititIikKICAgICAgICByZXR1cm4gWFJBWV9EQVlTCiAgICBuID0gY3R4LnVzZXJfZGF0YVsieG5hbWUiXQogICAgdWlkID0gc3RyKHV1aWQudXVpZDQoKSkKICAgIHB3ZCA9IHJuZCgxNikKICAgIGV4cCA9IChkYXRldGltZS5ub3coKSt0aW1lZGVsdGEoZGF5cz1kYXlzKSkuc3RyZnRpbWUoIiVZLSVtLSVkIikKICAgIGFkZF94cmF5KG4sIHVpZCwgcHdkKQogICAgZGIgPSBqcmVhZChYUkFZX0RCLCB7fSkKICAgIGRiW25dID0geyJ1dWlkIjogdWlkLCAicGFzc3dvcmQiOiBwd2QsICJleHBpcmUiOiBleHB9CiAgICBqd3JpdGUoWFJBWV9EQiwgZGIpCiAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KGYi4pyFINiq2YUg2KXZhti02KfYoSBYcmF5XG7wn5OFIHtleHB9XG5cbnt4bGlua3Mobix1aWQscHdkKX0iLCBwYXJzZV9tb2RlPSJIVE1MIiwgZGlzYWJsZV93ZWJfcGFnZV9wcmV2aWV3PVRydWUpCiAgICBhd2FpdCB1cGRhdGUubWVzc2FnZS5yZXBseV90ZXh0KCLwn6esINil2K/Yp9ix2Kkg2K3Ys9in2KjYp9iqIFhyYXkiLCByZXBseV9tYXJrdXA9bWVudV94cmF5KCkpCiAgICByZXR1cm4gQ29udmVyc2F0aW9uSGFuZGxlci5FTkQKCgpAYWRtaW5fb25seQphc3luYyBkZWYgeHJheV9saXN0KHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcSA9IHVwZGF0ZS5jYWxsYmFja19xdWVyeTsgYXdhaXQgcS5hbnN3ZXIoKQogICAgZGIgPSBqcmVhZChYUkFZX0RCLCB7fSkKICAgIGxpbmVzID0gWyLwn5OLINit2LPYp9io2KfYqiBYcmF5XG7ilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIHilIEiXSArIFtmIvCfp6wge259IHwg8J+ThSB7di5nZXQoJ2V4cGlyZScsJ04vQScpfSIgZm9yIG4sdiBpbiBkYi5pdGVtcygpXQogICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgiXG4iLmpvaW4obGluZXMpIGlmIGRiIGVsc2UgItmE2Kcg2KrZiNis2K8g2K3Ys9in2KjYp9iqIFhyYXkiLCByZXBseV9tYXJrdXA9bWVudV94cmF5KCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHhyYXlfZGVsX21lbnUodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5OyBhd2FpdCBxLmFuc3dlcigpCiAgICBkYiA9IGpyZWFkKFhSQVlfREIsIHt9KQogICAga2IgPSBbW0lubGluZUtleWJvYXJkQnV0dG9uKGYi8J+XkSB7bn0iLCBjYWxsYmFja19kYXRhPWYieHJheV9kZWw6e259IildIGZvciBuIGluIGRiXQogICAga2IuYXBwZW5kKFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UmSDYsdis2YjYuSIsIGNhbGxiYWNrX2RhdGE9Im1feHJheSIpXSkKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoItin2K7YqtixINin2YTYrdiz2KfYqCDZhNmE2K3YsNmBOiIsIHJlcGx5X21hcmt1cD1JbmxpbmVLZXlib2FyZE1hcmt1cChrYikpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHhyYXlfZGVsKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcSA9IHVwZGF0ZS5jYWxsYmFja19xdWVyeTsgYXdhaXQgcS5hbnN3ZXIoKQogICAgbiA9IHEuZGF0YS5zcGxpdCgiOiIsMSlbMV0KICAgIGRlbF94cmF5KG4pCiAgICBkYiA9IGpyZWFkKFhSQVlfREIsIHt9KTsgZGIucG9wKG4sIE5vbmUpOyBqd3JpdGUoWFJBWV9EQiwgZGIpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KGYi8J+XkSDYqtmFINit2LDZgSB7bn0iLCByZXBseV9tYXJrdXA9bWVudV94cmF5KCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHhyYXlfbGlua3NfbWVudSh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHEgPSB1cGRhdGUuY2FsbGJhY2tfcXVlcnk7IGF3YWl0IHEuYW5zd2VyKCkKICAgIGRiID0ganJlYWQoWFJBWV9EQiwge30pCiAgICBrYiA9IFtbSW5saW5lS2V5Ym9hcmRCdXR0b24oZiLwn5SXIHtufSIsIGNhbGxiYWNrX2RhdGE9ZiJ4cmF5X2xpbms6e259IildIGZvciBuIGluIGRiXQogICAga2IuYXBwZW5kKFtJbmxpbmVLZXlib2FyZEJ1dHRvbigi8J+UmSDYsdis2YjYuSIsIGNhbGxiYWNrX2RhdGE9Im1feHJheSIpXSkKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoItin2K7YqtixINin2YTYrdiz2KfYqDoiLCByZXBseV9tYXJrdXA9SW5saW5lS2V5Ym9hcmRNYXJrdXAoa2IpKQoKCkBhZG1pbl9vbmx5CmFzeW5jIGRlZiB4cmF5X2xpbmsodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxID0gdXBkYXRlLmNhbGxiYWNrX3F1ZXJ5OyBhd2FpdCBxLmFuc3dlcigpCiAgICBuID0gcS5kYXRhLnNwbGl0KCI6IiwxKVsxXQogICAgZGIgPSBqcmVhZChYUkFZX0RCLCB7fSkKICAgIHYgPSBkYi5nZXQobikKICAgIGlmIG5vdCB2OgogICAgICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoIti62YrYsSDZhdmI2KzZiNivIiwgcmVwbHlfbWFya3VwPW1lbnVfeHJheSgpKTsgcmV0dXJuCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KHhsaW5rcyhuLCB2WyJ1dWlkIl0sIHZbInBhc3N3b3JkIl0pWzozOTAwXSwgcGFyc2VfbW9kZT0iSFRNTCIsIHJlcGx5X21hcmt1cD1tZW51X3hyYXkoKSwgZGlzYWJsZV93ZWJfcGFnZV9wcmV2aWV3PVRydWUpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHhyYXlfcmVzdGFydCh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHE9dXBkYXRlLmNhbGxiYWNrX3F1ZXJ5OyBhd2FpdCBxLmFuc3dlcigpCiAgICBvdXQ9cnVuKCJzeXN0ZW1jdGwgcmVzdGFydCB4cmF5OyBzeXN0ZW1jdGwgaXMtYWN0aXZlIHhyYXkiKQogICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgi4pm777iPIFhyYXk6ICIrb3V0LCByZXBseV9tYXJrdXA9bWVudV94cmF5KCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHN0YXRzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcT11cGRhdGUuY2FsbGJhY2tfcXVlcnk7IGF3YWl0IHEuYW5zd2VyKCkKICAgIHRleHQgPSAi8J+TiiDYrdin2YTYqSDYp9mE2LPZitix2YHYsVxu4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSBXG4iCiAgICB0ZXh0ICs9ICLwn4yQIElQOiAiICsgcnVuKCJob3N0bmFtZSAtSSB8IGF3ayAne3ByaW50ICQxfSciKSArICJcbiIKICAgIHRleHQgKz0gIvCflJcgRG9tYWluOiAiICsgZG9tYWluKCkgKyAiXG4iCiAgICB0ZXh0ICs9ICLimqEgQ1BVOiAiICsgcnVuKCJ0b3AgLWJuMSB8IGdyZXAgJ0NwdShzKScgfCBhd2sgJ3twcmludCAkMiskNCBcIiVcIn0nIikgKyAiXG4iCiAgICB0ZXh0ICs9ICLwn5K+IFJBTTogIiArIHJ1bigiZnJlZSAtaCB8IGF3ayAnL15NZW06L3twcmludCAkM1wiL1wiJDJ9JyIpICsgIlxuIgogICAgdGV4dCArPSAi8J+SvyBEaXNrOiAiICsgcnVuKCJkZiAtaCAvIHwgYXdrICdOUj09MntwcmludCAkM1wiL1wiJDJcIiBcIiQ1fSciKSArICJcbiIKICAgIHRleHQgKz0gIuKPsSBVcHRpbWU6ICIgKyBydW4oInVwdGltZSAtcCIpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KHRleHQsIHJlcGx5X21hcmt1cD1tZW51X21haW4oKSkKCgpAYWRtaW5fb25seQphc3luYyBkZWYgc2VydmljZXModXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxPXVwZGF0ZS5jYWxsYmFja19xdWVyeTsgYXdhaXQgcS5hbnN3ZXIoKQogICAgbGluZXM9WyLimpnvuI8g2KfZhNiu2K/Zhdin2KpcbuKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgeKUgSJdCiAgICBmb3IgcyBpbiBTRVJWSUNFUzoKICAgICAgICBzdCA9IHJ1bihmInN5c3RlbWN0bCBpcy1hY3RpdmUge3N9IDI+L2Rldi9udWxsIHx8IHRydWUiKQogICAgICAgIGxpbmVzLmFwcGVuZCgoIvCfn6IiIGlmIHN0PT0iYWN0aXZlIiBlbHNlICLwn5S0IikgKyBmIiB7c306IHtzdH0iKQogICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgiXG4iLmpvaW4obGluZXMpLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHBvcnRzKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcT11cGRhdGUuY2FsbGJhY2tfcXVlcnk7IGF3YWl0IHEuYW5zd2VyKCkKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoIvCfp60g2KfZhNio2YjYsdiq2KfYqlxu4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSB4pSBXG5WMlJheS9YcmF5OiA4MCAvIDQ0M1xuVk1lc3M6IC92bWVzc1xuVkxFU1M6IC92bGVzc1xuVHJvamFuOiAvdHJvamFuXG5TU0g6IDIyIC8gMzMwM1xuRHJvcGJlYXI6IDY5IC8gMTA5IC8gMTExXG5TU0w6IDQ0NCAvIDQ0NyAvIDc3N1xuU1NIIFdTOiAvc3NoINi52YTZiSA4MC80NDNcblNsb3dETlM6IDUzMDAgVURQXG5Ob29ielZQTjogODA4MCAvIDg0NDNcbkJhZFZQTjogNzMwMCBVRFAiLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIG9ubGluZSh1cGRhdGU6IFVwZGF0ZSwgY3R4OiBDb250ZXh0VHlwZXMuREVGQVVMVF9UWVBFKToKICAgIHE9dXBkYXRlLmNhbGxiYWNrX3F1ZXJ5OyBhd2FpdCBxLmFuc3dlcigpCiAgICBhd2FpdCBxLmVkaXRfbWVzc2FnZV90ZXh0KCLwn5SMINin2YTZhdiq2LXZhNmK2YZcbiIrcnVuKCJ3aG87IGVjaG87IHNzIC10biBzdGF0ZSBlc3RhYmxpc2hlZCB8IGhlYWQgLTMwIilbOjM1MDBdLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHRvcnJlbnRfb24odXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxPXVwZGF0ZS5jYWxsYmFja19xdWVyeTsgYXdhaXQgcS5hbnN3ZXIoKQogICAgYXdhaXQgcS5lZGl0X21lc3NhZ2VfdGV4dCgi8J+aqyAiK3J1bigiL3Vzci9sb2NhbC9zYmluL2Jsb2NrLXRvcnJlbnQgYXBwbHkgMj4mMSB8fCBzeXN0ZW1jdGwgc3RhcnQgYmxvY2stdG9ycmVudCAyPiYxIilbOjEwMDBdLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIHRvcnJlbnRfb2ZmKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcT11cGRhdGUuY2FsbGJhY2tfcXVlcnk7IGF3YWl0IHEuYW5zd2VyKCkKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoIuKchSAiK3J1bigiL3Vzci9sb2NhbC9zYmluL2Jsb2NrLXRvcnJlbnQgcmVtb3ZlIDI+JjEgfHwgc3lzdGVtY3RsIHN0b3AgYmxvY2stdG9ycmVudCAyPiYxIilbOjEwMDBdLCByZXBseV9tYXJrdXA9bWVudV9tYWluKCkpCgoKQGFkbWluX29ubHkKYXN5bmMgZGVmIGNhY2hlKHVwZGF0ZTogVXBkYXRlLCBjdHg6IENvbnRleHRUeXBlcy5ERUZBVUxUX1RZUEUpOgogICAgcT11cGRhdGUuY2FsbGJhY2tfcXVlcnk7IGF3YWl0IHEuYW5zd2VyKCkKICAgIGF3YWl0IHEuZWRpdF9tZXNzYWdlX3RleHQoIvCfp7kgIitydW4oInN5bmM7IGVjaG8gMyA+IC9wcm9jL3N5cy92bS9kcm9wX2NhY2hlczsgZWNobyBkb25lIiksIHJlcGx5X21hcmt1cD1tZW51X21haW4oKSkKCgpAYWRtaW5fb25seQphc3luYyBkZWYgcmVzdGFydF9hbGwodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBxPXVwZGF0ZS5jYWxsYmFja19xdWVyeTsgYXdhaXQgcS5hbnN3ZXIoKQogICAgcnVuKCJzeXN0ZW1jdGwgcmVzdGFydCBzc2ggZHJvcGJlYXIgc3R1bm5lbDQgbmdpbnggeHJheSBzc2gtd3Mgbm9vYnp2cG5zIGJhZHZwbiBibG9jay10b3JyZW50IDI+L2Rldi9udWxsIHx8IHRydWUiLCA2MCkKICAgIGF3YWl0IHNlcnZpY2VzKHVwZGF0ZSwgY3R4KQoKCmFzeW5jIGRlZiBjYW5jZWwodXBkYXRlOiBVcGRhdGUsIGN0eDogQ29udGV4dFR5cGVzLkRFRkFVTFRfVFlQRSk6CiAgICBhd2FpdCB1cGRhdGUuZWZmZWN0aXZlX21lc3NhZ2UucmVwbHlfdGV4dCgi2KrZhSDYp9mE2KXZhNi62KfYoSIsIHJlcGx5X21hcmt1cD1tZW51X21haW4oKSkKICAgIHJldHVybiBDb252ZXJzYXRpb25IYW5kbGVyLkVORAoKCmRlZiBtYWluKCk6CiAgICBpZiBub3QgVE9LRU46CiAgICAgICAgcmFpc2UgU3lzdGVtRXhpdCgiQk9UX1RPS0VOIG1pc3NpbmciKQogICAgYXBwID0gQXBwbGljYXRpb24uYnVpbGRlcigpLnRva2VuKFRPS0VOKS5idWlsZCgpCiAgICBhcHAuYWRkX2hhbmRsZXIoQ29tbWFuZEhhbmRsZXIoInN0YXJ0Iiwgc3RhcnQpKQogICAgYXBwLmFkZF9oYW5kbGVyKENvbW1hbmRIYW5kbGVyKCJjYW5jZWwiLCBjYW5jZWwpKQogICAgYXBwLmFkZF9oYW5kbGVyKENvbnZlcnNhdGlvbkhhbmRsZXIoCiAgICAgICAgZW50cnlfcG9pbnRzPVtDYWxsYmFja1F1ZXJ5SGFuZGxlcihzc2hfY3JlYXRlLCBwYXR0ZXJuPSJec3NoX2NyZWF0ZSQiKV0sCiAgICAgICAgc3RhdGVzPXtTU0hfVVNFUjpbTWVzc2FnZUhhbmRsZXIoZmlsdGVycy5URVhUICYgfmZpbHRlcnMuQ09NTUFORCwgc3NoX3VzZXIpXSwgU1NIX1BBU1M6W01lc3NhZ2VIYW5kbGVyKGZpbHRlcnMuVEVYVCAmIH5maWx0ZXJzLkNPTU1BTkQsIHNzaF9wYXNzKV0sIFNTSF9EQVlTOltNZXNzYWdlSGFuZGxlcihmaWx0ZXJzLlRFWFQgJiB+ZmlsdGVycy5DT01NQU5ELCBzc2hfZGF5cyldLCBTU0hfUVVPVEE6W01lc3NhZ2VIYW5kbGVyKGZpbHRlcnMuVEVYVCAmIH5maWx0ZXJzLkNPTU1BTkQsIHNzaF9xdW90YV9nb3QpXX0sCiAgICAgICAgZmFsbGJhY2tzPVtDb21tYW5kSGFuZGxlcigiY2FuY2VsIiwgY2FuY2VsKSwgQ29tbWFuZEhhbmRsZXIoInN0YXJ0Iiwgc3RhcnQpXSwgYWxsb3dfcmVlbnRyeT1UcnVlKSkKICAgIGFwcC5hZGRfaGFuZGxlcihDb252ZXJzYXRpb25IYW5kbGVyKAogICAgICAgIGVudHJ5X3BvaW50cz1bQ2FsbGJhY2tRdWVyeUhhbmRsZXIoeHJheV9jcmVhdGUsIHBhdHRlcm49Il54cmF5X2NyZWF0ZSQiKV0sCiAgICAgICAgc3RhdGVzPXtYUkFZX05BTUU6W01lc3NhZ2VIYW5kbGVyKGZpbHRlcnMuVEVYVCAmIH5maWx0ZXJzLkNPTU1BTkQsIHhyYXlfbmFtZSldLCBYUkFZX0RBWVM6W01lc3NhZ2VIYW5kbGVyKGZpbHRlcnMuVEVYVCAmIH5maWx0ZXJzLkNPTU1BTkQsIHhyYXlfZGF5cyldfSwKICAgICAgICBmYWxsYmFja3M9W0NvbW1hbmRIYW5kbGVyKCJjYW5jZWwiLCBjYW5jZWwpLCBDb21tYW5kSGFuZGxlcigic3RhcnQiLCBzdGFydCldLCBhbGxvd19yZWVudHJ5PVRydWUpKQogICAgYXBwLmFkZF9oYW5kbGVyKENvbnZlcnNhdGlvbkhhbmRsZXIoCiAgICAgICAgZW50cnlfcG9pbnRzPVtDYWxsYmFja1F1ZXJ5SGFuZGxlcihzc2hfZXh0X3BpY2ssIHBhdHRlcm49Il5zc2hfZXh0OiIpXSwKICAgICAgICBzdGF0ZXM9e0VYVF9EQVlTOltNZXNzYWdlSGFuZGxlcihmaWx0ZXJzLlRFWFQgJiB+ZmlsdGVycy5DT01NQU5ELCBzc2hfZXh0X2RheXMpXX0sCiAgICAgICAgZmFsbGJhY2tzPVtDb21tYW5kSGFuZGxlcigiY2FuY2VsIiwgY2FuY2VsKSwgQ29tbWFuZEhhbmRsZXIoInN0YXJ0Iiwgc3RhcnQpXSwgYWxsb3dfcmVlbnRyeT1UcnVlKSkKICAgIGFwcC5hZGRfaGFuZGxlcihDb252ZXJzYXRpb25IYW5kbGVyKAogICAgICAgIGVudHJ5X3BvaW50cz1bQ2FsbGJhY2tRdWVyeUhhbmRsZXIoc3NoX3Bhc3NfcGljaywgcGF0dGVybj0iXnNzaF9wYXNzOiIpXSwKICAgICAgICBzdGF0ZXM9e05FV19QQVNTOltNZXNzYWdlSGFuZGxlcihmaWx0ZXJzLlRFWFQgJiB+ZmlsdGVycy5DT01NQU5ELCBzc2hfbmV3X3Bhc3MpXX0sCiAgICAgICAgZmFsbGJhY2tzPVtDb21tYW5kSGFuZGxlcigiY2FuY2VsIiwgY2FuY2VsKSwgQ29tbWFuZEhhbmRsZXIoInN0YXJ0Iiwgc3RhcnQpXSwgYWxsb3dfcmVlbnRyeT1UcnVlKSkKICAgIGhhbmRsZXJzID0gWwogICAgICAgIChtZW51cywgIl4obV9zc2h8bV94cmF5fGJhY2spJCIpLCAoc3NoX2xpc3QsICJec3NoX2xpc3QkIiksIChzc2hfcXVvdGFfbGlzdCwgIl5zc2hfcXVvdGEkIiksCiAgICAgICAgKHNzaF9kZWxfbWVudSwgIl5zc2hfZGVsX21lbnUkIiksIChzc2hfZGVsLCAiXnNzaF9kZWw6IiksIChzc2hfZXh0X21lbnUsICJec3NoX2V4dF9tZW51JCIpLAogICAgICAgIChzc2hfcGFzc19tZW51LCAiXnNzaF9wYXNzX21lbnUkIiksICh4cmF5X2xpc3QsICJeeHJheV9saXN0JCIpLCAoeHJheV9kZWxfbWVudSwgIl54cmF5X2RlbF9tZW51JCIpLAogICAgICAgICh4cmF5X2RlbCwgIl54cmF5X2RlbDoiKSwgKHhyYXlfbGlua3NfbWVudSwgIl54cmF5X2xpbmtzX21lbnUkIiksICh4cmF5X2xpbmssICJeeHJheV9saW5rOiIpLAogICAgICAgICh4cmF5X3Jlc3RhcnQsICJeeHJheV9yZXN0YXJ0JCIpLCAoc3RhdHMsICJec3RhdHMkIiksIChzZXJ2aWNlcywgIl5zZXJ2aWNlcyQiKSwgKHBvcnRzLCAiXnBvcnRzJCIpLAogICAgICAgIChvbmxpbmUsICJeb25saW5lJCIpLCAodG9ycmVudF9vbiwgIl50b3JyZW50X29uJCIpLCAodG9ycmVudF9vZmYsICJedG9ycmVudF9vZmYkIiksCiAgICAgICAgKGNhY2hlLCAiXmNhY2hlJCIpLCAocmVzdGFydF9hbGwsICJecmVzdGFydF9hbGwkIikKICAgIF0KICAgIGZvciBmbiwgcGF0IGluIGhhbmRsZXJzOgogICAgICAgIGFwcC5hZGRfaGFuZGxlcihDYWxsYmFja1F1ZXJ5SGFuZGxlcihmbiwgcGF0dGVybj1wYXQpKQogICAgYXBwLnJ1bl9wb2xsaW5nKGRyb3BfcGVuZGluZ191cGRhdGVzPVRydWUpCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIG1haW4oKQo=
B64BOT
    chmod 700 /opt/aio-bot/bot.py
    python3 -m venv /opt/aio-bot/venv
    /opt/aio-bot/venv/bin/pip install --upgrade pip
    /opt/aio-bot/venv/bin/pip install "python-telegram-bot>=22,<23"
    /opt/aio-bot/venv/bin/python -m py_compile /opt/aio-bot/bot.py
    cat > /etc/systemd/system/aio-bot.service <<'EOF'
[Unit]
Description=AIO Telegram Arabic Bot
After=network-online.target
[Service]
User=root
EnvironmentFile=/etc/aio-bot/.env
WorkingDirectory=/opt/aio-bot
ExecStart=/opt/aio-bot/venv/bin/python /opt/aio-bot/bot.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable aio-bot
}

firewall() {
    ufw default deny incoming || true
    ufw default allow outgoing || true
    for p in 22 3303 69 109 111 80 443 444 447 777 8080 8443 8880; do ufw allow "$p/tcp" || true; iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$p" -j ACCEPT; done
    for p in 5300 7300; do ufw allow "$p/udp" || true; iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$p" -j ACCEPT; done
    yes | ufw enable || true
}

start_services() {
    systemctl daemon-reload
    for s in ssh dropbear stunnel4 nginx xray ssh-ws noobzvpns badvpn block-torrent aio-bot cron; do systemctl restart "$s" >>"$LOG" 2>&1 || true; done
}

verify() {
    echo
    echo -e "${CYAN}Service status:${NC}"
    for s in ssh dropbear stunnel4 nginx xray ssh-ws noobzvpns badvpn block-torrent aio-bot; do
        st="$(systemctl is-active "$s" 2>/dev/null || true)"
        [[ "$st" == "active" ]] && echo -e "  $s: ${GREEN}$st${NC}" || echo -e "  $s: ${YELLOW}$st${NC}"
    done
}

summary() {
    IP="$(cat /etc/xray/.ip 2>/dev/null || hostname -I | awk '{print $1}')"
    DOMAIN="$(cat /etc/xray/domain)"
    echo
    echo -e "${GREEN}Installation finished.${NC}"
    echo "IP: $IP"
    echo "Domain: $DOMAIN"
    echo "V2Ray/Xray ports: 80 and 443"
    echo "Paths: /vmess /vless /trojan"
    echo "SSH: 22/3303 | Dropbear: 69/109/111 | SSL: 444/447/777 | SlowDNS UDP: 5300"
    echo "Telegram bot: send /start"
    echo "Logs: journalctl -u aio-bot -f"
}

main() {
    need_root
    : > "$LOG"
    check_os
    ask_inputs
    step "Fixing apt state" fix_apt
    step "Installing packages" install_packages
    step "Preparing directories" prepare_dirs
    step "Configuring SSH and Dropbear" configure_ssh
    step "Generating TLS certificate" make_cert
    step "Installing latest Xray" install_xray
    step "Configuring Nginx 80/443" configure_nginx
    step "Configuring Stunnel" configure_stunnel
    step "Installing SSH WebSocket" install_ssh_ws
    step "Installing NoobzVPN and BadVPN" install_noobz_badvpn
    step "Preparing SlowDNS" slowdns_prepare
    step "Installing torrent block" torrent_block
    step "Installing quota checker" quota_checker
    step "Installing Arabic Telegram bot" install_bot
    step "Configuring firewall" firewall
    step "Starting services" start_services
    step "Verifying services" verify
    while [[ "$CURRENT_STEP" -lt "$TOTAL_STEPS" ]]; do CURRENT_STEP=$((CURRENT_STEP+1)); progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Finalizing"; echo; done
    apt-get autoremove -y >>"$LOG" 2>&1 || true
    apt-get clean >>"$LOG" 2>&1 || true
    summary
}

main "$@"
