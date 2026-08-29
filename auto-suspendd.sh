#!/bin/bash
set -e

# Style
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
REVERSE='\033[7m'
HIDDEN='\033[8m'

# Foreground (Text Color Normal)
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'


install_auto_suspend() {
  print_banner "INSTALL FITUR AUTO SUSPEND" "$CYAN"
  echo -e "${BOLD}Fitur ini akan menambahkan fungsionalitas auto-suspend server.${NC}"
  echo -n -e "${BOLD}Lanjutkan instalasi? (y/n): ${NC}"
  read confirmation
  if [[ "$confirmation" != [yY] ]]; then
    echo -e "${BOLD}Instalasi dibatalkan.${NC}"
    return
  fi

  setup_nodejs

  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf -- "$TEMP_DIR"' EXIT
  cd "$TEMP_DIR"

  print_info "Mengunduh file autosuspend.zip..."
  wget -q https://cdn.jsdelivr.net/gh/Bangsano/themeinstaller@main/autosuspend.zip

  print_info "Mengekstrak file..."
  unzip -oq autosuspend.zip || true

  print_info "Menyalin file migrasi database..."
  cp -rf pterodactyl/* /var/www/pterodactyl/

  print_info "Menerapkan modifikasi sistem..."
  cd /var/www/pterodactyl

  sed -i "/use Ramsey\\\\Uuid\\\\Uuid;/a use Pterodactyl\\\\Models\\\\Server;" app/Console/Kernel.php
  if ! grep -q "Server::where('exp_date'" app/Console/Kernel.php; then
    sed -i "/\\\$schedule->command(CleanServiceBackupFilesCommand::class)->daily();/a \\
    \\
        \$schedule->call(function () { \\
            \$servers = Server::where('exp_date', '<', now())->get(); \\
            \$suspensionService = \\\\App::make('Pterodactyl\\\\Services\\\\Servers\\\\SuspensionService'); \\
            foreach (\$servers as \$server) { \\
                if(\$server->status != 'suspended') { \\
                    if(\$server->status != 'installing') { \\
                        if(\$server->exp_date != null) { \\
                            \$suspensionService->toggle(\$server, 'suspend'); \\
                        } \\
                    } \\
                } \\
            } \\
        })->dailyAt('23:55');" app/Console/Kernel.php
  fi

  sed -i "/'owner_id', 'external_id', 'name', 'description',/a \\\t\t\t'exp_date'," app/Http/Controllers/Admin/ServersController.php
  sed -i "/'oom_disabled' => 'sometimes|boolean',/a \\            'exp_date' => \$rules['exp_date']," app/Http/Requests/Api/Application/Servers/StoreServerRequest.php
  sed -i "/'oom_disabled' => array_get(\$data, 'oom_disabled'),/a \\            'exp_date' => array_get(\$data, 'exp_date')," app/Http/Requests/Api/Application/Servers/StoreServerRequest.php
  sed -i "/'backup_limit' => 'present|nullable|integer|min:0',/a \\        'exp_date' => 'sometimes|nullable'," app/Models/Server.php
  sed -i "/'description' => Arr::get(\$data, 'description') ?? '',/a \                'exp_date' => Arr::get(\$data, 'exp_date') ?? null," app/Services/Servers/DetailsModificationService.php
  sed -i "/'backup_limit' => Arr::get(\$data, 'backup_limit') ?? 0,/a \\                'exp_date' => Arr::get(\$data, 'exp_date') ?? null," app/Services/Servers/ServerCreationService.php
  sed -i "/'name' => \$server->name,/a \\                'exp_date' => \$server->exp_date," app/Transformers/Api/Client/ServerTransformer.php

  if [ -f "resources/scripts/api/server/getServer.ts" ]; then
    sed -i "/name: string;/a \\        expDate: string;" resources/scripts/api/server/getServer.ts
    sed -i "/name: data.name,/a \\        expDate: data.exp_date," resources/scripts/api/server/getServer.ts
  fi

  if [ -f "resources/scripts/components/server/console/ServerDetailsBlock.tsx" ]; then
    sed -i "/faMicrochip,/a \\        faCalendarDay," resources/scripts/components/server/console/ServerDetailsBlock.tsx
    sed -i "/const limits = ServerContext.useStoreState((state) => state.server.data!.limits);/a \\        const expDate = ServerContext.useStoreState((state) => state.server.data!.expDate);" resources/scripts/components/server/console/ServerDetailsBlock.tsx

    sed -i -e '/<StatBlock icon={faMicrochip} title={'\''CPU Load'\''} color={getBackgroundColor(stats.cpu, limits.cpu)}>/{x;p;x;}' \
           -e '\%<StatBlock icon={faMicrochip} title={'\''CPU Load'\''} color={getBackgroundColor(stats.cpu, limits.cpu)}>%'"{s%^%\t\t\t<StatBlock icon={faCalendarDay} title={'Expiration Date'}>\n\t\t\t\t{expDate ? expDate : 'Unlimited'}\n\t\t\t<\/StatBlock>\n%}" resources/scripts/components/server/console/ServerDetailsBlock.tsx
  fi

  TARGET_BLADE="resources/views/admin/servers/view/details.blade.php"
  if [ -f "$TARGET_BLADE" ] && ! grep -q "exp_date" "$TARGET_BLADE"; then
    sed -i "/<p class=\"text-muted small\">Character limits: <code>a-zA-Z0-9_-<\/code> and <code>\[Space\]<\/code>.<\/p>/,/<\/div>/ {
      /<\/div>/ {
      s|<\/div>|&\n                    <div class=\"form-group\">\n                        <label for=\"exp_date\" class=\"control-label\">Expiration date<\/label>\n                        <input type=\"date\" name=\"exp_date\" value=\"{{ old('exp_date', \$server->exp_date) }}\" class=\"form-control\" \/>\n                        <p class=\"text-muted small\">Server akan kadaluarsa (suspend) di akhir hari pada tanggal yang dipilih (kosongkan jika ingin server permanen)<\/p>\n                    <\/div>|
      }
    }" "$TARGET_BLADE"
  fi

  TARGET_NEW="resources/views/admin/servers/new.blade.php"
  if [ -f "$TARGET_NEW" ] && ! grep -q "exp_date" "$TARGET_NEW"; then
    sed -i "/<p class=\"small text-muted no-margin\">Email address of the Server Owner.<\/p>/,/<\/div>/ {
      /<\/div>/ {
      s|<\/div>|&\n\n\t\t\t\t\t\t<div class=\"form-group\">\n\t\t\t\t\t\t\t<label for=\"exp_date\">Expiration date<\/label>\n\t\t\t\t\t\t\t<input type=\"date\" class=\"form-control\" id=\"expiration\" name=\"exp_date\" value=\"{{ old('exp_date') }}\" placeholder=\"Expiration Date\">\n\t\t\t\t\t\t\t<p class=\"small text-muted no-margin\">Server akan kadaluarsa (suspend) di akhir hari pada tanggal yang dipilih (kosongkan jika ingin server permanen)<\/p>\n\t\t\t\t\t\t<\/div>|
      }
    }" "$TARGET_NEW"
  fi

  print_info "Menjalankan migrasi database..."
  php artisan migrate --force

  print_info "Menginstal dependensi build..."
  MISSING_PKGS=""
  for pkg in cross-env; do
    jq -e ".dependencies[\"$pkg\"] or .devDependencies[\"$pkg\"]" package.json > /dev/null || MISSING_PKGS="$MISSING_PKGS $pkg"
  done
  [ -n "$MISSING_PKGS" ] && yarn add $MISSING_PKGS
  yarn install

  print_info "Membangun ulang aset panel..."
  export NODE_OPTIONS=--openssl-legacy-provider
  yarn run build:production

  clear_artisan_cache
  chown -R www-data:www-data /var/www/pterodactyl

  print_banner "LXJR OFFC FITUR AUTO SUSPEND BERHASIL DIPASANG" "$GREEN"
  sleep 3
  return 0
}