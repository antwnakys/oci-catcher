#!/usr/bin/env bash
# Daily world backup. Keeps 7 on the server; if the "gdrive" rclone remote
# exists, also uploads to Google Drive and keeps the newest 3 there.
set -euo pipefail

MC_DIR="/opt/minecraft"
BACKUP_DIR="$MC_DIR/backups"
KEEP_LOCAL=7
KEEP_DRIVE=3
DRIVE_REMOTE="gdrive:Minecraft Backups"
RCON="python3 $MC_DIR/rcon.py"
STAMP="$(date +%Y-%m-%d_%H-%M)"
FILE="$BACKUP_DIR/world_$STAMP.tar.gz"

server_up() { $RCON "list" >/dev/null 2>&1; }

if server_up; then
  $RCON "say Backup starting, a small lag spike is possible..." >/dev/null || true
  $RCON "save-off" >/dev/null
  $RCON "save-all flush" >/dev/null
  sleep 5
fi

restore_saving() { server_up && $RCON "save-on" >/dev/null || true; }
trap restore_saving EXIT

cd "$MC_DIR"
WORLDS=$(ls -d world world_nether world_the_end 2>/dev/null || true)
tar -czf "$FILE.part" $WORLDS plugins server.properties whitelist.json ops.json 2>/dev/null || tar -czf "$FILE.part" $WORLDS
mv "$FILE.part" "$FILE"

restore_saving
trap - EXIT
server_up && $RCON "say Backup done." >/dev/null || true

# Keep only the newest KEEP_LOCAL backups on the server
ls -1t "$BACKUP_DIR"/world_*.tar.gz | tail -n +$((KEEP_LOCAL + 1)) | xargs -r rm -f

# Google Drive copy (only if set up)
if rclone listremotes 2>/dev/null | grep -q '^gdrive:$'; then
  rclone copy "$FILE" "$DRIVE_REMOTE"
  rclone lsf "$DRIVE_REMOTE" --files-only | grep '^world_.*\.tar\.gz$' | sort -r | tail -n +$((KEEP_DRIVE + 1)) | while read -r old; do
    rclone deletefile "$DRIVE_REMOTE/$old"
  done || true
fi

echo "Backup saved: $FILE ($(du -h "$FILE" | cut -f1))"
