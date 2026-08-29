#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Auto Suspend Installer
# Fixed GitHub-ready standalone installer
# ============================================================

PTERODACTYL="/var/www/pterodactyl"
AUTOSUSPEND_URL="https://raw.githubusercontent.com/manziero/Autosp/main/expdate.zip"
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
    [[ -d "$PTERODACTYL" ]] \
        || die "Pterodactyl tidak ditemukan di $PTERODACTYL."

    [[ -f "$PTERODACTYL/artisan" ]] \
        || die "Laravel artisan tidak ditemukan."
}

install_base_packages() {
    log "Memeriksa dependency dasar..."

    export DEBIAN_FRONTEND=noninteractive

    command -v apt-get >/dev/null 2>&1 \
        || die "Script ini membutuhkan apt-get."

    apt-get update
    apt-get install -y ca-certificates curl gnupg unzip wget jq python3
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
        https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor --yes \
        -o /etc/apt/keyrings/nodesource.gpg

    cat >/etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main
EOF

    apt-get update
    apt-get install -y nodejs

    command -v node >/dev/null 2>&1 \
        || die "Node.js gagal diinstal."

    command -v npm >/dev/null 2>&1 \
        || die "npm tidak ditemukan setelah instalasi."
}

install_yarn() {
    if command -v yarn >/dev/null 2>&1; then
        log "Yarn sudah tersedia: $(yarn --version)"
        return
    fi

    log "Menginstal Yarn..."

    npm install -g yarn
    hash -r

    command -v yarn >/dev/null 2>&1 \
        || die "Yarn gagal diinstal."
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

    log "Mengunduh autosuspend.zip..."

    curl -fL \
        "$AUTOSUSPEND_URL" \
        -o "$TMP_DIR/autosuspend.zip"

    [[ -s "$TMP_DIR/autosuspend.zip" ]] \
        || die "Gagal mengunduh autosuspend.zip."

    log "Memeriksa ZIP..."

    unzip -tq "$TMP_DIR/autosuspend.zip" \
        || die "autosuspend.zip rusak atau bukan ZIP yang valid."

    log "Mengekstrak autosuspend.zip..."

    mkdir -p "$TMP_DIR/extracted"

    unzip -oq \
        "$TMP_DIR/autosuspend.zip" \
        -d "$TMP_DIR/extracted"

    local src=""

    # Format 1:
    # extracted/pterodactyl/
    if [[ -d "$TMP_DIR/extracted/pterodactyl" ]]; then
        src="$TMP_DIR/extracted/pterodactyl"
    fi

    # Format 2:
    # extracted/sesuatu/pterodactyl/
    if [[ -z "$src" ]]; then
        src="$(find "$TMP_DIR/extracted" \
            -type d \
            -name "pterodactyl" \
            -print -quit 2>/dev/null || true)"
    fi

    # Format 3:
    # ZIP langsung berisi app/ dan resources/
    if [[ -z "$src" ]]; then
        local kernel_path=""

        kernel_path="$(find "$TMP_DIR/extracted" \
            -type f \
            -path "*/app/Console/Kernel.php" \
            -print -quit 2>/dev/null || true)"

        if [[ -n "$kernel_path" ]]; then
            src="$(dirname "$(dirname "$(dirname "$kernel_path")")")"
        fi
    fi

    [[ -n "$src" && -d "$src" ]] \
        || die "Tidak menemukan struktur Pterodactyl yang valid di autosuspend.zip."

    log "Sumber Auto Suspend ditemukan:"
    log "$src"

    log "Menyalin file Auto Suspend..."

    cp -a "$src/." "$PTERODACTYL/"
}

patch_kernel() {
    local file="$PTERODACTYL/app/Console/Kernel.php"

    [[ -f "$file" ]] \
        || die "Kernel.php tidak ditemukan."

    backup_file "$file"

    log "Memperbaiki Kernel.php..."

    python3 - "$file" <<'PY'
import sys

file = sys.argv[1]

with open(file, "r", encoding="utf-8") as f:
    text = f.read()

# ------------------------------------------------------------
# Add Server model import
# ------------------------------------------------------------

server_import = "use Pterodactyl\\Models\\Server;"

if server_import not in text:
    uuid_import = "use Ramsey\\Uuid\\Uuid;"

    if uuid_import not in text:
        raise SystemExit(
            "Pattern 'use Ramsey\\Uuid\\Uuid;' tidak ditemukan di Kernel.php."
        )

    text = text.replace(
        uuid_import,
        uuid_import + "\n" + server_import,
        1
    )

# ------------------------------------------------------------
# Add Auto Suspend scheduler
# ------------------------------------------------------------

marker = "$schedule->command(CleanServiceBackupFilesCommand::class)->daily();"

scheduler = r"""
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
"""

if "Server::whereNotNull('exp_date')" not in text:
    if marker not in text:
        raise SystemExit(
            "Pattern scheduler Pterodactyl tidak ditemukan di Kernel.php."
        )

    text = text.replace(
        marker,
        marker + "\n" + scheduler,
        1
    )

with open(file, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

patch_backend() {
    local file

    # --------------------------------------------------------
    # ServersController
    # --------------------------------------------------------

    file="$PTERODACTYL/app/Http/Controllers/Admin/ServersController.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if ! grep -Fq "'exp_date'," "$file"; then
            if grep -Fq "'owner_id', 'external_id', 'name', 'description'," "$file"; then
                sed -i \
                    "/'owner_id', 'external_id', 'name', 'description',/a\\
            'exp_date'," \
                    "$file"
            fi
        fi
    fi

    # --------------------------------------------------------
    # StoreServerRequest
    # --------------------------------------------------------

    file="$PTERODACTYL/app/Http/Requests/Api/Application/Servers/StoreServerRequest.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq "'oom_disabled' => 'sometimes|boolean'," "$file"; then
            if ! grep -Fq "'exp_date' => \$rules['exp_date']," "$file"; then
                sed -i \
                    "/'oom_disabled' => 'sometimes|boolean',/a\\
            'exp_date' => \$rules['exp_date']," \
                    "$file"
            fi
        fi

        if grep -Fq "'oom_disabled' => array_get(\$data, 'oom_disabled')," "$file"; then
            if ! grep -Fq "'exp_date' => array_get(\$data, 'exp_date')," "$file"; then
                sed -i \
                    "/'oom_disabled' => array_get(\\\$data, 'oom_disabled'),/a\\
            'exp_date' => array_get(\$data, 'exp_date')," \
                    "$file"
            fi
        fi
    fi

    # --------------------------------------------------------
    # Server model
    # --------------------------------------------------------

    file="$PTERODACTYL/app/Models/Server.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq "'backup_limit' => 'present|nullable|integer|min:0'," "$file"; then
            if ! grep -Fq "'exp_date' => 'sometimes|nullable'," "$file"; then
                sed -i \
                    "/'backup_limit' => 'present|nullable|integer|min:0',/a\\
        'exp_date' => 'sometimes|nullable'," \
                    "$file"
            fi
        fi
    fi

    # --------------------------------------------------------
    # DetailsModificationService
    # --------------------------------------------------------

    file="$PTERODACTYL/app/Services/Servers/DetailsModificationService.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq "'description' => Arr::get(\$data, 'description') ?? ''," "$file"; then
            if ! grep -Fq "'exp_date' => Arr::get(\$data, 'exp_date') ?? null," "$file"; then
                sed -i \
                    "/'description' => Arr::get(\\\$data, 'description') ?? '',/a\\
                'exp_date' => Arr::get(\$data, 'exp_date') ?? null," \
                    "$file"
            fi
        fi
    fi

    # --------------------------------------------------------
    # ServerCreationService
    # --------------------------------------------------------

    file="$PTERODACTYL/app/Services/Servers/ServerCreationService.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq "'backup_limit' => Arr::get(\$data, 'backup_limit') ?? 0," "$file"; then
            if ! grep -Fq "'exp_date' => Arr::get(\$data, 'exp_date') ?? null," "$file"; then
                sed -i \
                    "/'backup_limit' => Arr::get(\\\$data, 'backup_limit') ?? 0,/a\\
                'exp_date' => Arr::get(\$data, 'exp_date') ?? null," \
                    "$file"
            fi
        fi
    fi

    # --------------------------------------------------------
    # ServerTransformer
    # --------------------------------------------------------

    file="$PTERODACTYL/app/Transformers/Api/Client/ServerTransformer.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"

        if grep -Fq "'name' => \$server->name," "$file"; then
            if ! grep -Fq "'exp_date' => \$server->exp_date," "$file"; then
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
    local file

    # --------------------------------------------------------
    # Existing server page
    # --------------------------------------------------------

    file="$PTERODACTYL/resources/views/admin/servers/view/details.blade.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"
    fi

    # --------------------------------------------------------
    # New server page
    # --------------------------------------------------------

    file="$PTERODACTYL/resources/views/admin/servers/new.blade.php"

    if [[ -f "$file" ]]; then
        backup_file "$file"
    fi
}

migrate_and_build() {
    cd "$PTERODACTYL"

    log "Menjalankan migration database..."

    php artisan migrate --force

    log "Memastikan cross-env tersedia..."

    if ! jq -e \
        '.dependencies["cross-env"] or .devDependencies["cross-env"]' \
        package.json >/dev/null 2>&1; then

        yarn add cross-env
    fi

    log "Menjalankan yarn install..."

    yarn install

    log "Build panel..."

    export NODE_OPTIONS=--openssl-legacy-provider

    yarn run build:production

    log "Membersihkan cache Laravel..."

    php artisan optimize:clear

    chown -R www-data:www-data "$PTERODACTYL"
}

verify() {
    local kernel="$PTERODACTYL/app/Console/Kernel.php"

    grep -Fq "Server::whereNotNull('exp_date')" "$kernel" \
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