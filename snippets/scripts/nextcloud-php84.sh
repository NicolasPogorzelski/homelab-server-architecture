#!/usr/bin/env bash
# Runs inside lxc210 after the Debian 13 upgrade: moves Apache and Nextcloud from PHP 8.2 to 8.4.
# The 8.2 configuration stays on disk as the reference until the 8.2 packages are purged.
set -uo pipefail
OCC() { sudo -u www-data php /var/www/nextcloud/occ "$@"; }

MODS="apcu bcmath cli curl gd gmp igbinary imagick intl mbstring mysql opcache readline redis xml zip"
PKGS="libapache2-mod-php8.4"; for m in $MODS; do PKGS="$PKGS php8.4-$m"; done
DEBIAN_FRONTEND=noninteractive apt-get install -y -q $PKGS >/tmp/php84-install.log 2>&1 \
    || { echo "install failed"; tail -5 /tmp/php84-install.log; exit 1; }

# The values Nextcloud needs, read from the 8.2 Apache php.ini rather than restated.
for k in memory_limit upload_max_filesize post_max_size max_execution_time output_buffering; do
    v=$(grep -E "^$k\s*=" /etc/php/8.2/apache2/php.ini | tail -1 | sed -E 's/^[^=]+=\s*//')
    [ -n "$v" ] && sed -i -E "s|^;?\s*$k\s*=.*|$k = $v|" /etc/php/8.4/apache2/php.ini
done
for sapi in apache2 cli; do
    [ -f /etc/php/8.2/$sapi/conf.d/99-nextcloud-opcache.ini ] && \
        cp -a /etc/php/8.2/$sapi/conf.d/99-nextcloud-opcache.ini /etc/php/8.4/$sapi/conf.d/
done

a2dismod -q php8.2 >/dev/null 2>&1
a2enmod -q php8.4 >/dev/null || { echo "a2enmod php8.4 failed"; exit 1; }
apache2ctl -t 2>&1 | tail -1
systemctl restart apache2 || { echo "apache restart failed"; exit 1; }
update-alternatives --set php /usr/bin/php8.4 >/dev/null 2>&1

echo "php cli: $(php -r 'echo PHP_VERSION;')"
echo "apache php: $(curl -s -H "Host: $(OCC config:system:get overwrite.cli.url | sed -E 's#^https?://##; s#/.*##')" http://127.0.0.1/status.php | head -c 160)"
for k in memory_limit upload_max_filesize post_max_size max_execution_time; do
    printf '  %s=%s\n' "$k" "$(grep -E "^$k\s*=" /etc/php/8.4/apache2/php.ini | sed -E 's/^[^=]+=\s*//')"
done
echo "mariadb: $(mariadb -Nse 'select version()')"
OCC maintenance:mode --off
OCC status --output=json | python3 -c 'import sys,json;d=json.load(sys.stdin);print("occ:",{k:d[k] for k in ("maintenance","needsDbUpgrade","versionstring")})'
