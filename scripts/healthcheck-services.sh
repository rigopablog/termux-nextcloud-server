#!/data/data/com.termux/files/usr/bin/sh
# Run every 5 min via crontab. Restarts any core service that isn't
# running, and keeps a timestamped log so outages can be diagnosed
# after the fact instead of guessed at.
LOG=$HOME/bin/healthcheck.log
echo "== $(date '+%Y-%m-%d %H:%M:%S') ==" >> "$LOG"
for svc in mysqld nginx php-fpm cloudflared crond; do
  status=$(sv status "$svc")
  echo "$status" >> "$LOG"
  echo "$status" | grep -q '^run:' || {
    echo "  -> DOWN, restarting $svc" >> "$LOG"
    sv up "$svc"
  }
done
tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
