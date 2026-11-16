#!/usr/bin/env bash
# One-time setup for the Minecraft server on the Oracle Cloud Ubuntu 24.04 VM.
# Run on the server as:  sudo EULA=yes bash setup.sh
# (EULA=yes means you accept the Minecraft EULA: https://aka.ms/MinecraftEULA)
set -euo pipefail

PAPER_VERSION="26.1.2"
PAPER_BUILD="74"
PAPER_URL="https://fill-data.papermc.io/v1/objects/1d70b1dab9cf4a6de615209a536f3a45a2186240253c428213ce2188ab95e5f7/paper-26.1.2-74.jar"
PAPER_SHA256="1d70b1dab9cf4a6de615209a536f3a45a2186240253c428213ce2188ab95e5f7"
MC_DIR="/opt/minecraft"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${EULA:-}" != "yes" ]]; then
  echo "Refusing to continue: run with EULA=yes to accept the Minecraft EULA (https://aka.ms/MinecraftEULA)." >&2
  exit 1
fi
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

echo "==> Time zone: Greece"
timedatectl set-timezone Europe/Athens

echo "==> Updating Ubuntu"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates python3 rclone iptables-persistent

echo "==> Installing Java 25"
if ! apt-get install -y openjdk-25-jre-headless; then
  echo "Ubuntu's Java 25 not available, using Eclipse Temurin"
  apt-get install -y wget apt-transport-https gpg
  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
  echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release; echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list
  apt-get update -y
  apt-get install -y temurin-25-jre || apt-get install -y temurin-25-jdk
fi
java -version

echo "==> Opening port 25565 in the server firewall"
if ! iptables -C INPUT -p tcp --dport 25565 -m state --state NEW -j ACCEPT 2>/dev/null; then
  iptables -I INPUT -p tcp --dport 25565 -m state --state NEW -j ACCEPT
fi
netfilter-persistent save

echo "==> Creating minecraft user and folder"
id minecraft >/dev/null 2>&1 || useradd --system --create-home --home-dir "$MC_DIR" --shell /usr/sbin/nologin minecraft
mkdir -p "$MC_DIR"/{plugins,backups}

echo "==> Downloading Paper $PAPER_VERSION build $PAPER_BUILD"
curl -fsSL -A "mcserver-setup/1.0" -o "$MC_DIR/paper.jar.new" "$PAPER_URL"
echo "$PAPER_SHA256  $MC_DIR/paper.jar.new" | sha256sum -c -
mv "$MC_DIR/paper.jar.new" "$MC_DIR/paper.jar"

echo "==> Writing settings"
echo "eula=true" > "$MC_DIR/eula.txt"
if [[ ! -f "$MC_DIR/.rcon-password" ]]; then
  head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$MC_DIR/.rcon-password"
fi
RCON_PW="$(cat "$MC_DIR/.rcon-password")"
if [[ ! -f "$MC_DIR/server.properties" ]]; then
  cat > "$MC_DIR/server.properties" <<EOF
motd=§aOur Survival Server §7| §e26.1.2
gamemode=survival
difficulty=normal
hardcore=false
pvp=true
max-players=20
view-distance=10
simulation-distance=8
white-list=true
enforce-whitelist=true
online-mode=true
spawn-protection=16
server-port=25565
enable-rcon=true
rcon.port=25575
rcon.password=$RCON_PW
broadcast-rcon-to-ops=false
sync-chunk-writes=false
EOF
fi
install -m 755 "$HERE/rcon.py" "$MC_DIR/rcon.py"
install -m 755 "$HERE/backup.sh" "$MC_DIR/backup.sh"
chown -R minecraft:minecraft "$MC_DIR"
chmod 600 "$MC_DIR/.rcon-password"

echo "==> Installing services"
install -m 644 "$HERE/minecraft.service" /etc/systemd/system/minecraft.service
# Fit Minecraft's memory to the server: 24 GB machine -> 12G, 12 GB machine -> 8G
TOTAL_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
if   (( TOTAL_GB >= 20 )); then HEAP=12G
elif (( TOTAL_GB >= 10 )); then HEAP=8G
elif (( TOTAL_GB >= 5 ));  then HEAP=4G   # 6 GB machine (shows as ~5)
else HEAP=$(( TOTAL_GB * 2 / 3 ))G; fi
# On a 1-core server, lower view/simulation distance so 5-8 players stay smooth
if (( $(nproc) <= 1 )); then
  sed -i 's/^view-distance=.*/view-distance=8/; s/^simulation-distance=.*/simulation-distance=6/' "$MC_DIR/server.properties"
  echo "    1-core server: view-distance 8, simulation-distance 6"
fi
sed -i "s/-Xms12G -Xmx12G/-Xms$HEAP -Xmx$HEAP/" /etc/systemd/system/minecraft.service
echo "    Machine has ~${TOTAL_GB} GB RAM, giving Minecraft $HEAP"
install -m 644 "$HERE/minecraft-backup.service" /etc/systemd/system/minecraft-backup.service
install -m 644 "$HERE/minecraft-backup.timer" /etc/systemd/system/minecraft-backup.timer
systemctl daemon-reload
systemctl enable --now minecraft.service
systemctl enable --now minecraft-backup.timer

# Small helper so admins can type:  mc "whitelist add Name"
cat > /usr/local/bin/mc <<'EOF'
#!/usr/bin/env bash
sudo -u minecraft python3 /opt/minecraft/rcon.py "$@"
EOF
chmod 755 /usr/local/bin/mc

echo "==> Done. Server is starting (first start takes ~1 minute)."
echo "    Watch it with:  sudo journalctl -u minecraft -f"
