cat > /root/domayer-playprotect.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

APP="/var/www/pterodactyl"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/domayer-playprotect-backup-$STAMP"

clear 2>/dev/null || true
echo "=================================================="
echo "       DOMAYER NETWORK PLAYPROTECT"
echo "       ROLE SYSTEM INSTALLER"
echo "       SCRIPT BY DOMAYER NETWORK HOSTING"
echo "=================================================="
echo "Panel : $APP"
echo "Backup: $BACKUP"
echo
read -r -p "Lanjutkan instalasi backup + role dasar? [Y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Dibatalkan."; exit 0; }

[[ -d "$APP/app/Http/Middleware" && -f "$APP/.env" ]] || {
  echo "ERROR: Direktori panel tidak valid."; exit 1;
}

mkdir -p "$BACKUP/files"
cp -a "$APP/app/Http/Middleware/AdminAuthenticate.php" "$BACKUP/files/"
cp -a "$APP/app/Models/User.php" "$BACKUP/files/" 2>/dev/null || true
cp -a "$APP/app/Http/Controllers/Admin/UserController.php" "$BACKUP/files/" 2>/dev/null || true
cp -a "$APP/resources/views/admin/users/new.blade.php" "$BACKUP/files/" 2>/dev/null || true
cp -a "$APP/app/Http/Requests/Admin/ServerFormRequest.php" "$BACKUP/files/" 2>/dev/null || true
cp -a "$APP/.env" "$BACKUP/files/env.backup"

cd "$APP"
DB_NAME="$(grep '^DB_DATABASE=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")"
DB_USER="$(grep '^DB_USERNAME=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")"
DB_PASS="$(grep '^DB_PASSWORD=' .env | cut -d= -f2- | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//')"
DB_HOST="$(grep '^DB_HOST=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")"
DB_PORT="$(grep '^DB_PORT=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

echo
echo "Membuat backup database..."
if [[ -n "$DB_NAME" && -n "$DB_USER" ]]; then
  if MYSQL_PWD="$DB_PASS" mysqldump \
      --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
      --single-transaction --routines --triggers "$DB_NAME" \
      > "$BACKUP/database.sql"; then
    chmod 600 "$BACKUP/database.sql"
  else
    echo "Backup database gagal. Tidak ada perubahan aplikasi."
    rm -f "$BACKUP/database.sql"
    exit 1
  fi
else
  echo "Konfigurasi database tidak terbaca. Instalasi dihentikan."
  exit 1
fi

echo "Membuat backup source panel..."
tar -czf "$BACKUP/panel-files.tar.gz" \
  --exclude='vendor' --exclude='node_modules' --exclude='storage/logs/*' \
  -C "$APP" app/Http/Middleware app/Models app/Http/Controllers/Admin \
  resources/views/admin/users app/Http/Requests/Admin database/migrations

echo
echo "Backup selesai: $BACKUP"
echo "Installer berhenti sebelum mengubah akses panel."
echo "Role middleware dan validasi resource belum dipasang."
echo "Backup aman tersimpan; panel tidak diubah."
SCRIPT

chmod 700 /root/domayer-playprotect.sh
bash /root/domayer-playprotect.sh