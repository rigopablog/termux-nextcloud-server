# termux-nextcloud-server

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Termux/Android](https://img.shields.io/badge/platform-Termux%20%2F%20Android-3DDC84.svg)](https://termux.dev)

Run a full Nextcloud instance (MariaDB + PHP-FPM + nginx) on an Android
phone using Termux, exposed to the internet via a Cloudflare Tunnel, kept
alive across reboots with Termux:Boot.

No root required. Tested on Termux (F-Droid/GitHub build) on Android
(Samsung One UI).

## Contents

- [Stack](#stack)
- [Prerequisites](#prerequisites)
- [1. Install packages](#1-install-packages)
- [2. Set up MariaDB](#2-set-up-mariadb)
- [3. Install Nextcloud](#3-install-nextcloud)
- [4. Configure nginx and PHP-FPM](#4-configure-nginx-and-php-fpm)
- [5. Fill in config.php](#5-fill-in-configphp)
- [6. Enable the services](#6-enable-the-services)
- [7. Expose it with a Cloudflare Tunnel](#7-expose-it-with-a-cloudflare-tunnel)
- [8. Auto-start on boot (Termux:Boot)](#8-auto-start-on-boot-termuxboot)
- [9. Health check (self-healing + diagnostics)](#9-health-check-self-healing--diagnostics)
- [Repo layout](#repo-layout)
- [Troubleshooting](#troubleshooting)

## Stack

| Component | Role |
|---|---|
| MariaDB (`mysqld`) | Nextcloud database |
| PHP-FPM | Runs Nextcloud's PHP |
| nginx | Web server, listens on port 8080 |
| crond | Runs Nextcloud's background cron job every 5 min |
| cloudflared | Named Cloudflare Tunnel, exposes the server without opening router ports |
| termux-services (runit) | Supervises all of the above, restarts them if they crash |
| Termux:Boot | Starts everything automatically when the phone boots |

## Prerequisites

- **Termux** installed from [F-Droid](https://f-droid.org/packages/com.termux/)
  or [GitHub releases](https://github.com/termux/termux-app/releases) — not
  the Play Store build, which is unmaintained and package installs will
  fail.
- A free [Cloudflare](https://dash.cloudflare.com/) account with a domain
  added to it, if you want remote access (step 7). Skip step 7 if
  LAN-only access is enough.
- Grant Termux storage access once, up front:

  ```sh
  termux-setup-storage
  ```

## 1. Install packages

```sh
pkg update
pkg install mariadb nginx php php-fpm cronie termux-services cloudflared termux-boot git
sv-enable  # first run sets up the runit service dir
```

## 2. Set up MariaDB

Initialize the data directory (first time only), then start it and
create the Nextcloud database:

```sh
mariadb-install-db --datadir=$PREFIX/var/lib/mysql
mysqld_safe --skip-grant-tables &  # temporary, just for the setup below
mysql -u root <<'SQL'
CREATE DATABASE nextcloud;
CREATE USER 'ncadmin'@'localhost' IDENTIFIED BY 'CHANGE_ME';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'ncadmin'@'localhost';
FLUSH PRIVILEGES;
SQL
```

Use a strong, unique password for `ncadmin` — you'll put it in
`config.php` in step 5. Once step 6 enables `mysqld` as a supervised
service, kill this temporary `mysqld_safe` process.

## 3. Install Nextcloud

Download the latest Nextcloud server tarball from
[nextcloud.com/install](https://nextcloud.com/install/) and extract it to
`~/nextcloud`. Create the data directory:

```sh
mkdir -p ~/nextcloud-data
```

Install from the CLI with `occ` (this generates `config/config.php`,
including the auto-generated `instanceid`, `passwordsalt`, and `secret`
— which is why `scripts/config.sample.php` here has placeholders instead
of real values):

```sh
php ~/nextcloud/occ maintenance:install \
  --database "mysql" \
  --database-name "nextcloud" \
  --database-user "ncadmin" \
  --database-pass "CHANGE_ME" \
  --data-dir "$HOME/nextcloud-data" \
  --admin-user "admin" \
  --admin-pass "CHANGE_ME_TOO"
```

## 4. Configure nginx and PHP-FPM

Copy `scripts/nginx.conf` to `$PREFIX/etc/nginx/nginx.conf`. It listens
on port 8080 and proxies PHP requests to PHP-FPM over a Unix socket.

In `$PREFIX/etc/php-fpm.d/www.conf`, make sure the `listen` directive
matches the socket path nginx expects:

```ini
listen = /data/data/com.termux/files/usr/var/run/php-fpm.sock
```

Everything else in that file can stay at its packaged defaults.

## 5. Fill in config.php

Copy `scripts/config.sample.php` to `~/nextcloud/config/config.php` (or
merge the relevant keys into what `occ maintenance:install` generated in
step 3) and replace:

- `<YOUR_DB_PASSWORD>` — the MariaDB password from step 2
- `<YOUR_LAN_IP>` / `<YOUR_PUBLIC_DOMAIN>` in `trusted_domains` — add
  your phone's LAN IP so devices on your home network can reach it, and
  your public domain once the tunnel (step 7) is set up

## 6. Enable the services

```sh
sv-enable mysqld
sv-enable nginx
sv-enable php-fpm
sv-enable crond
crontab scripts/crontab.sample
```

Verify locally:

```sh
curl -I http://127.0.0.1:8080/status.php   # expect HTTP/1.1 200 OK
```

## 7. Expose it with a Cloudflare Tunnel

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/),
create a named tunnel and point a hostname (e.g. `cloud.example.com`) at
`http://localhost:8080`. Save the tunnel token to `~/.cloudflared/token`
(this file is **not** included here — it's a live credential, generate
your own from the dashboard).

```sh
mkdir -p ~/.cloudflared
echo 'YOUR_TUNNEL_TOKEN' > ~/.cloudflared/token
chmod 600 ~/.cloudflared/token
```

Install the runit service:

```sh
mkdir -p $PREFIX/var/service/cloudflared
cp scripts/cloudflared-run $PREFIX/var/service/cloudflared/run
chmod +x $PREFIX/var/service/cloudflared/run
sv-enable cloudflared
```

Add your tunnel hostname to `trusted_domains` in `config.php` (step 5).

## 8. Auto-start on boot (Termux:Boot)

Install the [Termux:Boot](https://f-droid.org/packages/com.termux.boot/)
app (must be installed separately, same signing source as your Termux
app — both from F-Droid or both from GitHub, not mixed).

```sh
mkdir -p ~/.termux/boot
cp scripts/start-nextcloud.sh ~/.termux/boot/start-nextcloud.sh
chmod +x ~/.termux/boot/start-nextcloud.sh
```

Reboot the phone once to confirm Termux:Boot fires the script and all
services come up (`sv status` under `$PREFIX/var/service`).

### Keeping it alive on Android

Android's battery management will kill background apps, including
Termux, which takes every child service down with it. To prevent that:

- Grant Termux **unrestricted battery usage** (Settings → Apps → Termux
  → Battery), and explicitly enable **"Allow background activity"**
- On Samsung/One UI specifically, also check **Settings → Battery and
  device care → Battery → Background usage limits** and make sure
  Termux/Termux:Boot are not in "Sleeping apps" / "Deep sleeping apps"
- Disable Termux from "Put unused apps to sleep" auto-management

This is inherently fragile on stock Android — a dedicated Linux box
(Raspberry Pi, old PC) avoids this class of problem entirely if you
outgrow phone-as-server.

## 9. Health check (self-healing + diagnostics)

```sh
mkdir -p ~/bin
cp scripts/healthcheck-services.sh ~/bin/healthcheck-services.sh
chmod +x ~/bin/healthcheck-services.sh
```

Already included in `scripts/crontab.sample` (step 6) — runs every 5
minutes, restarts any service that isn't `run:`, and logs a timestamped
snapshot to `~/bin/healthcheck.log` so you can see exactly what died and
when, instead of guessing after the fact.

## Repo layout

```
.
├── README.md
├── LICENSE
└── scripts/
    ├── start-nextcloud.sh        # Termux:Boot entrypoint (step 8)
    ├── healthcheck-services.sh   # cron self-healing + logging (step 9)
    ├── nginx.conf                # full nginx config (step 4)
    ├── config.sample.php         # redacted Nextcloud config.php (step 5)
    ├── cloudflared-run           # runit run-script for the tunnel (step 7)
    └── crontab.sample            # Nextcloud cron + healthcheck entries
```

## Troubleshooting

- **LAN devices can't reach it**: add your phone's LAN IP to
  `trusted_domains` in `config.php` (step 5) — Nextcloud rejects requests
  to hostnames/IPs it doesn't recognize with a 400 error.
- **`sv status <service>` says `unable to change to service directory:
  file does not exist`**: usually a timing race right after boot (the
  service dir isn't created yet) or a transient device clock hiccup.
  Check `~/bin/healthcheck.log` — if the 5-minute timestamps keep
  advancing normally, the service came back on its own and this wasn't
  a real crash.
- **Everything dies together a few minutes after boot**: that's Android
  killing the whole Termux process, not a service crash (all child
  processes die at once). Revisit the battery/background-activity
  settings in step 8.
- **`php-fpm` won't start / nginx 502s**: check that the `listen` socket
  path in `$PREFIX/etc/php-fpm.d/www.conf` (step 4) exactly matches the
  `upstream php-handler` path in `nginx.conf`.
- **Nextcloud cron isn't running background jobs**: confirm
  `crontab -l` shows both lines from `scripts/crontab.sample`, and that
  `crond` shows `run:` in `sv status crond`.

## Security notes

Never commit `~/.cloudflared/token`, `config/config.php` (has your DB
password/secrets), or the contents of `~/nextcloud-data` (your actual
files) to this or any repo. `scripts/config.sample.php` and this README
are the only things meant to be shared.
