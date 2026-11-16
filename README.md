# oci-catcher

Retries creating an Oracle Cloud Always Free Ampere A1 instance (1 OCPU / 6 GB)
every 120 seconds until capacity is available. Runs on GitHub Actions.

All account details are stored as encrypted repository secrets; nothing secret
is in this repository. When the instance is created, the workflow opens an
issue titled "Server caught" and disables itself.
