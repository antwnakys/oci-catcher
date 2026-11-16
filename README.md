# oci-catcher

Retries creating an Oracle Cloud Always Free Ampere A1 instance (1 OCPU / 6 GB)
every 120 seconds until capacity is available. Runs on GitHub Actions.

All account details are stored as encrypted repository secrets; nothing secret
is in this repository. When the instance is created, the workflow opens an
issue titled "Server caught" and disables itself.

After a catch, the `set-up-server` workflow sets the server up automatically:
fixed public IP, port 25565 open, Minecraft installed (`deploy.sh`). It logs in
with an SSH key derived from the Oracle API key secret (`cloud_key.py`), so no
extra secret is needed. Read-only test: `gh workflow run set-up-server -f mode=check`.
