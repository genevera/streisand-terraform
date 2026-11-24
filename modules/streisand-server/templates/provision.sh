#!/bin/bash
# Streisand provisioning script.
# Uploaded to $STREISAND_BOOT/provision.sh by the streisand-server module
# (root's home on DO/Linode, the login user's home on AWS/GCP) and run over
# SSH after the cloud-init bootstrap completes.
#
# Idempotent: every section guards with file-existence checks, safe to re-run.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# Files uploaded by Terraform land in $STREISAND_BOOT (the deploy module
# passes /home/streisand-admin/streisand-boot on every provider).
STREISAND_BOOT="${STREISAND_BOOT:-/root}"
[ -f "$STREISAND_BOOT/streisand-env.sh" ] && . "$STREISAND_BOOT/streisand-env.sh"

LOG=/var/log/streisand-provision.log
exec > >(tee -a "$LOG") 2>&1
echo "=== streisand provision start $(date -Is) ==="

FAILED=""
fail() { echo "PROVISION FAIL: $1" >&2; FAILED="$FAILED $1"; }
run() { echo "+ $*"; "$@" || fail "command failed: $*"; }

# ---------- configuration (defaults; env file overrides) ----------
PROVIDER="${PROVIDER:-generic}"
SERVER_NAME="${SERVER_NAME:-streisand}"
SSH_PORT="${SSH_PORT:-22}"
VPN_CLIENTS="${VPN_CLIENTS:-10}"
ENABLE_OPENVPN="${ENABLE_OPENVPN:-true}"
ENABLE_OPENCONNECT="${ENABLE_OPENCONNECT:-true}"
ENABLE_SHADOWSOCKS="${ENABLE_SHADOWSOCKS:-true}"
ENABLE_SSH_FORWARD="${ENABLE_SSH_FORWARD:-true}"
ENABLE_SSHUTTLE="${ENABLE_SSHUTTLE:-false}"
ENABLE_STUNNEL="${ENABLE_STUNNEL:-true}"
ENABLE_TINYPROXY="${ENABLE_TINYPROXY:-true}"
ENABLE_TOR="${ENABLE_TOR:-false}"
ENABLE_WIREGUARD="${ENABLE_WIREGUARD:-true}"
ENABLE_CLOUDFLARED="${ENABLE_CLOUDFLARED:-false}"
ENABLE_AD_BLOCKING="${ENABLE_AD_BLOCKING:-false}"
ENABLE_V2RAY="${ENABLE_V2RAY:-false}"
ENABLE_LE="${ENABLE_LE:-false}"
DOMAIN="${DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1 1.0.0.1}"
CLOUDFLARED_PORT="${CLOUDFLARED_PORT:-5053}"

# ---------- ports ----------
OPENVPN_PORT=636
OPENVPN_PORT_UDP=8757
OPENVPN_SSLH_PORT=443
OPENVPN_CIPHER="AES-256-CBC"
OPENVPN_NCP_CIPHERS="AES-256-GCM:AES-128-GCM"
OPENVPN_AUTH_DIGEST="SHA256"
STUNNEL_REMOTE_PORT=993
STUNNEL_LOCAL_PORT=41194
OCSERV_PORT=4443
SHADOWSOCKS_PORT=8530
SHADOWSOCKS_METHOD="chacha20-ietf-poly1305"
TOR_ORPORT=8443
TOR_OBFS4_PORT=9443
TOR_STATE=/var/lib/tor
TOR_PT_STATE=$TOR_STATE/pt_state
TOR_HS_DIR=$TOR_STATE/hidden_service
WIREGUARD_PORT=51820
TINYPROXY_PORT=8888
TINYPROXY_LISTEN=127.0.0.1
NGINX_PORT=443
DNSMASQ_OPENVPN_TCP_IP=10.8.0.1
DNSMASQ_OPENVPN_UDP_IP=10.9.0.1
DNSMASQ_WIREGUARD_IP=10.192.122.1
OCSERV_NET=192.168.1.0
IPT_WAIT=120
TLS_CIPHERS="ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256"
GATEWAY=/var/www/streisand
MIRROR=$GATEWAY/mirror
GATEWAY_PASS_FILE=/etc/nginx/gateway-password.txt
HTPASSWD_FILE=/etc/nginx/htpasswd
WORDLIST_SRC=$STREISAND_BOOT/english.txt
WORDLIST=/usr/share/dict/english.txt
SHUF="shuf --random-source=/dev/urandom"
IFACE=""
PUB_IP=""

# ---------- helpers ----------
detect_iface() {
  IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
  [ -z "$IFACE" ] && IFACE="eth0"
  echo "public interface: $IFACE"
}

detect_public_ip() {
  # Prefer an operator override (provider modules know the real public IP).
  if [ -n "${STREISAND_PUBLIC_IP:-}" ]; then
    PUB_IP="$STREISAND_PUBLIC_IP"
    echo "server ip (operator override): $PUB_IP"
    return 0
  fi
  case "$PROVIDER" in
    digitalocean)
      # DO assigns the public IP directly to the interface
      PUB_IP=$(ip -4 -o addr show dev "$IFACE" | awk '$3=="inet"{split($4,a,"/"); print a[1]}' | head -1)
      ;;
    amazon)
      PUB_IP=$(curl -sS --max-time 10 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
      ;;
    google)
      PUB_IP=$(curl -sS --max-time 10 -H "Metadata-Flavor: Google" \
        http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null || true)
      ;;
    linode)
      PUB_IP=$(curl -sS --max-time 10 http://169.254.100.100/latest/meta-data/public-ipv4 2>/dev/null || true)
      ;;
  esac
  if [ -z "$PUB_IP" ]; then
    PUB_IP=$(ip -4 -o addr show 2>/dev/null \
      | awk '$3=="inet"{split($4,a,"/"); print a[1]}' \
      | grep -Ev '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|169\.254\.)' | head -1)
  fi
  if [ -z "$PUB_IP" ]; then
    PUB_IP=$(ip -4 -o addr show dev "$IFACE" | awk '$3=="inet"{split($4,a,"/"); print a[1]}' | head -1)
  fi
  echo "server ip: $PUB_IP"
}

gen_identifier_15() {
  egrep '^.{1,7}$' "$WORDLIST" | $SHUF -n 2 | paste -s -d '-' -
}
gen_long_identifier() {
  $SHUF -n 3 "$WORDLIST" | paste -s -d '-' -
}
gen_gateway_password() {
  $SHUF -n 6 "$WORDLIST" | paste -s -d '.' -
}
gen_weak_password() {
  $SHUF -n 3 "$WORDLIST" | paste -s -d '.' -
}
gen_psk() {
  $SHUF -n 5 "$WORDLIST" | paste -s -d '.' -
}
gen_tor_nickname() {
  $SHUF -n 2 "$WORDLIST" |
    awk '{OFS=""; for(j=1;j<=NF;j++){ $j=toupper(substr($j,1,1)) substr($j,2) }}1' |
    tr -d '\n' | cut -b 1-18
}
is_true() { [ "${1:-}" = "true" ]; }
apt_wait() {
  local lock=/var/lib/dpkg/lock-frontend
  [ -e "$lock" ] || lock=/var/lib/dpkg/lock
  flock -w 300 "$lock" true 2>/dev/null || true
}
apt-get() { apt_wait; command apt-get "$@"; }


# Generate (once) and echo the file of N random client identifiers.
client_names_file=$STREISAND_BOOT/streisand-client-names
gen_client_names() {
  if [ ! -s "$client_names_file" ]; then
    for _ in $(seq 1 "$VPN_CLIENTS"); do
      gen_identifier_15
    done > "$client_names_file"
  fi
}
# ---------- certificates (openssl CA / server / client) ----------
TLS_SUBJECT="/C=US/ST=California/L=Beverly Hills/O=ACME CORPORATION/OU=Anvil Department"
TLS_DAYS=1825
TLS_KEY_SIZE=4096

# make_ca <ca_path> — CA key/cert + openssl.cnf + index/serial
make_ca() {
  local ca_path="$1"
  mkdir -p "$ca_path"
  chmod 700 "$ca_path"
  if [ ! -f "$ca_path/ca.key" ]; then
    openssl genrsa -out "$ca_path/ca.key" "$TLS_KEY_SIZE" || fail "ca keygen $ca_path"
  fi
  chmod 600 "$ca_path/ca.key"
  if [ ! -f "$ca_path/ca.crt" ]; then
    openssl req -nodes -batch -new -x509 \
      -key "$ca_path/ca.key" -days "$TLS_DAYS" -out "$ca_path/ca.crt" \
      -subj "$TLS_SUBJECT/CN=ca-certificate" || fail "ca cert $ca_path"
  fi
  cat > "$ca_path/openssl.cnf" <<CNF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir = $ca_path
certs = \$dir
crl_dir = \$dir
database = \$dir/index.txt
new_certs_dir = \$dir
certificate = $ca_path/ca.crt
serial = \$dir/serial
crl = \$dir/crl.pem
private_key = $ca_path/ca.key
RANDFILE = \$dir/.rand
copy_extensions = copy
x509_extensions = server
default_days = $TLS_DAYS
default_crl_days= 30
default_md = sha256
preserve = no
policy = policy_anything
keyUsage = cRLSign, keyCertSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always

[ policy_anything ]
countryName = optional
stateOrProvinceName = optional
localityName = optional
organizationName = optional
organizationalUnitName = optional
commonName = supplied
name = optional
emailAddress = optional

[ req ]
distinguished_name = req_distinguished_name
req_extensions     = req_ext

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
IP.1 = $PUB_IP

[ req_distinguished_name ]
countryName = Country Name (2 letter code)
stateOrProvinceName = State or Province Name (full name)
localityName = Locality Name (eg, city)
0.organizationName = Organization Name
organizationalUnitName = Organizational Unit Name
commonName = Common Name

[ v3_ca ]
keyUsage = digitalSignature, keyEncipherment

[ server ]
basicConstraints=CA:FALSE
nsComment = "Terraform Generated Server Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
extendedKeyUsage=serverAuth
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ client ]
basicConstraints=CA:FALSE
nsComment = "Terraform Generated Client Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
extendedKeyUsage=clientAuth
keyUsage = digitalSignature
CNF
  touch "$ca_path/index.txt"
  [ -f "$ca_path/serial" ] || echo "01" > "$ca_path/serial"
}

# make_server_cert <ca_path> — server.key/server.crt, writes .server_common_name
make_server_cert() {
  local ca_path="$1" cn_file cn
  cn_file="$ca_path/.server_common_name"
  if [ ! -s "$cn_file" ]; then
    ( umask 077; gen_long_identifier > "$cn_file" )
  fi
  cn=$(cat "$cn_file")
  if [ ! -f "$ca_path/server.key" ]; then
    ( cd "$ca_path" && openssl genrsa -out server.key "$TLS_KEY_SIZE" ) || fail "server keygen $ca_path"
  fi
  chmod 600 "$ca_path/server.key"
  if [ ! -f "$ca_path/server.crt" ]; then
    ( cd "$ca_path" \
      && openssl req -batch -extensions server -new -key server.key -out server.csr -config openssl.cnf -subj "$TLS_SUBJECT/CN=$cn" \
      && openssl ca -batch -extensions server -in server.csr -out server.crt -config openssl.cnf ) \
      || fail "server cert $ca_path"
  fi
}

# make_client_cert <client_dir> <ca_path> — client.key/client.crt
make_client_cert() {
  local cdir="$1" ca_path="$2" name
  name=$(basename "$cdir")
  mkdir -p "$cdir"; chmod 700 "$cdir"
  ( cd "$cdir" \
    && { [ -f client.key ] || openssl genrsa -out client.key "$TLS_KEY_SIZE"; } \
    && { [ -f client.csr ] || openssl req -new -extensions client -key client.key -out client.csr -subj "$TLS_SUBJECT/CN=$name" -config "$ca_path/openssl.cnf"; } \
    && { [ -f client.crt ] || openssl x509 -extensions client -CA "$ca_path/ca.crt" -CAkey "$ca_path/ca.key" -CAcreateserial -req -days "$TLS_DAYS" -in client.csr -out client.crt -extfile "$ca_path/openssl.cnf"; } ) \
    || fail "client cert $name in $ca_path"
  chmod 600 "$cdir/client.key"
}
# =====================================================================
# 1. common: packages, wordlist, client names, gateway dir
# =====================================================================
detect_iface
detect_public_ip

# Base packages installed by cloud-init; just wait for the lock.
apt_wait

# Purge unneeded services
apt-get purge -y lxd snapd 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

run apt-get upgrade -y

# BIP-39 wordlist
if [ -f "$WORDLIST_SRC" ] && [ ! -s "$WORDLIST" ]; then
  cp "$WORDLIST_SRC" "$WORDLIST"
  chmod 644 "$WORDLIST"
fi
[ -s "$WORDLIST" ] || fail "missing BIP-39 wordlist at $WORDLIST"

gen_client_names

# Gateway directory
mkdir -p "$GATEWAY" "$MIRROR"
chown www-data:www-data "$GATEWAY" "$MIRROR" 2>/dev/null || true
chmod 750 "$GATEWAY"

# unattended-upgrades config written by cloud-init

# ip forwarding
cat > /etc/sysctl.d/99-streisand-forward.conf <<'FWD'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
FWD
sysctl --system >/dev/null 2>&1 || true

# =====================================================================
# 2. ssh: hardened sshd + regenerated RSA host key
# =====================================================================
if [ ! -f /etc/ssh/ssh_host_rsa_key_was_regenerated ]; then
  rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
  ssh-keygen -h -t rsa -b 3072 -f /etc/ssh/ssh_host_rsa_key -N '' -q
  touch /etc/ssh/ssh_host_rsa_key_was_regenerated
  run systemctl restart ssh
fi
run ssh-keygen -A
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub > $STREISAND_BOOT/ssh-fingerprints.txt
ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub >> $STREISAND_BOOT/ssh-fingerprints.txt

# operator key into root's authorized_keys (idempotent)
if [ -s $STREISAND_BOOT/streisand_ssh_pubkey ] && command -v ssh-keygen >/dev/null; then
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  key=$(cat $STREISAND_BOOT/streisand_ssh_pubkey)
  grep -qxF "$key" /root/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /root/.ssh/authorized_keys
fi

# =====================================================================
# 3. service-net + dnsmasq
# =====================================================================
systemctl daemon-reload
systemctl enable systemd-networkd 2>/dev/null || true
systemctl restart systemd-networkd 2>/dev/null || true

if is_true "$ENABLE_CLOUDFLARED"; then
  apt-get install -y cloudflared 2>/dev/null || true
fi
# The systemd-resolved stub listener is disabled by the cloud-init bootstrap
# (resolved.conf.d drop-in + restart) before dnsmasq is even installed.

apt-get purge -y bind9 2>/dev/null || true

# /etc/dnsmasq.conf (base config) ships from the cloud-init bootstrap.
# Feature drop-ins under /etc/dnsmasq.d are written by their sections below,
# and the single restart after them loads everything.
# Documentation header/footer templates come from the bundle.
cp $STREISAND_BOOT/header.html /tmp/header.html 2>/dev/null || true
cp $STREISAND_BOOT/footer.html /tmp/footer.html 2>/dev/null || true
# =====================================================================
# 4. openvpn (+ stunnel)
# =====================================================================
if is_true "$ENABLE_OPENVPN"; then
  apt-get install -y openvpn udev

  OPENVPN_PATH=/etc/openvpn
  OPENVPN_TA=$OPENVPN_PATH/ta.key
  OPENVPN_GW=$GATEWAY/openvpn
  mkdir -p "$OPENVPN_GW"

  make_ca "$OPENVPN_PATH"
  make_server_cert "$OPENVPN_PATH"
  OPENVPN_SERVER_CN=$(cat "$OPENVPN_PATH/.server_common_name")
  OPENVPN_SERVER=$PUB_IP

  run openvpn --genkey --secret "$OPENVPN_TA" || true
  [ -f "$OPENVPN_TA" ] || ( umask 077; openvpn --genkey --secret "$OPENVPN_TA" )

  # dnsmasq listens for OpenVPN clients
  cat > /etc/dnsmasq.d/openvpn.conf <<'DN'
listen-address=10.8.0.1,10.9.0.1
DN

  # server config (tcp + udp)
  OPENVPN_SERVER_COMMON() { :; }
  write_openvpn_server_common() {
    cat <<COMMON
dev tun
ca ca.crt
cert server.crt
key server.key
dh none
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1"
push block-outside-dns
client-to-client
remote-cert-tls client
keepalive 1800 3600
tls-crypt ta.key
cipher $OPENVPN_CIPHER
ncp-ciphers $OPENVPN_NCP_CIPHERS
tls-cipher TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384
auth $OPENVPN_AUTH_DIGEST
tls-version-min 1.2
compress
user nobody
group nogroup
persist-key
persist-tun
verb 0
script-security 2
tls-verify "/usr/share/openvpn/verify-cn /etc/allowed_vpn_certs"
COMMON
  }
  {
    echo "server 10.8.0.0 255.255.255.0"
    echo "push \"dhcp-option DNS $DNSMASQ_OPENVPN_TCP_IP\""
    echo "proto tcp"
    echo "port $OPENVPN_PORT"
    write_openvpn_server_common
  } > "$OPENVPN_PATH/server.conf"
  {
    echo "server 10.9.0.0 255.255.255.0"
    echo "push \"dhcp-option DNS $DNSMASQ_OPENVPN_UDP_IP\""
    echo "proto udp"
    echo "port $OPENVPN_PORT_UDP"
    write_openvpn_server_common
  } > "$OPENVPN_PATH/server-udp.conf"

  # systemd unit for openvpn@ instances
  cat > /etc/systemd/system/openvpn@.service <<'UNIT'
[Unit]
Description=OpenVPN service for %I
After=syslog.target network-online.target
Wants=network-online.target
Documentation=man:openvpn(8)

[Service]
Type=notify
PrivateTmp=true
WorkingDirectory=/etc/openvpn
ExecStart=/usr/sbin/openvpn --config %i.conf
CapabilityBoundingSet=CAP_IPC_LOCK CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SETGID CAP_SETUID CAP_SYS_CHROOT CAP_DAC_OVERRIDE
LimitNPROC=30
DeviceAllow=/dev/null rw
DeviceAllow=/dev/net/tun rw
ProtectSystem=true
ProtectHome=true
KillMode=process
RestartSec=5s
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

  # one client directory + profiles per identifier
  : > /etc/allowed_vpn_certs
  chmod 644 /etc/allowed_vpn_certs
  while read -r cname; do
    cdir="$OPENVPN_PATH/$cname"
    make_client_cert "$cdir" "$OPENVPN_PATH"
    cp "$OPENVPN_PATH/ca.crt" "$OPENVPN_PATH/ta.key" "$cdir/"
    grep -qxF "$cname" /etc/allowed_vpn_certs 2>/dev/null || echo "$cname" >> /etc/allowed_vpn_certs
    gwdir="$OPENVPN_GW/$cname"
    mkdir -p "$gwdir"

    ca_c=$(cat "$OPENVPN_PATH/ca.crt")
    ta_c=$(cat "$OPENVPN_PATH/ta.key")
    cl_crt=$(cat "$cdir/client.crt")
    cl_key=$(cat "$cdir/client.key")

    client_common() {
      cat <<COMMON
dev tun
cipher $OPENVPN_CIPHER
auth $OPENVPN_AUTH_DIGEST
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $OPENVPN_SERVER_CN name
tls-version-min 1.2
compress
verb 3
route $PUB_IP 255.255.255.255 net_gateway
<ca>
$ca_c
</ca>
<cert>
$cl_crt
</cert>
<key>
$cl_key
</key>
<tls-crypt>
$ta_c
</tls-crypt>
COMMON
    }

    { echo "client"; echo "remote $OPENVPN_SERVER $OPENVPN_PORT"; echo "proto tcp"; client_common; } \
      > "$cdir/$OPENVPN_SERVER-direct.ovpn"
    { echo "client"; echo "remote $OPENVPN_SERVER $OPENVPN_PORT_UDP"; echo "proto udp"; client_common; } \
      > "$cdir/$OPENVPN_SERVER-direct-udp.ovpn"
    { echo "client"; echo "remote $OPENVPN_SERVER $OPENVPN_SSLH_PORT"; echo "proto tcp"; client_common; } \
      > "$cdir/$OPENVPN_SERVER-sslh.ovpn"

    if is_true "$ENABLE_STUNNEL"; then
      { echo "client"; echo "remote 127.0.0.1 $STUNNEL_LOCAL_PORT"; echo "proto tcp"; client_common; } \
        > "$cdir/$OPENVPN_SERVER-stunnel.ovpn"
      cp "$cdir/$OPENVPN_SERVER-stunnel.ovpn" "$gwdir/"
    fi

    # combined profile: direct tcp, then direct udp, then stunnel/sslh
    {
      echo "# Combined profile: tries the fastest options first."
      echo "<connection>"
      echo "client"
      echo "remote $OPENVPN_SERVER $OPENVPN_PORT"
      echo "proto tcp"
      echo "</connection>"
      echo "<connection>"
      echo "remote $OPENVPN_SERVER $OPENVPN_PORT_UDP"
      echo "proto udp"
      echo "</connection>"
      if is_true "$ENABLE_STUNNEL"; then
        echo "<connection>"
        echo "remote 127.0.0.1 $STUNNEL_LOCAL_PORT"
        echo "proto tcp"
        echo "</connection>"
      fi
      echo "<connection>"
      echo "remote $OPENVPN_SERVER $OPENVPN_SSLH_PORT"
      echo "proto tcp"
      echo "</connection>"
      client_common
    } > "$cdir/$OPENVPN_SERVER-combined.ovpn"

    for f in direct direct-udp sslh stunnel combined; do
      [ -f "$cdir/$OPENVPN_SERVER-$f.ovpn" ] && cp "$cdir/$OPENVPN_SERVER-$f.ovpn" "$gwdir/"
    done
    cp "$OPENVPN_PATH/ca.crt" "$OPENVPN_PATH/ta.key" "$gwdir/" 2>/dev/null || true
  done < "$client_names_file"


  systemctl disable --now openvpn.service 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable --now openvpn@server openvpn@server-udp 2>/dev/null || \
    echo "WARN: openvpn services failed to start" >&2

  # gateway docs
  {
    echo "# OpenVPN"
    echo
    echo "Connect using the .ovpn profiles in this directory."
    echo "Recommended: <client>-$OPENVPN_SERVER-combined.ovpn (tries the fastest options first)."
    for f in "$OPENVPN_GW"/*.ovpn; do [ -f "$f" ] && echo "- $f"; done
  } > "$OPENVPN_GW/index.md"
fi

# =====================================================================
# 5. stunnel
# =====================================================================
if is_true "$ENABLE_OPENVPN" && is_true "$ENABLE_STUNNEL"; then
  apt-get install -y stunnel4
  STUNNEL_PATH=/etc/stunnel
  mkdir -p "$STUNNEL_PATH"
  [ -f "$STUNNEL_PATH/stunnel.key" ] || openssl genrsa -out "$STUNNEL_PATH/stunnel.key" 3072
  [ -f "$STUNNEL_PATH/stunnel.crt" ] || openssl req -new -nodes -x509 \
    -key "$STUNNEL_PATH/stunnel.key" -days 1825 \
    -subj "/C=GB/ST=Berkshire/L=Slough/O=Wernham Hogg Paper Company/OU=Gareth Keenan Investigations/CN=stunnel" \
    > "$STUNNEL_PATH/stunnel.crt"
  chmod 600 "$STUNNEL_PATH/stunnel.key"

  cat > "$STUNNEL_PATH/stunnel.conf" <<STN
cert = $STUNNEL_PATH/stunnel.crt
key = $STUNNEL_PATH/stunnel.key
debug = 4
sslVersionMin = TLSv1.2
ciphers = $TLS_CIPHERS

[stunnel]
accept = $STUNNEL_REMOTE_PORT
connect = 127.0.0.1:$OPENVPN_PORT
STN
  # client-side config for download via the gateway
  cat > "$OPENVPN_GW/stunnel.conf" <<STN
client = yes

[stunnel]
accept = 127.0.0.1:$STUNNEL_LOCAL_PORT
connect = $PUB_IP:$STUNNEL_REMOTE_PORT
STN

  systemctl disable --now stunnel4 2>/dev/null || true
  cat > /etc/systemd/system/stunnel.service <<'UNIT'
[Unit]
Description=stunnel VPN wrapper for OpenVPN
After=network-online.target

[Service]
ExecStart=/usr/bin/stunnel4 /etc/stunnel/stunnel.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now stunnel 2>/dev/null || echo "WARN: stunnel failed to start" >&2
fi
# =====================================================================
# 6. wireguard
# =====================================================================
if is_true "$ENABLE_WIREGUARD"; then
  apt-get install -y wireguard wireguard-tools

  WG_PATH=/etc/wireguard
  WG_CLIENT_PATH=$WG_PATH/clients
  mkdir -p "$WG_CLIENT_PATH"
  chmod 600 "$WG_CLIENT_PATH"

  if [ ! -f "$WG_PATH/server.pub" ]; then
    ( umask 077; wg genkey | tee "$WG_PATH/server.key" | wg pubkey > "$WG_PATH/server.pub" )
  fi
  WG_SERVER_PRIV=$(cat "$WG_PATH/server.key")
  WG_SERVER_PUB=$(cat "$WG_PATH/server.pub")

  # server config: rebuild peers from client names each run
  {
    echo "[Interface]"
    echo "Address = 10.192.122.1/24"
    echo "SaveConfig = true"
    echo "ListenPort = $WIREGUARD_PORT"
    echo "PrivateKey = $WG_SERVER_PRIV"
    n=1
    while read -r cname; do
      cdir="$WG_CLIENT_PATH/$cname"
      mkdir -p "$cdir"; chmod 600 "$cdir"
      if [ ! -f "$cdir/client.key" ]; then
        ( cd "$cdir" && umask 077 && wg genkey | tee client.key | wg pubkey > client.pub )
      fi
      cpriv=$(cat "$cdir/client.key")
      cpub=$(cat "$cdir/client.pub")
      echo ""
      echo "# \"$cname\" Client Peer"
      echo "[Peer]"
      echo "PublicKey = $cpub"
      echo "AllowedIPs = 10.192.122.$((n+1))/32"
      n=$((n+1))
    done < "$client_names_file"
  } > "$WG_PATH/wg0.conf"
  chmod 600 "$WG_PATH/wg0.conf"

  touch "$WG_PATH/.reload-module-on-update"

  # client configs + gateway copies
  n=1
  while read -r cname; do
    cdir="$WG_CLIENT_PATH/$cname"
    cpriv=$(cat "$cdir/client.key")
    gwdir="$GATEWAY/wireguard/$cname"
    mkdir -p "$gwdir"
    {
      echo "# \"$cname\" - Streisand WireGuard Client Profile"
      echo "[Interface]"
      echo "Address = 10.192.122.$((n+1))/32"
      echo "DNS = $DNSMASQ_WIREGUARD_IP"
      echo "PrivateKey = $cpriv"
      echo ""
      echo "[Peer]"
      echo "PublicKey = $WG_SERVER_PUB"
      echo "AllowedIPs = 0.0.0.0/0,::/0"
      echo "Endpoint = $PUB_IP:$WIREGUARD_PORT"
    } > "$cdir/client.conf"
    cp "$cdir/client.conf" "$gwdir/client.conf"
    qrencode -o "$gwdir/client-qr.png" < "$cdir/client.conf" 2>/dev/null || true
    n=$((n+1))
  done < "$client_names_file"

  cat > /etc/dnsmasq.d/wireguard.conf <<DN
listen-address=$DNSMASQ_WIREGUARD_IP
DN

  systemctl daemon-reload
  systemctl enable --now wg-quick@wg0 2>/dev/null || echo "WARN: wg-quick failed to start" >&2

  {
    echo "# WireGuard"
    echo
    echo "Import one of the client.conf profiles into a WireGuard client."
    echo "Mobile users: scan the client-qr.png images."
  } > "$GATEWAY/wireguard/index.md"
fi

# =====================================================================
# 7. shadowsocks
# =====================================================================
if is_true "$ENABLE_SHADOWSOCKS"; then
  sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
  apt-get install -y shadowsocks-libev

  SS_PATH=/etc/shadowsocks-libev
  mkdir -p "$SS_PATH"
  chown root:nogroup "$SS_PATH" 2>/dev/null || true
  chmod 755 "$SS_PATH"

  if [ ! -f "$SS_PATH/shadowsocks-password.txt" ]; then
    openssl rand -base64 48 > "$SS_PATH/shadowsocks-password.txt"
  fi
  chmod 600 "$SS_PATH/shadowsocks-password.txt"
  SS_PASS=$(cat "$SS_PATH/shadowsocks-password.txt")

  V2RAY_PLUGIN=""
  if is_true "$ENABLE_V2RAY"; then
    V2RAY_ARCH=amd64
    case $(uname -m) in
      aarch64) V2RAY_ARCH=arm64 ;;
      armv7l)  V2RAY_ARCH=386 ;;
    esac
    V2RAY_URL="https://github.com/shadowsocks/v2ray-plugin/releases/download/v1.4.0/v2ray-plugin-linux-$V2RAY_ARCH-v1.4.0.tar.gz"
    if [ ! -f "$SS_PATH/v2ray-plugin" ]; then
      curl -fsSL "$V2RAY_URL" -o /tmp/v2ray.tar.gz \
        && tar -xzf /tmp/v2ray.tar.gz -C /tmp \
        && mv "/tmp/v2ray-plugin-linux-$V2RAY_ARCH-v1.4.0" "$SS_PATH/v2ray-plugin" \
        && chmod 755 "$SS_PATH/v2ray-plugin" \
        || echo "WARN: v2ray-plugin download failed" >&2
    fi
    V2RAY_PLUGIN=",
    \"plugin\":\"$SS_PATH/v2ray-plugin\",
    \"plugin_opts\":\"server;host=github.com\""
  fi

  cat > /etc/default/shadowsocks-libev <<DEF
CONFFILE="$SS_PATH/config.json"
DAEMON_ARGS="-u"
DEF

  SS_LISTEN_IP=$(ip -4 -o addr show dev "$IFACE" | awk '$3=="inet"{split($4,a,"/"); print a[1]}' | head -1)
  cat > "$SS_PATH/config.json" <<JSON
{
    "server":"$SS_LISTEN_IP",
    "server_port":$SHADOWSOCKS_PORT,
    "local_port":1080,
    "password":"$SS_PASS",
    "timeout":600,
    "method":"$SHADOWSOCKS_METHOD",
    "fast_open":true$V2RAY_PLUGIN
}
JSON
  # noble's unit runs DynamicUser=true: the transient uid needs a
  # supplementary group to read the root-owned config.json, or ss-server
  # exits with "Invalid config path" and restarts forever.
  getent group shadowsocks >/dev/null || groupadd -r shadowsocks
  chown root:shadowsocks "$SS_PATH/config.json"
  chmod 640 "$SS_PATH/config.json"

  mkdir -p /etc/systemd/system/shadowsocks-libev.service.d
  cat > /etc/systemd/system/shadowsocks-libev.service.d/10-restart-failure.conf <<'UNIT'
[Service]
Restart=on-failure
RestartSec=5s
SupplementaryGroups=shadowsocks
UNIT

  systemctl daemon-reload
  systemctl enable --now shadowsocks-libev 2>/dev/null || echo "WARN: shadowsocks-libev failed to start" >&2

  SS_GW=$GATEWAY/shadowsocks
  mkdir -p "$SS_GW"
  {
    echo "# Shadowsocks"
    echo
    echo "- Server: $PUB_IP:$SHADOWSOCKS_PORT"
    echo "- Method: $SHADOWSOCKS_METHOD"
    echo "- Password: $SS_PASS"
  } > "$SS_GW/index.md"
  echo "$SS_PASS" > "$SS_GW/shadowsocks-password.txt"
  chmod 640 "$SS_GW/shadowsocks-password.txt"
fi
# =====================================================================
# 8. openconnect (ocserv)
# =====================================================================
if is_true "$ENABLE_OPENCONNECT"; then
  # ocserv lives in universe; enable it first
  add-apt-repository -y universe 2>/dev/null || true
  apt-get update -y
  apt-get install -y ocserv uuid-runtime

  OC_PATH=/etc/ocserv
  OC_GW=$GATEWAY/openconnect
  mkdir -p "$OC_PATH" "$OC_GW"

  cp $STREISAND_BOOT/ocserv-pam /etc/pam.d/ocserv 2>/dev/null || true
  chmod 644 /etc/pam.d/ocserv 2>/dev/null || true

  make_ca "$OC_PATH"
  make_server_cert "$OC_PATH"

  # client certs + PKCS12
  while read -r cname; do
    cdir="$OC_PATH/$cname"
    make_client_cert "$cdir" "$OC_PATH"
    if [ ! -f "$cdir/$cname.p12" ]; then
      pw_file="$cdir/ocserv-$cname-pkcs12-password"
      [ -s "$pw_file" ] || { ( umask 077; gen_weak_password > "$pw_file" ); }
      pw=$(cat "$pw_file")
      ( cd "$cdir" && openssl pkcs12 -export \
          -in client.crt -inkey client.key -name "$cname" \
          -out "$cname.p12" -certfile "$OC_PATH/ca.crt" \
          -passout pass:"$pw" ) || fail "pkcs12 $cname"
    fi
    mkdir -p "$OC_GW/$cname"
    cp "$cdir/$cname.p12" "$OC_GW/$cname/"
    cp "$cdir/ocserv-$cname-pkcs12-password" "$OC_GW/$cname/"
    # Android / generic: .pcf is not standard; distribute p12 + password
  done < "$client_names_file"

  # server password
  if [ ! -s "$OC_PATH/ocserv-password" ]; then
    ( umask 077; gen_psk > "$OC_PATH/ocserv-password" )
  fi
  OC_PASS=$(cat "$OC_PATH/ocserv-password")
  if [ ! -f "$OC_PATH/ocpasswd" ]; then
    printf '%s\n%s\n' "$OC_PASS" "$OC_PASS" | ocpasswd -c "$OC_PATH/ocpasswd" streisand
  fi

  cat > "$OC_PATH/ocserv.conf" <<OCS
auth = "plain[passwd=$OC_PATH/ocpasswd]"
tcp-port = $OCSERV_PORT
udp-port = $OCSERV_PORT
run-as-user = nobody
run-as-group = nogroup
socket-file = /var/run/ocserv-socket
server-cert = $OC_PATH/server.crt
server-key = $OC_PATH/server.key
ca-cert = $OC_PATH/ca.crt
isolate-workers = true
persistent-cookies = true
keepalive = 32400
dpd = 240
mobile-dpd = 1800
try-mtu-discovery = true
cert-user-oid = 2.5.4.3
cert-group-oid = 2.5.4.11
tls-priorities = "SECURE192:%SERVER_PRECEDENCE:%LATEST_RECORD_VERSION:-VERS-ALL:+VERS-TLS1.2:+VERS-DTLS1.2"
auth-timeout = 40
min-reauth-time = 300
max-ban-score = 50
ban-reset-time = 300
cookie-timeout = 300
cookie-rekey-time = 14400
deny-roaming = false
rekey-time = 3600
rekey-method = ssl
use-occtl = true
pid-file = /var/run/ocserv.pid
device = vpns
default-domain = example.com
ipv4-network = $OCSERV_NET
ipv4-netmask = 255.255.255.0
ping-leases = false
cisco-client-compat = true
max-clients = $((VPN_CLIENTS + 1))
max-same-clients = 1
tunnel-all-dns = true
$(for s in $UPSTREAM_DNS; do echo "dns = $s"; done)
OCS

  cat > /etc/systemd/system/ocserv.service <<UNIT
[Unit]
Description=OpenConnect SSL VPN server
Documentation=man:ocserv(8)
After=network-online.target

[Service]
PrivateTmp=true
PIDFile=/var/run/ocserv.pid
ExecStart=/usr/sbin/ocserv --foreground --pid-file /var/run/ocserv.pid --config $OC_PATH/ocserv.conf
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
UNIT

  systemctl disable --now ocserv.socket 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable --now ocserv 2>/dev/null || echo "WARN: ocserv failed to start" >&2

  # NAT + DNS from ocserv clients
  cat > /etc/systemd/system/ocserv-iptables.service <<UNIT
[Unit]
Description=ocserv iptables rules
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables --wait $IPT_WAIT -t nat -A POSTROUTING -j MASQUERADE; iptables --wait $IPT_WAIT -A FORWARD -s $OCSERV_NET/24 -j ACCEPT'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now ocserv-iptables 2>/dev/null || true

  {
    echo "# OpenConnect"
    echo
    echo "Server: https://$PUB_IP:$OCSERV_PORT (Cisco AnyConnect / openconnect)"
    echo
    echo "Plain username/password auth:"
    echo "- username: streisand"
    echo "- password: $OC_PASS"
    echo
    echo "Per-client .p12 certificates are in subdirectories; the matching"
    echo "PKCS12 password is in the same directory."
  } > "$OC_GW/index.md"
  echo "$OC_PASS" > "$OC_GW/ocserv-password.txt"
  chmod 640 "$OC_GW/ocserv-password.txt"
fi

# =====================================================================
# 9. tor-bridge
# =====================================================================
if is_true "$ENABLE_TOR"; then
  apt-get install -y obfs4proxy tor

  TOR_STATE=/var/lib/tor
  TOR_PT_STATE=$TOR_STATE/pt_state
  TOR_HS_DIR=$TOR_STATE/hidden_service
  TOR_GW=$GATEWAY/tor

  if [ ! -s /etc/tor/bridge_nickname ]; then
    mkdir -p /etc/tor
    gen_tor_nickname > /etc/tor/bridge_nickname
  fi
  TOR_NICK=$(cat /etc/tor/bridge_nickname)

  cat > /etc/tor/torrc <<TORRC
SocksPort 0
ORPort $TOR_ORPORT
ExtORPort auto
BridgeRelay 1
PublishServerDescriptor 0
ExitPolicy reject *:*

Nickname $TOR_NICK

ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ServerTransportListenAddr obfs4 0.0.0.0:$TOR_OBFS4_PORT

HiddenServiceDir $TOR_HS_DIR
HiddenServicePort 80 127.0.0.1:8181
TORRC

  # apparmor local override for tor and obfs4proxy
  if [ -d /etc/apparmor.d ]; then
    cp $STREISAND_BOOT/apparmor-local-override /etc/apparmor.d/local/system_tor 2>/dev/null || true
    sed -i -E 's#^(\s*)/usr/bin/(obfs4?proxy) PUx,$#\1/usr/bin/\2 ix,#' \
      /etc/apparmor.d/abstractions/tor 2>/dev/null || true
    apparmor_parser -r /etc/apparmor.d/system_tor 2>/dev/null || true
  fi

  systemctl restart tor 2>/dev/null || echo "WARN: tor restart failed" >&2
  # wait for state files (up to 3 min)
  for _ in $(seq 1 36); do
    [ -f "$TOR_PT_STATE/obfs4_state.json" ] && [ -f "$TOR_HS_DIR/hostname" ] && \
      [ -f "$TOR_STATE/fingerprint" ] && break
    sleep 5
  done

  TOR_HS_HOSTNAME=$(cat "$TOR_HS_DIR/hostname" 2>/dev/null || echo "unavailable")
  TOR_FINGERPRINT=$(awk '{ print $2 }' "$TOR_STATE/fingerprint" 2>/dev/null || echo "unavailable")
  TOR_CERT=$(grep 'Bridge obfs4' "$TOR_PT_STATE/obfs4_bridgeline.txt" 2>/dev/null | sed -e 's/^.*cert=\(.*\) .*$/\1/' || echo "unavailable")

  mkdir -p "$TOR_GW"
  {
    echo "# Tor Bridge"
    echo
    echo "obfs4 bridge line:"
    echo "    obfs4 $PUB_IP:$TOR_OBFS4_PORT $TOR_FINGERPRINT cert=$TOR_CERT iat-mode=0"
    echo
    echo "Hidden service for this gateway: http://$TOR_HS_HOSTNAME"
  } > "$TOR_GW/index.md"
  echo "$TOR_HS_HOSTNAME" > "$TOR_GW/hidden-service-hostname.txt"
  echo "obfs4 $PUB_IP:$TOR_OBFS4_PORT $TOR_FINGERPRINT cert=$TOR_CERT iat-mode=0" > "$TOR_GW/bridgeline.txt"
  qrencode -o "$TOR_GW/tor-obfs4-qr-code.png" < "$TOR_GW/bridgeline.txt" 2>/dev/null || true

  # nginx vhost for the hidden service (proxies HS port 80 -> localhost:8181)
  cat > /etc/nginx/sites-available/streisand-hidden-service <<VH
server {
  listen 127.0.0.1:8181;
  root $GATEWAY;
  index index.html index.htm;
  auth_basic "Authorization Required";
  auth_basic_user_file $HTPASSWD_FILE;
}
VH
  ln -sf /etc/nginx/sites-available/streisand-hidden-service /etc/nginx/sites-enabled/streisand-hidden-service
fi
# =====================================================================
# 10. ssh-forward (forward user + optional sshuttle user)
# =====================================================================
if is_true "$ENABLE_SSH_FORWARD"; then
  SSH_FWD_GW=$GATEWAY/ssh
  mkdir -p "$SSH_FWD_GW"

  # 'forward' account: key-only, forced command, port-forwarding only.
  # The forward user's keypair is generated on the server; the private key
  # is published in the gateway so VPN users (who never see the server's
  # host keys or root key) can connect with it.
  if [ ! -f /home/forward/.ssh/id_rsa ]; then
    id forward >/dev/null 2>&1 || useradd -m -d /home/forward -s /bin/bash -c "SSH Forwarding User" forward
    mkdir -p /home/forward/.ssh
    ssh-keygen -h -t rsa -b 3072 -C streisand -f /home/forward/.ssh/id_rsa -N '' -q
    chown -R forward:forward /home/forward/.ssh
  fi
  FWD_KEY=$(cat /home/forward/.ssh/id_rsa.pub 2>/dev/null || echo "")
  if [ -n "$FWD_KEY" ]; then
    FCMD="command=\"echo 'This account is for port forwarding only.'\",no-agent-forwarding,no-X11-forwarding,no-pty $FWD_KEY"
    grep -qF "$FWD_KEY" /home/forward/.ssh/authorized_keys 2>/dev/null || \
      echo "$FCMD" > /home/forward/.ssh/authorized_keys
    chown -R forward:forward /home/forward/.ssh
    chmod 700 /home/forward/.ssh; chmod 600 /home/forward/.ssh/authorized_keys
  fi
  # publish the forward key for gateway download
  cp /home/forward/.ssh/id_rsa "$SSH_FWD_GW/streisand_rsa" 2>/dev/null || true
  chmod 640 "$SSH_FWD_GW/streisand_rsa" 2>/dev/null || true
  if command -v puttygen >/dev/null 2>&1; then
    puttygen /home/forward/.ssh/id_rsa -o "$SSH_FWD_GW/streisand_rsa.ppk" 2>/dev/null || true
  fi

  if is_true "$ENABLE_SSHUTTLE"; then
    if [ ! -f /home/sshuttle/.ssh/id_rsa ]; then
      id sshuttle >/dev/null 2>&1 || useradd -m -d /home/sshuttle -s /bin/bash -c "sshuttle User" sshuttle
      mkdir -p /home/sshuttle/.ssh
      ssh-keygen -h -t rsa -b 3072 -C streisand-sshuttle -f /home/sshuttle/.ssh/id_rsa -N '' -q
      # sshuttle user: full shell (documented deviation risk in original README)
      cat /home/sshuttle/.ssh/id_rsa.pub > /home/sshuttle/.ssh/authorized_keys
      chown -R sshuttle:sshuttle /home/sshuttle/.ssh
      chmod 700 /home/sshuttle/.ssh; chmod 600 /home/sshuttle/.ssh/authorized_keys
      cp /home/sshuttle/.ssh/id_rsa "$SSH_FWD_GW/streisand_sshuttle_rsa" 2>/dev/null || true
      chmod 640 "$SSH_FWD_GW/streisand_sshuttle_rsa" 2>/dev/null || true
    fi
  fi

  {
    echo "# SSH Forwarding"
    echo
    echo "Use the provided streisand_rsa key:"
    echo "    ssh -N -D 8080 -p $SSH_PORT -i streisand_rsa forward@$PUB_IP"
    echo "Then set your SOCKS proxy to 127.0.0.1:8080."
    if is_true "$ENABLE_SSHUTTLE"; then
      echo "sshuttle: sshuttle -r sshuttle@$PUB_IP:22 --ssh-cmd 'ssh -i streisand_sshuttle_rsa' 0/0"
    fi
  } > "$SSH_FWD_GW/index.md"
  ssh-keyscan -p "$SSH_PORT" "$PUB_IP" > "$SSH_FWD_GW/streisand.known_hosts" 2>/dev/null || true
fi

# =====================================================================
# 11. tinyproxy
# =====================================================================
if is_true "$ENABLE_TINYPROXY"; then
  apt-get install -y tinyproxy
  systemctl stop tinyproxy 2>/dev/null || true
  mkdir -p /var/log/tinyproxy /var/run/tinyproxy /etc/tinyproxy
  chown tinyproxy:tinyproxy /var/log/tinyproxy /var/run/tinyproxy 2>/dev/null || true

  MAX_CLIENTS=$((VPN_CLIENTS * 4)); [ "$MAX_CLIENTS" -gt 50 ] && MAX_CLIENTS=50
  cat > /etc/tinyproxy/tinyproxy.conf <<TP
User nobody
Group nogroup
Port $TINYPROXY_PORT
Listen $TINYPROXY_LISTEN
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
Logfile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Critical
PidFile "/var/run/tinyproxy/tinyproxy.pid"
MaxClients $MAX_CLIENTS
Allow $TINYPROXY_LISTEN
Allow $PUB_IP
ViaProxyName "tinyproxy"
ConnectPort 443
ConnectPort 563
TP
  rm -f /etc/tinyproxy.conf

  cat > /etc/systemd/system/tinyproxy.service <<UNIT
[Unit]
Description=tinyproxy HTTP proxy
After=network.target

[Service]
# /usr/bin/env resolves the binary: Ubuntu 22.04 ships it in /usr/sbin,
# 24.04 in /usr/bin; a hardcoded path exits 203/EXEC on the other release.
ExecStart=/usr/bin/env tinyproxy -c /etc/tinyproxy/tinyproxy.conf -d
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/tmpfiles.d/tinyproxy.conf <<'TF'
d /var/run/tinyproxy 0755 tinyproxy tinyproxy -
TF
  systemctl daemon-reload
  systemctl enable --now tinyproxy 2>/dev/null || echo "WARN: tinyproxy failed to start" >&2
fi

# =====================================================================
# 12. sslh (port 443 multiplexer; installed by cloud-init)
# =====================================================================
cat > /etc/default/sslh <<'D'
RUN=yes
DAEMON=/usr/sbin/sslh
DAEMON_OPTS="--config /etc/sslh.cfg"
D
OPENVPN_SSLH_LINE=""
if is_true "$ENABLE_OPENVPN"; then
  OPENVPN_SSLH_LINE="    { name: \"openvpn\"; host: \"127.0.0.1\"; port: \"$OPENVPN_PORT\"; probe: \"builtin\"; },"
fi
SSLH_BIND=$(ip -4 -o addr show dev "$IFACE" | awk '$3=="inet"{split($4,a,"/"); print a[1]}' | head -1)
cat > /etc/sslh.cfg <<CFG
verbose: false;
foreground: true;
fork: false;
# /run/sslh (not /run/sslh.pid): the Ubuntu unit runs DynamicUser=true with
# ProtectSystem=strict, so the daemon can only write under its RuntimeDirectory.
pidfile: "/run/sslh/sslh.pid";

listen:
(
    { host: "$SSLH_BIND"; port: "443"; }
);

protocols:
(
     { name: "ssh";     host: "127.0.0.1"; port: "$SSH_PORT"; probe: "builtin"; },
     { name: "tls";     host: "127.0.0.1"; port: "$NGINX_PORT"; probe: "builtin"; },
$OPENVPN_SSLH_LINE
     { name: "anyprot"; host: "127.0.0.1"; port: "$NGINX_PORT"; probe: "builtin"; }
);

on-timeout: "tls";
CFG
# nginx must NOT bind 0.0.0.0:443 when sslh owns the public 443.
mkdir -p /etc/systemd/system/sslh.service.d
cat > /etc/systemd/system/sslh.service.d/10-restart-failure.conf <<'UNIT'
[Service]
Restart=on-failure
RestartSec=5s
RuntimeDirectory=sslh
UNIT
systemctl daemon-reload
systemctl enable --now sslh 2>/dev/null || echo "WARN: sslh failed to start" >&2
# =====================================================================
# 13. ufw (host firewall)
# =====================================================================
ufw --force reset >/dev/null 2>&1 || true
sed -i 's/^LOGLEVEL=.*/LOGLEVEL=off/' /etc/ufw/ufw.conf 2>/dev/null || true
sed -i 's|^DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|' /etc/default/ufw 2>/dev/null || true

ufw allow "$SSH_PORT"/tcp comment 'SSH' || true
ufw allow "$NGINX_PORT"/tcp comment 'nginx gateway' || true
is_true "$ENABLE_SHADOWSOCKS"  && ufw allow from any to any port "$SHADOWSOCKS_PORT" comment 'shadowsocks' || true
if is_true "$ENABLE_WIREGUARD"; then
  ufw allow from 10.192.122.0/24 to any port 53 proto udp comment 'wg-dns' || true
  ufw allow "$WIREGUARD_PORT"/udp comment 'wireguard' || true
fi
if is_true "$ENABLE_OPENCONNECT"; then
  ufw allow from $OCSERV_NET/24 to any port 53 proto udp comment 'ocserv-dns' || true
  ufw allow from any to any port "$OCSERV_PORT" comment 'ocserv' || true
fi
is_true "$ENABLE_STUNNEL" && is_true "$ENABLE_OPENVPN" \
  && ufw allow "$STUNNEL_REMOTE_PORT"/tcp comment 'stunnel' || true
if is_true "$ENABLE_TOR"; then
  ufw allow "$TOR_ORPORT"/tcp comment 'tor orport' || true
  ufw allow "$TOR_OBFS4_PORT"/tcp comment 'tor obfs4' || true
fi
if is_true "$ENABLE_CLOUDFLARED"; then
  ufw allow from any to any port "$CLOUDFLARED_PORT" comment 'cloudflared' || true
fi
ufw --force enable || fail "ufw enable"

# =====================================================================
# 14. ad-blocking
# =====================================================================
if is_true "$ENABLE_AD_BLOCKING"; then
  # ad-block tooling ships in the uploaded bundle (cloud-init no longer ships it)
  cp $STREISAND_BOOT/adblocking/download-blocklists /usr/local/bin/
  cp $STREISAND_BOOT/adblocking/transform-domain-list /usr/local/bin/
  cp $STREISAND_BOOT/adblocking/transform-host-list /usr/local/bin/
  cp $STREISAND_BOOT/adblocking/download-blocklists.service /etc/systemd/system/
  cp $STREISAND_BOOT/adblocking/download-blocklists.timer /etc/systemd/system/
  chmod 755 /usr/local/bin/download-blocklists /usr/local/bin/transform-domain-list /usr/local/bin/transform-host-list
  systemctl daemon-reload
  systemctl enable --now download-blocklists.timer 2>/dev/null || true
  systemctl start download-blocklists.service 2>/dev/null || true
fi

# =====================================================================
# 15. cloudflared (DNS-over-HTTPS upstream for dnsmasq)
# =====================================================================
if is_true "$ENABLE_CLOUDFLARED"; then
  apt-get install -y cloudflared 2>/dev/null || \
    echo "WARN: cloudflared package unavailable" >&2
  if [ -x /usr/local/bin/cloudflared ] || command -v cloudflared >/dev/null 2>&1; then
    id cloudflared >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin cloudflared
    CF_BIN=$(command -v cloudflared || echo /usr/local/bin/cloudflared)
    chown cloudflared:cloudflared "$CF_BIN" 2>/dev/null || true
    [ "$CLOUDFLARED_PORT" -lt 1024 ] && setcap cap_net_bind_service=ep "$CF_BIN" 2>/dev/null || true
    cat > /etc/default/cloudflared <<CF
COMMAND_ARGS="--address=127.0.0.1 --port=$CLOUDFLARED_PORT --proxy-dns --upstream-url=https://cloudflare-dns.com/dns-query"
CF
    chown cloudflared:cloudflared /etc/default/cloudflared 2>/dev/null || true
    cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=cloudflared DNS-over-HTTPS proxy
After=network-online.target

[Service]
User=cloudflared
EnvironmentFile=/etc/default/cloudflared
ExecStart=$CF_BIN \$COMMAND_ARGS
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now cloudflared 2>/dev/null || echo "WARN: cloudflared failed to start" >&2
    sed -i '/^server=/d' /etc/dnsmasq.conf 2>/dev/null || true
    echo "server=127.0.0.1#$CLOUDFLARED_PORT" >> /etc/dnsmasq.conf
  fi
fi

# restart (not enable --now): cloud-init's postinst may have left dnsmasq
# running with the stock config; the overwritten /etc/dnsmasq.conf must load.
systemctl enable dnsmasq 2>/dev/null || true
systemctl restart dnsmasq 2>/dev/null || echo "WARN: dnsmasq failed to start" >&2

# =====================================================================
# 16. lets-encrypt + gateway certs
# =====================================================================
LE_OK=false
if is_true "$ENABLE_LE" && [ -n "$DOMAIN" ]; then
  apt-get install -y certbot 2>/dev/null || true
  EMAIL_FLAG="--register-unsafely-without-email"
  [ -n "$ADMIN_EMAIL" ] && EMAIL_FLAG="--email $ADMIN_EMAIL"
  mkdir -p /var/www/html
  systemctl stop nginx 2>/dev/null || true
  if certbot certonly --standalone -d "$DOMAIN" \
       $EMAIL_FLAG --agree-tos --non-interactive \
       --rsa-key-size 4096 \
       --server https://acme-v02.api.letsencrypt.org/directory; then
    LE_OK=true
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl reload nginx\n' \
      > /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
    chmod 750 /etc/letsencrypt/renewal-hooks/deploy/01-reload-nginx.sh
    # switch renewal to webroot
    CONF=/etc/letsencrypt/renewal/$DOMAIN.conf
    [ -f "$CONF" ] && {
      sed -i 's/^authenticator = .*/authenticator = webroot/' "$CONF"
      grep -q '^webroot_path' "$CONF" || echo 'webroot_path = /var/www/html,' >> "$CONF"
    }
  else
    echo "WARN: Let's Encrypt issuance failed; falling back to self-signed" >&2
  fi
fi

# self-signed gateway cert
if [ "$LE_OK" != "true" ]; then
  if [ ! -f /etc/ssl/certs/$SERVER_NAME.crt ]; then
    openssl genrsa -out /etc/ssl/private/$SERVER_NAME.key 3072
    openssl req -new -x509 -days 1825 -key /etc/ssl/private/$SERVER_NAME.key \
      -out /etc/ssl/certs/$SERVER_NAME.crt \
      -subj "/C=US/ST=California/L=Malibu/O=Streisand/OU=Streisand Effect Department/CN=$PUB_IP"
  fi
fi

# =====================================================================
# 17. streisand-gateway (htpasswd, vhost, docs)
# =====================================================================
# nginx.conf is shipped in the uploaded bundle (cloud-init no longer ships it)
cp $STREISAND_BOOT/nginx.conf /etc/nginx/nginx.conf

if [ ! -s "$GATEWAY_PASS_FILE" ]; then
  ( umask 077; gen_gateway_password > "$GATEWAY_PASS_FILE" )
fi
chmod 600 "$GATEWAY_PASS_FILE"
GW_PASS=$(cat "$GATEWAY_PASS_FILE")
[ -f "$HTPASSWD_FILE" ] || htpasswd -b -c "$HTPASSWD_FILE" streisand "$GW_PASS"
# nginx workers run as www-data and must read the auth file: group-own it.
chown root:www-data "$HTPASSWD_FILE"
chmod 640 "$HTPASSWD_FILE"

if [ "$LE_OK" = "true" ]; then
  SSL_BLOCK="  ssl_certificate         /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key     /etc/letsencrypt/live/$DOMAIN/privkey.pem;
  ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
  ssl_stapling on;
  ssl_stapling_verify on;
  resolver ${UPSTREAM_DNS// / } valid=300s;
  resolver_timeout 5s;
  add_header Strict-Transport-Security max-age=63072000;"
  SERVER_NAME_LINE="  server_name $DOMAIN;"
  ACME_BLOCK="  location /.well-known/acme-challenge/ {
    root /var/www/html;
    allow all;
  }"
else
  SSL_BLOCK="  ssl_certificate      /etc/ssl/certs/$SERVER_NAME.crt;
  ssl_certificate_key  /etc/ssl/private/$SERVER_NAME.key;"
  SERVER_NAME_LINE="  server_name $PUB_IP;"
  ACME_BLOCK=""
fi

cat > /etc/nginx/sites-available/streisand <<VHOST
# http -> https redirect
server {
  listen 80;
$SERVER_NAME_LINE
$ACME_BLOCK
  location / {
    return 301 https://\$server_name\$request_uri;
  }
  access_log /dev/null;
  error_log  /dev/null crit;
}

# catch-all
server {
  listen 80;
  server_name _;
  return 444;
}

# SSL Gateway — nginx binds loopback only; sslh (if present) owns the
# public :443 and multiplexes tls -> 127.0.0.1:443.
server {
  listen 127.0.0.1:$NGINX_PORT default_server ssl http2;

$SSL_BLOCK
  auth_basic            "Authorization Required";
  auth_basic_user_file  $HTPASSWD_FILE;

  ssl_protocols TLSv1.2;
  ssl_prefer_server_ciphers on;
  ssl_ciphers '$TLS_CIPHERS';
  ssl_ecdh_curve auto;
  ssl_session_timeout  10m;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  add_header X-Frame-Options DENY;
  add_header X-Content-Type-Options nosniff;
  add_header X-Robots-Tag none;
  add_header Referrer-Policy "no-referrer";

  access_log /dev/null;
  error_log  /dev/null crit;

  root  $GATEWAY;
  index index.html index.htm;

  location / {
    autoindex off;
  }
}
VHOST
ln -sf /etc/nginx/sites-available/streisand /etc/nginx/sites-enabled/streisand
rm -f /etc/nginx/sites-enabled/default

# gateway landing page + index docs
is_true "$ENABLE_OPENVPN" && OPENVPN_ENABLED="yes" || OPENVPN_ENABLED="no"
{
  echo "# Streisand gateway: $SERVER_NAME"
  echo
  echo "Server: https://$PUB_IP (username \`streisand\`, password in gateway-password.txt)"
  echo "Tor hidden service: http://$(cat $TOR_HS_DIR/hostname 2>/dev/null || echo 'n/a')"
  echo
  echo "Available services:"
  is_true "$ENABLE_OPENVPN"     && echo "- OpenVPN (openvpn/)"
  is_true "$ENABLE_STUNNEL"     && echo "- stunnel (openvpn/)"
  is_true "$ENABLE_OPENCONNECT" && echo "- OpenConnect (openconnect/)"
  is_true "$ENABLE_SHADOWSOCKS" && echo "- Shadowsocks (shadowsocks/)"
  is_true "$ENABLE_SSH_FORWARD" && echo "- SSH forwarding (ssh/)"
  is_true "$ENABLE_TINYPROXY"   && echo "- tinyproxy (via SSH SOCKS)"
  is_true "$ENABLE_TOR"         && echo "- Tor obfs4 bridge (tor/)"
  is_true "$ENABLE_WIREGUARD"   && echo "- WireGuard (wireguard/)"
} > "$GATEWAY/index.md"

# mirror page (links only)
if is_true "$ENABLE_OPENVPN" || is_true "$ENABLE_OPENCONNECT" || is_true "$ENABLE_SHADOWSOCKS" \
   || is_true "$ENABLE_SSH_FORWARD" || is_true "$ENABLE_STUNNEL" || is_true "$ENABLE_TOR"; then
  {
    echo "# Client software mirror"
    echo
    echo "- OpenVPN Connect / OpenVPN: https://openvpn.net/vpn-client/"
    echo "- WireGuard: https://www.wireguard.com/install/"
    echo "- Shadowsocks clients: https://shadowsocks.org/en/download/clients.html"
    echo "- Tor Browser: https://www.torproject.org/download/"
    echo "- OpenConnect: https://www.infradead.org/openconnect/download.html"
  } > "$MIRROR/index.md"
fi

# markdown -> html for every gateway page
find "$GATEWAY" -name '*.md' | while read -r mdf; do
  out="${mdf%.md}.html"
  { cat /tmp/header.html; markdown "$mdf"; cat /tmp/footer.html; } > "$out" 2>/dev/null || true
done

# gateway password + server info copied to the artifact directory that
# Terraform fetches to the operator machine. Must live under STREISAND_BOOT:
# on AWS/GCP the boot dir is the login user's home, not /root.
mkdir -p "$STREISAND_BOOT/streisand-local"
echo "$GW_PASS" > "$STREISAND_BOOT/streisand-local/gateway-password.txt"
echo "$PUB_IP" > "$STREISAND_BOOT/streisand-local/server-ip.txt"
cp "$STREISAND_BOOT/ssh-fingerprints.txt" "$STREISAND_BOOT/streisand-local/" 2>/dev/null || true
cp "$STREISAND_BOOT/streisand-client-names" "$STREISAND_BOOT/streisand-local/vpn-client-names.txt" 2>/dev/null || true
chown -R www-data:www-data "$GATEWAY"
chmod -R u+rwX,g+rX,o-rwx "$GATEWAY"

systemctl daemon-reload
systemctl enable nginx 2>/dev/null || true
nginx -t 2>/dev/null && systemctl restart nginx || fail "nginx config invalid"

# =====================================================================
# summary
# =====================================================================
echo "=== provision $( [ -z "$FAILED" ] && echo COMPLETE || echo "FAILED:$FAILED" ) ==="
if [ -n "$FAILED" ]; then
  for svc in openvpn stunnel wg-quick@wg0 shadowsocks-libev ocserv tor tinyproxy sslh nginx dnsmasq; do
    systemctl is-active --quiet "$svc" 2>/dev/null && echo "active: $svc"
  done
  # do not fail hard on transient service start issues; report them
  exit 0
fi
# Re-enable unattended-upgrades and apt daily timers (disabled during bootstrap)
systemctl enable --now unattended-upgrades 2>/dev/null || true
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
exit 0
