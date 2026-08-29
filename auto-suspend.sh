#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Auto Suspend Installer
# Fixed + Cron version
# ============================================================

PTERODACTYL="/var/www/pterodactyl"
AUTOSUSPEND_URL="https://raw.githubusercontent.com/manziero/Autosp/main/expdate.zip"
BACKUP_DIR="/root/pterodactyl-auto-suspend-backup-$(date +%Y%m%d-%H%M%S)"
TMP_DIR=""

log() {
    printf '[AUTO-SUSPEND] %s\n' "$*"
}

print_info() {
    printf '[INFO] %s\n' "$*"
}

die() {
    printf '[AUTO-SUSPEND] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Jalankan script sebagai root."
}

require_panel() {
    [[ -d "$PTERODACTYL" ]] ||
        die "Pterodactyl tidak ditemukan di $PTERODACTYL."

    [[ -f "$PTERODACTYL/artisan" ]] ||
        die "Laravel artisan tidak ditemukan."
}

install_base_packages() {
    log "Memeriksa dependency dasar..."

    export DEBIAN_FRONTEND=noninteractive

    command -v apt-get >/dev/null 2>&1 ||
        die "Script ini membutuhkan apt-get."

    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        unzip \
        wget \
        jq \
        cron
}

install_node22_if_needed() {
    local major=""

    if command -v node >/dev/null 2>&1; then
        major="$(node -v | sed 's/^v//' | cut -d. -f1)"
    fi

    if [[ "$major" == "22" ]]; then
        log "Node.js 22 sudah tersedia."
        return
    fi

    log "Menginstal Node.js 22..."

    install -d -m 0755 /etc/apt/keyrings

    curl -fsSL \
        https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
        gpg --dearmor --yes \
        -o /etc/apt/keyrings/nodesource.gpg

    cat >/etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main
EOF

    apt-get update
    apt-get install -y nodejs

    command -v node >/dev/null 2>&1 ||
        die "Node.js gagal diinstal."

    command -v npm >/dev/null 2>&1 ||
        die "npm tidak ditemukan."
}

install_yarn() {
    if command -v yarn >/dev/null 2>&1; then
        log "Yarn sudah tersedia: $(yarn --version)"
        return
    fi

    log "Menginstal Yarn..."

    npm install -g yarn
    hash -r

    command -v yarn >/dev/null 2>&1 ||
        die "Yarn gagal diinstal."
}

backup_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$file" "$BACKUP_DIR/$(basename "$file")"
    fi
}

download_autosuspend() {
    TMP_DIR="$(mktemp -d)"

    log "Mengunduh expdate.zip..."

    curl -fL \
        "$AUTOSUSPEND_URL" \
        -o "$TMP_DIR/expdate.zip"

    [[ -s "$TMP_DIR/expdate.zip" ]] ||
        die "Gagal mengunduh expdate.zip."

    log "Memeriksa ZIP..."

    unzip -tq "$TMP_DIR/expdate.zip" ||
        die "expdate.zip rusak atau bukan ZIP valid."

    log "Mengekstrak expdate.zip..."

    mkdir -p "$TMP_DIR/extracted"

    unzip -oq \
        "$TMP_DIR/expdate.zip" \
        -d "$TMP_DIR/extracted"

    if [[ -d "$TMP_DIR/extracted/database" ]]; then
        log "Folder database ditemukan."

        cp -a \
            "$TMP_DIR/extracted/database" \
            "$PTERODACTYL/"
    else
        die "Folder database tidak ditemukan di expdate.zip."
    fi

    log "Migration Auto Suspend berhasil disalin."
}

patch_kernel() {
    local file="$PTERODACTYL/app/Console/Kernel.php"

    [[ -f "$file" ]] ||
        die "Kernel.php tidak ditemukan."

    backup_file "$file"

    log "Memasang scheduler Auto Suspend..."

    if ! grep -Fq 'use Pterodactyl\Models\Server;' "$file"; then
        if grep -Fq 'use Ramsey\Uuid\Uuid;' "$file"; then
            sed -i \
                '/use Ramsey\\Uuid\\Uuid;/a use Pterodactyl\\Models\\Server;' \
                "$file"
        else
            sed -i \
                '/^namespace /a use Pterodactyl\\Models\\Server;' \
                "$file"
        fi
    fi

    if ! grep -Fq "Server::whereNotNull('exp_date')" "$file"; then

        if grep -Fq \
            '$schedule->command(CleanServiceBackupFilesCommand::class)->daily();' \
            "$file"; then

            python3 - "$file" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

marker = "$schedule->command(CleanServiceBackupFilesCommand::class)->daily();"

scheduler = r'''
        $schedule->call(function () {
            $servers = Server::whereNotNull('exp_date')
                ->where('exp_date', '<', now())
                ->get();

            $suspensionService = \App::make(
                'Pterodactyl\Services\Servers\SuspensionService'
            );

            foreach ($servers as $server) {
                if (
                    $server->status !== 'suspended' &&
                    $server->status !== 'installing' &&
                    $server->exp_date !== null
                ) {
                    try {
                        $suspensionService->toggle($server, 'suspend');
                    } catch (\Throwable $e) {
                        \Log::error(
                            'Auto Suspend failed for server ' .
                            $server->id . ': ' .
                            $e->getMessage()
                        );
                    }
                }
            }
        })->dailyAt('23:55');
'''

if "Server::whereNotNull('exp_date')" not in text:
    if marker not in text:
        raise SystemExit("Scheduler Pterodactyl tidak ditemukan.")

    text = text.replace(
        marker,
        marker + "\n" + scheduler,
        1
    )

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

        else
            log "Pattern scheduler lama tidak ditemukan."
            log "Scheduler tidak dipaksa agar tidak merusak Kernel.php."
        fi

    else
        log "Scheduler Auto Suspend sudah ada."
    fi
}

patch_backend() {
    local file

    file="$PTERODACTYL/app/Http/Controllers/Admin/ServersController.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq \
            "'owner_id', 'external_id', 'name', 'description'," \
            "$file"; then

            if ! grep -Fq "'exp_date'," "$file"; then
                sed -i \
                    "/'owner_id', 'external_id', 'name', 'description',/a\\
            'exp_date'," \
                    "$file"
            fi
        fi
    fi

    file="$PTERODACTYL/app/Http/Requests/Api/Application/Servers/StoreServerRequest.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq \
            "'oom_disabled' => 'sometimes|boolean'," \
            "$file"; then

            if ! grep -Fq "'exp_date'" "$file"; then
                sed -i \
                    "/'oom_disabled' => 'sometimes|boolean',/a\\
            'exp_date' => \$rules['exp_date']," \
                    "$file"
            fi
        fi

        if grep -Fq \
            "'oom_disabled' => array_get(\$data, 'oom_disabled')," \
            "$file"; then

            if ! grep -Fq \
                "'exp_date' => array_get(\$data, 'exp_date')," \
                "$file"; then

                sed -i \
                    "/'oom_disabled' => array_get(\\\$data, 'oom_disabled'),/a\\
            'exp_date' => array_get(\$data, 'exp_date')," \
                    "$file"
            fi
        fi
    fi

    file="$PTERODACTYL/app/Models/Server.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq \
            "'backup_limit' => 'present|nullable|integer|min:0'," \
            "$file"; then

            if ! grep -Fq "'exp_date'" "$file"; then
                sed -i \
                    "/'backup_limit' => 'present|nullable|integer|min:0',/a\\
        'exp_date' => 'sometimes|nullable'," \
                    "$file"
            fi
        fi
    fi

    file="$PTERODACTYL/app/Services/Servers/DetailsModificationService.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq \
            "'description' => Arr::get(\$data, 'description') ?? ''," \
            "$file"; then

            if ! grep -Fq "'exp_date'" "$file"; then
                sed -i \
                    "/'description' => Arr::get(\\\$data, 'description') ?? '',/a\\
                'exp_date' => Arr::get(\$data, 'exp_date') ?? null," \
                    "$file"
            fi
        fi
    fi

    file="$PTERODACTYL/app/Services/Servers/ServerCreationService.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq \
            "'backup_limit' => Arr::get(\$data, 'backup_limit') ?? 0," \
            "$file"; then

            if ! grep -Fq "'exp_date'" "$file"; then
                sed -i \
                    "/'backup_limit' => Arr::get(\\\$data, 'backup_limit') ?? 0,/a\\
                'exp_date' => Arr::get(\$data, 'exp_date') ?? null," \
                    "$file"
            fi
        fi
    fi

    file="$PTERODACTYL/app/Transformers/Api/Client/ServerTransformer.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq "'name' => \$server->name," "$file"; then

            if ! grep -Fq "'exp_date'" "$file"; then
                sed -i \
                    "/'name' => \\\$server->name,/a\\
                'exp_date' => \$server->exp_date," \
                    "$file"
            fi
        fi
    fi
}

patch_client() {
    local file="$PTERODACTYL/resources/scripts/api/server/getServer.ts"

    [[ -f "$file" ]] || return 0

    backup_file "$file"

    if grep -Fq "name: string;" "$file"; then
        if ! grep -Fq "expDate: string;" "$file"; then
            sed -i \
                "/name: string;/a\\
        expDate: string;" \
                "$file"
        fi
    fi

    if grep -Fq "name: data.name," "$file"; then
        if ! grep -Fq "expDate: data.exp_date," "$file"; then
            sed -i \
                "/name: data.name,/a\\
        expDate: data.exp_date," \
                "$file"
        fi
    fi
}

patch_server_details() {
    local file="$PTERODACTYL/resources/scripts/components/server/console/ServerDetailsBlock.tsx"

    [[ -f "$file" ]] || return 0

    backup_file "$file"

    if ! grep -Fq "faCalendarDay" "$file"; then
        if grep -Fq "faMicrochip," "$file"; then
            sed -i \
                "/faMicrochip,/a\\
        faCalendarDay," \
                "$file"
        fi
    fi

    if grep -Fq \
        "const limits = ServerContext.useStoreState((state) => state.server.data!.limits);" \
        "$file"; then

        if ! grep -Fq "const expDate =" "$file"; then
            sed -i \
                "/const limits = ServerContext.useStoreState((state) => state.server.data!.limits);/a\\
        const expDate = ServerContext.useStoreState((state) => state.server.data!.expDate);" \
                "$file"
        fi
    fi
}

patch_blades() {

    local TARGET_BLADE
    local TARGET_NEW

    # ========================================================
    # EDIT SERVER
    # ========================================================

    TARGET_BLADE="resources/views/admin/servers/view/details.blade.php"

    if [[ -f "$PTERODACTYL/$TARGET_BLADE" ]]; then

        local file="$PTERODACTYL/$TARGET_BLADE"

        if ! grep -Fq 'name="exp_date"' "$file"; then

            backup_file "$file"

            if grep -Fq "Character limits:" "$file"; then

                sed -i \
                    '/<p class="text-muted small">Character limits:/,/<\/div>/ {
                        /<\/div>/ {
                            s|<\/div>|&\
                    <div class="form-group">\
                        <label for="exp_date" class="control-label">Expiration date<\/label>\
                        <input type="date" name="exp_date" value="{{ old('\''exp_date'\'', $server->exp_date) }}" class="form-control" />\
                        <p class="text-muted small">LXJR OFFC Server akan kadaluarsa pada tanggal yang dipilih. Kosongkan untuk server permanen.<\/p>\
                    <\/div>|
                        }
                    }' \
                    "$file"
            fi
        fi
    fi

    # ========================================================
    # CREATE SERVER
    # ========================================================

    TARGET_NEW="resources/views/admin/servers/new.blade.php"

    if [[ -f "$PTERODACTYL/$TARGET_NEW" ]]; then

        local file="$PTERODACTYL/$TARGET_NEW"

        if ! grep -Fq 'name="exp_date"' "$file"; then

            backup_file "$file"

            print_info "Menambahkan field Expiration Date ke Create Server..."

            if grep -Fq \
                'Email address of the Server Owner.' \
                "$file"; then

                sed -i \
                    '/<p class="small text-muted no-margin">Email address of the Server Owner.<\/p>/,/<\/div>/ {
                        /<\/div>/ {
                            s|<\/div>|&\
\
                        <div class="form-group">\
                            <label for="exp_date">Expiration date<\/label>\
                            <input type="date" class="form-control" id="expiration" name="exp_date" value="{{ old('\''exp_date'\'') }}" placeholder="Expiration Date">\
                            <p class="small text-muted no-margin">Server akan kadaluarsa (suspend) di akhir hari pada tanggal yang dipilih (kosongkan jika ingin server permanen)<\/p>\
                        <\/div>|
                        }
                    }' \
                    "$file"

                print_info "Field Expiration Date berhasil ditambahkan."

            else
                log "Pattern Owner tidak ditemukan di $TARGET_NEW."
                log "Field Expiration Date tidak dipaksakan agar form tidak rusak."
            fi
        else
            print_info "Expiration Date sudah ada di Create Server."
        fi
    else
        log "File $TARGET_NEW tidak ditemukan."
    fi
}

install_scheduler_cron() {

    log "Memastikan cron Laravel www-data aktif..."

    command -v crontab >/dev/null 2>&1 ||
        die "crontab tidak ditemukan."

    systemctl enable --now cron >/dev/null 2>&1 || true

    local cron_line='* * * * * cd /var/www/pterodactyl && php artisan schedule:run >> /dev/null 2>&1'
    local cron_tmp

    cron_tmp="$(mktemp)"

    (
        crontab -u www-data -l 2>/dev/null || true
    ) |
        grep -vF \
            'cd /var/www/pterodactyl && php artisan schedule:run' \
            > "$cron_tmp" || true

    echo "$cron_line" >> "$cron_tmp"

    crontab -u www-data "$cron_tmp"

    rm -f "$cron_tmp"

    if crontab -u www-data -l 2>/dev/null |
        grep -Fq "$cron_line"; then

        log "Cron Laravel www-data berhasil dipasang."

    else
        die "Cron Laravel www-data gagal dipasang."
    fi
}

migrate_and_build() {

    cd "$PTERODACTYL"

    log "Menjalankan migration database..."

    php artisan migrate --force

    log "Memastikan cross-env tersedia..."

    if command -v jq >/dev/null 2>&1; then

        if ! jq -e \
            '.dependencies["cross-env"] or .devDependencies["cross-env"]' \
            package.json >/dev/null 2>&1; then

            yarn add cross-env
        fi
    fi

    log "Menjalankan yarn install..."

    yarn install

    log "Membangun aset panel..."

    export NODE_OPTIONS=--openssl-legacy-provider

    yarn run build:production

    log "Membersihkan cache Laravel..."

    php artisan optimize:clear

    chown -R www-data:www-data "$PTERODACTYL"
}

verify() {

    local kernel="$PTERODACTYL/app/Console/Kernel.php"

    if grep -Fq \
        "Server::whereNotNull('exp_date')" \
        "$kernel"; then

        log "Scheduler Auto Suspend ditemukan."

    elif grep -Fq \
        "Server::where('exp_date'" \
        "$kernel"; then

        log "Scheduler Auto Suspend ditemukan."

    else
        die "Scheduler Auto Suspend tidak ditemukan."
    fi

    if [[ -f "$PTERODACTYL/resources/views/admin/servers/new.blade.php" ]]; then

        if grep -Fq \
            'name="exp_date"' \
            "$PTERODACTYL/resources/views/admin/servers/new.blade.php"; then

            log "Expiration Date ditemukan di Create Server."

        else
            log "PERINGATAN: Expiration Date belum ditemukan di Create Server."
        fi
    fi

    if crontab -u www-data -l 2>/dev/null |
        grep -Fq \
            '* * * * * cd /var/www/pterodactyl && php artisan schedule:run'; then

        log "Cron Laravel www-data ditemukan."

    else
        die "Cron Laravel www-data tidak ditemukan."
    fi

    log "Backup file tersimpan di: $BACKUP_DIR"
}

main() {

    require_root
    require_panel

    log "=============================================="
    log "INSTALL PTERODACTYL AUTO SUSPEND"
    log "=============================================="

    install_base_packages
    install_node22_if_needed
    install_yarn

    download_autosuspend

    patch_kernel
    patch_backend
    patch_client
    patch_server_details
    patch_blades

    migrate_and_build

    install_scheduler_cron

    verify

    printf '\n'

    log "=============================================="
    log "LXJR OFFC AUTO SUSPEND BERHASIL DIPASANG"
    log "=============================================="

    log "Expiration Date tersedia di Create Server."
    log "Cron Laravel berjalan setiap menit."
    log "Auto Suspend dijadwalkan setiap hari pukul 23:55."
}

main "$@"