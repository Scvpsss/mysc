#!/usr/bin/env bash
# Enhanced SSH setup for Ubuntu 22.04 (stunnel TLS or WebSocket via Xray)
# Edit variabel di bawah sesuai kebutuhan.
MODE="${MODE:-stunnel}"      # "stunnel" atau "ws"
DOMAIN="${DOMAIN:-gratis.zect-store.my.id}"  # domain kamu (A record -> IP VPS)
EMAIL="${EMAIL:-sandiprayoga6666444@$DOMAIN}"              # email utk Let's Encrypt
PORT_WS="${PORT_WS:-80}"                     # port WS inbound (80 direkomendasikan)
PATH_WS="${PATH_WS:-/sshws}"                 # path WS (samakan dengan klien)

set -e

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Jalankan dengan sudo/root."
    exit 1
  fi
}

common_basics() {
  apt-get update
  apt-get install -y curl wget gnupg lsb-release ca-certificates ufw
  # pastikan ssh sudah ada
  apt-get install -y openssh-server
  systemctl enable --now ssh
}

issue_cert() {
  # Pasang certbot standalone dan ambil sertifikat untuk $DOMAIN
  apt-get install -y certbot
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
  certbot certonly --standalone -d "$DOMAIN" --agree-tos -m "$EMAIL" --non-interactive --no-eff-email
}

setup_stunnel() {
  echo "[*] Mode: stunnel (TLS/443 -> 127.0.0.1:22)"
  apt-get install -y stunnel4
  issue_cert

  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    echo "Sertifikat tidak ditemukan. Pastikan domain mengarah ke VPS (DNS Only jika pakai Cloudflare)."
    exit 1
  fi

  cat >/etc/stunnel/ssh.conf <<EOF
pid = /var/run/stunnel-ssh.pid
foreground = no
delay = yes
sslVersion = TLSv1.2
options = NO_SSLv2
options = NO_SSLv3
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh]
accept = 0.0.0.0:443
connect = 127.0.0.1:22
cert = $CERT
key  = $KEY
EOF

  # aktifkan stunnel
  sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
  systemctl enable --now stunnel4

  # buka firewall
  ufw allow 22/tcp || true
  ufw allow 443/tcp || true

  echo
  echo "Selesai. Gunakan di klien:"
  echo "- Host/SNI   : $DOMAIN"
  echo "- Port       : 443"
  echo "- Mode       : SSH over SSL/TLS (stunnel)"
  echo "- Username   : user VPS kamu"
  echo "- Auth       : password atau key"
}

setup_xray_ws() {
  echo "[*] Mode: WebSocket via Xray (WS -> 127.0.0.1:22)"
  # Install Xray (script resmi)
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "ssh-ws",
      "port": $PORT_WS,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": 22, "network": "tcp" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$PATH_WS", "headers": { "Host": "$DOMAIN" } }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

  # Jalankan Xray
  systemctl enable xray
  systemctl restart xray

  ufw allow ${PORT_WS}/tcp || true

  echo
  echo "Selesai. Gunakan di klien (HTTP Custom/Termius lewat WS):"
  echo "- Host header/SNI : $DOMAIN"
  echo "- Server/IP       : (IP VPS kamu) atau domain (DNS Only jika pakai Cloudflare)"
  echo "- Port            : $PORT_WS"
  echo "- Path            : $PATH_WS"
  echo "- Mode            : WebSocket (Upgrade)"
  echo "- Username/Pass   : akun SSH VPS kamu"
  echo
  echo "Catatan: Jika ingin TLS di 443 untuk WS, pasang Nginx TLS terminate lalu proxy ke ws di 127.0.0.1:$PORT_WS$PATH_WS."
}

post_checks() {
  echo
  echo "Cek layanan:"
  systemctl status ssh --no-pager | sed -n '1,10p'
  if [[ "$MODE" == "stunnel" ]]; then
    systemctl status stunnel4 --no-pager | sed -n '1,10p'
    echo "Tes lokal:  openssl s_client -connect 127.0.0.1:443 -servername $DOMAIN -quiet"
  else
    systemctl status xray --no-pager | sed -n '1,10p'
    echo "Tes lokal:  curl -i -N -H 'Connection: Upgrade' -H 'Upgrade: websocket' \\
      -H 'Host: $DOMAIN' 'http://127.0.0.1:$PORT_WS$PATH_WS'"
  fi
}

main() {
  need_root
  common_basics
  if [[ "$MODE" == "stunnel" ]]; then
    setup_stunnel
  elif [[ "$MODE" == "ws" ]]; then
    setup_xray_ws
  else
    echo "MODE tidak dikenal. Gunakan MODE=stunnel atau MODE=ws"
    exit 1
  fi
  post_checks
}

main "$@"
