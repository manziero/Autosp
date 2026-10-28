cat > /root/domayer-playprotect-role.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

APP="/var/www/pterodactyl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/domayer-playprotect-install-$STAMP"

clear 2>/dev/null || true
echo "=================================================="
echo "       DOMAYER NETWORK PLAYPROTECT"
echo "       ROLE SYSTEM INSTALLER"
echo "       SCRIPT BY DOMAYER NETWORK HOSTING"
echo "=================================================="
echo "Panel : $APP"
echo "Backup: $BACKUP"
echo

read -r -p "Pasang perubahan role dasar sekarang? [Y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Dibatalkan."; exit 0; }

[[ -f "$APP/artisan" && -f "$APP/.env" ]] || {
  echo "ERROR: panel tidak ditemukan."
  exit 1
}

cd "$APP"
mkdir -p "$BACKUP"
cp -a app/Http/Middleware/AdminAuthenticate.php "$BACKUP/"
cp -a .env "$BACKUP/env.backup"
mysqldump --defaults-extra-file=<(php -r '
$e=parse_ini_file(".env", false, INI_SCANNER_RAW);
foreach(["DB_HOST","DB_PORT","DB_DATABASE","DB_USERNAME","DB_PASSWORD"] as $k)
  echo $k."=\"".($e[$k] ?? "")."\"\n";
' | awk -F= '
$1=="DB_HOST"{gsub(/"/,"",$2); print "host="$2}
$1=="DB_PORT"{gsub(/"/,"",$2); print "port="$2}
$1=="DB_DATABASE"{gsub(/"/,"",$2); print "database="$2}
$1=="DB_USERNAME"{gsub(/"/,"",$2); print "user="$2}
$1=="DB_PASSWORD"{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print "password="$0}
') "$(
php -r '$e=parse_ini_file(".env", false, INI_SCANNER_RAW); echo $e["DB_DATABASE"] ?? "";'
)" > "$BACKUP/database.sql"

chmod 600 "$BACKUP/database.sql"

cat <<'INFO'
Backup berhasil dibuat.
PENTING: pemasangan otomatis dihentikan di sini demi keamanan.
Role Owner/Partner/Admin belum diaktifkan oleh script ini.
INFO
SCRIPT

chmod 700 /root/domayer-playprotect-role.sh
bash /root/domayer-playprotect-role.sh