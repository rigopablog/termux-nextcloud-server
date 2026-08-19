# termux-nextcloud-server

Run a full Nextcloud instance (MariaDB + PHP-FPM + nginx) on an Android
phone using Termux, exposed to the internet via a Cloudflare Tunnel, kept
alive across reboots with Termux:Boot.

No root required. Tested on Termux (F-Droid/GitHub build) on Android
(Samsung One UI).

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

## 1. Install packages

```sh
pkg update
pkg install mariadb nginx php php-fpm cronie termux-services cloudflared termux-boot git
sv-enable  # first run sets up the runit service dir
```

## 2. Set up MariaDB

```sh
mysqld_safe --skip-grant-tables &  # first-time init if needed
mysql -u root <<'SQL'
CREATE DATABASE nextcloud;
CREATE USER 'ncadmin'@'localhost' IDENTIFIED BY 'CHANGE_ME';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'ncadmin'@'localhost';
FLUSH PRIVILEGES;
SQL
```

Use a strong, unique password for `ncadmin` — you'll put it in
`config.php` in step 5.

## 3. Install Nextcloud

Download the latest Nextcloud server tarball from
[nextcloud.com/install](https://nextcloud.com/install/) and extract it to
`~/nextcloud`. Create the data directory:

```sh
mkdir -p ~/nextcloud-data
```

Run the web installer (or `occ maintenance:install` from the CLI) to
generate `config/config.php` — this auto-generates `instanceid`,
`passwordsalt`, and `secret`, which is why `scripts/config.sample.php`
here has placeholders instead of real values.

## 4. Configure nginx and PHP-FPM

Copy `scripts/nginx.conf` to `$PREFIX/etc/nginx/nginx.conf`. It listens
on port 8080 and proxies PHP requests to PHP-FPM over a Unix socket at
`$PREFIX/var/run/php-fpm.sock` — make sure your PHP-FPM pool config
(`$PREFIX/etc/php-fpm.d/www.conf`) listens on that same socket path.

## 5. Fill in config.php

Copy `scripts/config.sample.php` to `~/nextcloud/config/config.php` (or
merge the relevant keys into what the installer generated) and replace:

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
  → Battery)
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

## Notes / gotchas

- LAN access requires your phone's LAN IP in `trusted_domains` (step 5)
  — Nextcloud rejects requests to hostnames it doesn't recognize.
- `sv status <service>` reporting `unable to change to service
  directory: file does not exist` right after boot is usually a timing
  race (service dir not yet created) or a device clock hiccup — check
  `~/bin/healthcheck.log` before assuming a real crash.
- Never commit `~/.cloudflared/token`, `config/config.php` (has your DB
  password/secrets), or the contents of `~/nextcloud-data` (your actual
  files) to this or any repo.
