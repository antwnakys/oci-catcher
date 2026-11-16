#!/usr/bin/env python3
"""Derive the server's "cloud" SSH key from the Oracle API key.

GitHub Actions already holds the Oracle API key as a secret. This script turns
it into an SSH key, always the same one, so every workflow can log in to the
server without any extra secret and without the user's Mac.

  cloud_key.py            print the public key
  cloud_key.py PATH       also write the private key to PATH (mode 600)

The private key never appears in logs. The derivation is one-way: the public
key reveals nothing about the Oracle key.
"""
import hashlib
import hmac
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

KEY_FILE = os.path.expanduser(os.environ.get("OCI_KEY_FILE", "~/.oci/key.pem"))

pem = open(KEY_FILE, "rb").read().replace(b"\r\n", b"\n").strip()
if b"PRIVATE KEY" not in pem:
    sys.exit("Oracle API key not found or not a private key")
seed = hmac.new(pem, b"oci-catcher minecraft cloud ssh key v1", hashlib.sha256).digest()
key = Ed25519PrivateKey.from_private_bytes(seed)

if len(sys.argv) > 1:
    path = sys.argv[1]
    os.makedirs(os.path.dirname(os.path.abspath(path)), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.OpenSSH,
                                  serialization.NoEncryption()))

pub = key.public_key().public_bytes(serialization.Encoding.OpenSSH,
                                    serialization.PublicFormat.OpenSSH)
print(pub.decode() + " minecraft-cloud")
