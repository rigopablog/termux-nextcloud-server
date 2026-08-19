#!/data/data/com.termux/files/usr/bin/bash
# Runs via Termux:Boot at device boot. Acquires a wake lock and enables
# the core services under termux-services (runit).
termux-wake-lock
export SVDIR=/data/data/com.termux/files/usr/var/service
sv-enable mysqld
sv-enable nginx
sv-enable php-fpm
sv-enable crond
sv-enable cloudflared
