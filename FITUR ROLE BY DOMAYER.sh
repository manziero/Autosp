
cat > /root/domayer-branding-patch.sh <<'PATCH'
#!/usr/bin/env bash
set -Eeuo pipefail

APP="/var/www/pterodactyl"
INSTALLER="/root/domayer-playprotect-installer.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/domayer-branding-backup-$STAMP"

if [ "$(id -u)" -ne 0 ]; then
    echo "Jalankan sebagai root."
    exit 1
fi

if [ ! -f "$APP/artisan" ] || [ ! -f "$INSTALLER" ]; then
    echo "STOP: panel atau installer tidak ditemukan."
    exit 1
fi

cd "$APP"

for f in \
    resources/views/admin/users/new.blade.php \
    app/Services/PlayProtect/PlayProtect.php
do
    if [ ! -f "$f" ]; then
        echo "STOP: file tidak ditemukan: $f"
        exit 1
    fi
done

mkdir -p "$BACKUP"
cp -a "$INSTALLER" "$BACKUP/"
cp -a resources/views/admin/users/new.blade.php "$BACKUP/new.blade.php"
cp -a app/Services/PlayProtect/PlayProtect.php "$BACKUP/PlayProtect.php"

echo
echo "=================================================="
echo "  SCRIPT BY DOMAYER NETWORK HOSTING"
echo "  PLAYPROTECT ROLE INSTALLER"
echo "=================================================="
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path
import sys

installer = Path("/root/domayer-playprotect-installer.sh")
view = Path("/var/www/pterodactyl/resources/views/admin/users/new.blade.php")
service = Path("/var/www/pterodactyl/app/Services/PlayProtect/PlayProtect.php")

s = installer.read_text()
v = view.read_text()
p = service.read_text()

# Branding besar saat installer dijalankan.
old_banner = '''echo " DOMAYER PLAYPROTECT INSTALLER"
echo " Owner / Partner / Admin Panel / User Biasa"
echo "=============================================="'''

new_banner = '''echo "  SCRIPT BY DOMAYER NETWORK HOSTING"
echo "  DOMAYER PLAYPROTECT INSTALLER"
echo "  Owner / Partner / Admin Panel / User Biasa"
echo "=============================================="'''

if old_banner in s:
    s = s.replace(old_banner, new_banner, 1)
elif "SCRIPT BY DOMAYER NETWORK HOSTING" not in s:
    print("STOP: format banner installer berbeda; tidak menyimpan perubahan.")
    sys.exit(1)

# Branding ikut dimasukkan ke form saat installer digunakan
# untuk instalasi baru.
old_field = '''field = """
<div class="form-group">
    <label for="playprotect_role">Role Akun</label>'''

new_field = '''field = """
<div class="alert alert-info" style="margin-bottom:20px;">
    <strong>SCRIPT BY LXY</strong><br>
    Order hosting ke :
    <a href="https://wa.me/" target="_blank" rel="noopener noreferrer">6282310833480</a>
</div>
<div class="form-group">
    <label for="playprotect_role">Role Akun</label>'''

if old_field in s:
    s = s.replace(old_field, new_field, 1)
elif "Order hosting ke :" not in s:
    print("STOP: blok form installer berbeda; tidak menyimpan perubahan.")
    sys.exit(1)

# Tambahkan branding ke halaman Create User yang sedang aktif.
if "Order hosting ke :" not in v or "SCRIPT BY DOMAYER" not in v:
    marker = "</form>"
    if v.count(marker) != 1:
        print("STOP: penutup form tidak unik; halaman tidak diubah.")
        sys.exit(1)

    branding = '''
<div class="alert alert-info" style="margin-top:20px;">
    <strong>SCRIPT BY LXY</strong><br>
    Order hosting ke :
    <a href="https://wa.me/" target="_blank" rel="noopener noreferrer">6282310833480</a>
</div>
'''
    v = v.replace(marker, branding + marker, 1)

# Identitas di file kode fitur Role.
if "SCRIPT BY DOMAYER NETWORK HOSTING" not in p:
    marker = "<?php"
    p = p.replace(
        marker,
        marker + "\\n// SCRIPT BY DOMAYER NETWORK HOSTING",
        1
    )

# Semua perubahan teks disiapkan dahulu sebelum file ditulis.
installer.write_text(s)
view.write_text(v)
service.write_text(p)

print("Branding installer, halaman Create User, dan file Role diperbarui.")
PY

php -l app/Services/PlayProtect/PlayProtect.php
php artisan view:clear

echo
echo "=================================================="
echo " SCRIPT BY DOMAYER NETWORK HOSTING"
echo " BRANDING BERHASIL DIPASANG"
echo " Backup: $BACKUP"
echo "=================================================="
PATCH

chmod 700 /root/domayer-branding-patch.sh
bash /root/domayer-branding-patch.sh
