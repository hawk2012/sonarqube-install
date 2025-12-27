#!/bin/bash
set -euo pipefail

# === КОНФИГУРАЦИЯ ===
SONARQUBE_VERSION="sonarqube-25.12.0.117093"  # ← менять здесь
DB_USER="sonar"
DB_PASS="sonar"
DB_NAME="sonarqube"
INSTALL_DIR="/opt/sonarqube"
SONAR_USER="sonar"
# === КОНЕЦ КОНФИГУРАЦИИ ===

echo "[*] Начинаем установку SonarQube: $SONARQUBE_VERSION"

if [ "$EUID" -ne 0 ]; then
  echo "[!] Запустите скрипт от root или через sudo"
  exit 1
fi

# === 1. Установка Eclipse Temurin JDK 17 (официально рекомендовано Sonar) ===
echo "[*] Установка Eclipse Temurin JDK 17..."
if ! command -v java &> /dev/null || ! java -version 2>&1 | grep -q "Temurin"; then
  apt update
  wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public 2>/dev/null | gpg --dearmor | sudo tee /usr/share/keyrings/adoptium.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" | sudo tee /etc/apt/sources.list.d/adoptium.list
  apt update
  apt install -y temurin-17-jdk
else
  echo "[*] Temurin JDK 17 уже установлен"
fi

# === 2. Postgres Pro 16 для 1С ===
echo "[*] Установка Postgres Pro 16..."
wget -qO- https://repo.postgrespro.ru/pg1c-16/keys/pgpro-repo-add.sh | bash
apt install -y postgrespro-1c-16
systemctl enable --now postgrespro-1c-16

# === 3. База данных ===
echo "[*] Создание БД..."
sudo -u postgres createuser --no-createdb --no-createrole --no-superuser "$DB_USER" 2>/dev/null || true
sudo -u postgres psql -c "ALTER USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;"
sudo -u postgres createdb --owner="$DB_USER" "$DB_NAME"

# === 4. Системные лимиты ===
echo "[*] Настройка лимитов и sysctl..."
cat >> /etc/security/limits.conf <<EOF

# SonarQube limits
$SONAR_USER soft nofile 65536
$SONAR_USER hard nofile 65536
$SONAR_USER soft nproc 4096
$SONAR_USER hard nproc 4096
EOF

echo "vm.max_map_count = 262144" >> /etc/sysctl.conf
sysctl -p >/dev/null

# === 5. Скачивание SonarQube ===
echo "[*] Скачивание и распаковка SonarQube..."
cd /tmp
apt install -y unzip
# ИСПРАВЛЕНО: убран пробел в URL!
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONARQUBE_VERSION}.zip"
wget -O "${SONARQUBE_VERSION}.zip" "$SONAR_URL"
unzip -q "${SONARQUBE_VERSION}.zip"
rm -rf "$INSTALL_DIR"
mv "/tmp/$SONARQUBE_VERSION" "$INSTALL_DIR"

# === 6. Пользователь и права ===
echo "[*] Настройка пользователя и прав..."
groupadd "$SONAR_USER" 2>/dev/null || true
useradd -r -g "$SONAR_USER" -d "$INSTALL_DIR" -s /bin/false -c "SonarQube user" "$SONAR_USER"
chown -R "$SONAR_USER":"$SONAR_USER" "$INSTALL_DIR"

# === 7. Настройка sonar.properties ===
CONF="$INSTALL_DIR/conf/sonar.properties"
sed -i "s|^#.*sonar.jdbc.username=.*|sonar.jdbc.username=$DB_USER|" "$CONF"
sed -i "s|^#.*sonar.jdbc.password=.*|sonar.jdbc.password=$DB_PASS|" "$CONF"
sed -i "s|^#.*sonar.jdbc.url=.*|sonar.jdbc.url=jdbc:postgresql://localhost/$DB_NAME|" "$CONF"
sed -i "s|^#.*sonar.path.data=.*|sonar.path.data=$INSTALL_DIR/data|" "$CONF"
sed -i "s|^#.*sonar.path.temp=.*|sonar.path.temp=$INSTALL_DIR/temp|" "$CONF"

grep -q "^sonar.ce.javaOpts=" "$CONF" || echo "
sonar.ce.javaOpts=-Xmx4G -Xms1G -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError
" >> "$CONF"

# === 8. Создание systemd-юнита (production) ===
echo "[*] Создание systemd-службы..."
cat > /etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube - Code Quality Analysis Platform
After=network.target postgrespro-1c-16.service
Wants=postgrespro-1c-16.service

[Service]
Type=forking
User=$SONAR_USER
Group=$SONAR_USER
ExecStart=$INSTALL_DIR/bin/linux-x86-64/sonar.sh start
ExecStop=$INSTALL_DIR/bin/linux-x86-64/sonar.sh stop
ExecReload=$INSTALL_DIR/bin/linux-x86-64/sonar.sh restart
TimeoutSec=300
LimitNOFILE=65536
LimitNPROC=4096
SuccessExitStatus=0 1
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sonarqube

echo
echo "Установка завершена!"
echo "SonarQube: $INSTALL_DIR"
echo "Служба: sonarqube (systemctl start|stop|status sonarqube)"
echo
echo "Запуск:"
echo "  sudo systemctl start sonarqube"
echo
echo "Логи:"
echo "  sudo journalctl -u sonarqube -f"
