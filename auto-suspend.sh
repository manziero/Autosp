#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Auto Suspend Installer
# GitHub-ready standalone installer
# ============================================================

PTERODACTYL="/var/www/pterodactyl"
AUTOSUSPEND_URL="https://cdn.jsdelivr.net/gh/Bangsano/themeinstaller@main/autosuspend.zip"
BACKUP_DIR="/root/pterodactyl-auto-suspend-backup-$(date +%Y%m%d-%H%M%S)"
TMP_DIR=""

log() {
    printf '[AUTO-SUSPEND] %s\n' "$*"
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
    [[ -d "$PTERODACTYL" ]] || die "Pterodactyl tidak ditemukan di $PTERODACTYL."
    [[ -f "$PTERODACTYL/artisan" ]] || die "Laravel artisan tidak ditemukan."
}

install_base_packages() {
    log "Memeriksa dependency dasar..."
    export DEBIAN_FRONTEND=noninteractive

    command -v apt-get >/dev/null 2>&1 || die "Script ini membutuhkan apt-get."

    apt-get update
    apt-get install -y ca-certificates curl gnupg unzip wget jq
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

    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg

    cat >/etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main
EOF

    apt-get update
    apt-get install -y nodejs

    command -v node >/dev/null 2>&1 || die "Node.js gagal diinstal."
    command -v npm >/dev/null 2>&1 || die "npm tidak ditemukan setelah instalasi."
}

install_yarn() {
    if command -v yarn >/dev/null 2>&1; then
        log "Yarn sudah tersedia: $(yarn --version)"
        return
    fi

    log "Menginstal Yarn..."
    npm install -g yarn
    hash -r

    command -v yarn >/dev/null 2>&1 || die "Yarn gagal diinstal."
}

backup_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$file" "$BACKUP_DIR/$(basename "$file")"
    fi
}

replace_once() {
    local file="$1"
    local marker="$2"
    local content="$3"

    [[ -f "$file" ]] || return 0

    if ! grep -Fq "$marker" "$file"; then
        printf '%s\n' "$content" >> "$file"
    fi
}

download_autosuspend() {
    TMP_DIR="$(mktemp -d)"

    log "Mengunduh autosuspend.zip..."
    wget -q --show-progress "$AUTOSUSPEND_URL" \
        -O "$TMP_DIR/autosuspend.zip"

    [[ -s "$TMP_DIR/autosuspend.zip" ]] \
        || die "Gagal mengunduh autosuspend.zip."

    log "Mengekstrak autosuspend.zip..."
    unzip -oq "$TMP_DIR/autosuspend.zip" -d "$TMP_DIR/extracted"

    [[ -d "$TMP_DIR/extracted/pterodactyl" ]] \
        || die "Folder pterodactyl tidak ditemukan di autosuspend.zip."

    log "Menyalin file Auto Suspend..."
    cp -a "$TMP_DIR/extracted/pterodactyl/." "$PTERODACTYL/"
}

patch_kernel() {
    local file="$PTERODACTYL/app/Console/Kernel.php"

    [[ -f "$file" ]] || die "Kernel.php tidak ditemukan."

    backup_file "$file"

    if ! grep -Fq 'use Pterodactyl\Models\Server;' "$file"; then
        grep -Fq 'use Ramsey\Uuid\Uuid;' "$file" \
            || die "Pattern Ramsey UUID tidak ditemukan di Kernel.php."

        sed -i \
            '/use Ramsey\\Uuid\\Uuid;/a use Pterodactyl\\Models\\Server;' \
            "$file"
    fi

    if ! grep -Fq "Server::where('exp_date'" "$file"; then
        grep -Fq '$schedule->command(CleanServiceBackupFilesCommand::class)->daily();' "$file" \
            || die "Pattern scheduler Pterodactyl tidak ditemukan di Kernel.php."

        sed -i "/\\\$schedule->command(CleanServiceBackupFilesCommand::class)->daily();/a\\
\\
        \\\$schedule->call(function () { \\
            \\\$servers = Server::where('exp_date', '<', now())->get(); \\
            \\\$suspensionService = \\\\App::make('Pterodactyl\\\\Services\\\\Servers\\\\SuspensionService'); \\
            foreach (\\\$servers as \\\$server) { \\
                if (\\\$server->status != 'suspended') { \\
                    if (\\\$server->status != 'installing') { \\
                        if (\\\$server->exp_date != null) { \\
                            \\\$suspensionService->toggle(\\\$server, 'suspend'); \\
                        } \\
                    } \\
                } \\
            } \\
        })->dailyAt('23:55');" "$file"
    fi
}

patch_backend() {
    local file

    file="$PTERODACTYL/app/Http/Controllers/Admin/ServersController.php"
    backup_file "$file"
    if [[ -f "$file" ]] && ! grep -Fq "'owner_id', 'external_id', 'name', 'description'," "$file"; then
        die "Pattern ServersController.php tidak cocok dengan source Auto Suspend."
    fi
    if [[ -f "$file" ]] && ! grep -Fq "'exp_date'," "$file"; then
        sed -i "/'owner_id', 'external_id', 'name', 'description',/a\\
            'exp_date'," "$file"
    fi

    file="$PTERODACTYL/app/Http/Requests/Api/Application/Servers/StoreServerRequest.php"
    backup_file "$file"
    if [[ -f "$file" ]]; then
        if grep -Fq "'oom_disabled' => 'sometimes|boolean'," "$file" \
           && ! grep -Fq "'exp_date' => \$rules['exp_date']," "$file"; then
            sed -i "/'oom_disabled' => 'sometimes|boolean',/a\\
            'exp_date' => \$rules['exp_date']," "$file"
        fi
        if grep -Fq "'oom_disabled' => array_get(\$data, 'oom_disabled')," "$file" \
           && ! grep -Fq "'exp_date' => array_get(\$data, 'exp_date')," "$file"; then
            sed -i "/'oom_disabled' => array_get(\\\$data, 'oom_disabled'),/a\\
            'exp_date' => array_get(\\\$data, 'exp_date')," "$file"
        fi
    fi

    file="$PTERODACTYL/app/Models/Server.php"
    backup_file "$file"
    if [[ -f "$file" ]] \
       && grep -Fq "'backup_limit' => 'present|nullable|integer|min:0'," "$file" \
       && ! grep -Fq "'exp_date' => 'sometimes|nullable'," "$file"; then
        sed -i "/'backup_limit' => 'present|nullable|integer|min:0',/a\\
        'exp_date' => 'sometimes|nullable'," "$file"
    fi

    file="$PTERODACTYL/app/Services/Servers/DetailsModificationService.php"
    backup_file "$file"
    if [[ -f "$file" ]] \
       && grep -Fq "'description' => Arr::get(\$data, 'description') ?? ''," "$file" \
       && ! grep -Fq "'exp_date' => Arr::get(\$data, 'exp_date') ?? null," "$file"; then
        sed -i "/'description' => Arr::get(\\\$data, 'description') ?? '',/a\\
                'exp_date' => Arr::get(\\\$data, 'exp_date') ?? null," "$file"
    fi

    file="$PTERODACTYL/app/Services/Servers/ServerCreationService.php"
    backup_file "$file"
    if [[ -f "$file" ]] \
       && grep -Fq "'backup_limit' => Arr::get(\$data, 'backup_limit') ?? 0," "$file" \
       && ! grep -Fq "'exp_date' => Arr::get(\$data, 'exp_date') ?? null," "$file"; then
        sed -i "/'backup_limit' => Arr::get(\\\$data, 'backup_limit') ?? 0,/a\\
                'exp_date' => Arr::get(\\\$data, 'exp_date') ?? null," "$file"
    fi

    file="$PTERODACTYL/app/Transformers/Api/Client/ServerTransformer.php"
    backup_file "$file"
    if [[ -f "$file" ]] \
       && grep -Fq "'name' => \$server->name," "$file" \
       && ! grep -Fq "'exp_date' => \$server->exp_date," "$file"; then
        sed -i "/'name' => \\\$server->name,/a\\
                'exp_date' => \$server->exp_date," "$file"
    fi
}

patch_client() {
    local file="$PTERODACTYL/resources/scripts/api/server/getServer.ts"

    [[ -f "$file" ]] || return 0

    backup_file "$file"

    if grep -Fq "name: string;" "$file" \
       && ! grep -Fq "expDate: string;" "$file"; then
        sed -i "/name: string;/a\\
        expDate: string;" "$file"
    fi

    if grep -Fq "name: data.name," "$file" \
       && ! grep -Fq "expDate: data.exp_date," "$file"; then
        sed -i "/name: data.name,/a\\
        expDate: data.exp_date," "$file"
    fi
}

patch_server_details() {
    local file="$PTERODACTYL/resources/scripts/components/server/console/ServerDetailsBlock.tsx"

    [[ -f "$file" ]] || return 0
    backup_file "$file"

    if ! grep -Fq "faCalendarDay" "$file"; then
        grep -Fq "faMicrochip," "$file" || return 0

        sed -i "/faMicrochip,/a\\
        faCalendarDay," "$file"

        if grep -Fq "const limits = ServerContext.useStoreState((state) => state.server.data!.limits);" "$file"; then
            sed -i "/const limits = ServerContext.useStoreState((state) => state.server.data!.limits);/a\\
        const expDate = ServerContext.useStoreState((state) => state.server.data!.expDate);" "$file"
        fi
    fi
}

patch_blades() {
    local file

    file="$PTERODACTYL/resources/views/admin/servers/view/details.blade.php"
    if [[ -f "$file" ]] && ! grep -Fq 'name="exp_date"' "$file"; then
        backup_file "$file"
        if grep -Fq 'Character limits:' "$file"; then
            sed -i '/<p class="text-muted small">Character limits: <code>a-zA-Z0-9_-<\/code> and <code>\[Space\]<\/code>.<\/p>/,/<\/div>/ {
                /<\/div>/ {
                    s|<\/div>|&\
                    <div class="form-group">\
                        <label for="exp_date" class="control-label">Expiration date<\/label>\
                        <input type="date" name="exp_date" value="{{ old('\''exp_date'\'', \$server->exp_date) }}" class="form-control" \/>\
                        <p class="text-muted small">Server akan kadaluarsa (suspend) di akhir hari pada tanggal yang dipilih (kosongkan jika ingin server permanen)<\/p>\
                    <\/div>|
                }
            }' "$file"
        fi
    fi

    file="$PTERODACTYL/resources/views/admin/servers/new.blade.php"
    if [[ -f "$file" ]] && ! grep -Fq 'name="exp_date"' "$file"; then
        backup_file "$file"
        if grep -Fq 'Email address of the Server Owner.' "$file"; then
            sed -i '/<p class="small text-muted no-margin">Email address of the Server Owner.<\/p>/,/<\/div>/ {
                /<\/div>/ {
                    s|<\/div>|&\
\
                        <div class="form-group">\
                            <label for="exp_date">Expiration date<\/label>\
                            <input type="date" class="form-control" id="expiration" name="exp_date" value="{{ old('\''exp_date'\'') }}" placeholder="Expiration Date">\
                            <p class="small text-muted no-margin">Server akan kadaluarsa (suspend) di akhir hari pada tanggal yang dipilih (kosongkan jika ingin server permanen)<\/p>\
                        <\/div>|
                }
            }' "$file"
        fi
    fi
}

migrate_and_build() {
    cd "$PTERODACTYL"

    log "Menjalankan migration database..."
    php artisan migrate --force

    log "Memastikan cross-env tersedia..."
    if ! jq -e '.dependencies["cross-env"] or .devDependencies["cross-env"]' package.json >/dev/null 2>&1; then
        yarn add cross-env
    fi

    log "Menjalankan yarn install..."
    yarn install

    log "Build panel..."
    export NODE_OPTIONS=--openssl-legacy-provider
    yarn run build:production

    log "Membersihkan cache Laravel..."
    for cmd in optimize view config route cache; do
        php artisan "${cmd}:clear"
    done

    chown -R www-data:www-data "$PTERODACTYL"
}

verify() {
    local kernel="$PTERODACTYL/app/Console/Kernel.php"

    grep -Fq "Server::where('exp_date'" "$kernel" \
        || die "Verifikasi gagal: scheduler Auto Suspend tidak ditemukan."

    log "Verifikasi Auto Suspend berhasil."
    log "Backup file tersimpan di: $BACKUP_DIR"
}

main() {
    require_root
    require_panel

    log "Memulai instalasi Auto Suspend..."
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
    verify

    printf '\n'
    log "=============================================="
    log "LXJR OFFC AUTO SUSPEND BERHASIL DIPASANG"
    log "=============================================="
    log "Server yang exp_date-nya sudah lewat akan"
    log "diproses otomatis setiap hari pukul 23:55."
}

main "$@"
