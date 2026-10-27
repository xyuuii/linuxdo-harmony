#!/usr/bin/env python3
"""Fetch a short-lived public DNS seed to isolate ECH from on-device DoH reachability.

This is a diagnostic bootstrap, not an application's DNS cache or an ECH success receipt.
Only allowlisted public targets are queried; no credentials or insecure TLS options are used.
"""
import base64
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

if len(sys.argv) != 3 or sys.argv[1] not in ("linux.do", "crypto.cloudflare.com"):
    raise SystemExit("usage: fetch-seed.py linux.do|crypto.cloudflare.com OUTPUT.json")
host = sys.argv[1]

def query(kind):
    uri = "https://cloudflare-dns.com/dns-query?" + urllib.parse.urlencode({"name": host, "type": kind})
    request = urllib.request.Request(uri, headers={"Accept": "application/dns-json"})
    with urllib.request.urlopen(request, timeout=12) as response:
        if response.status != 200:
            raise ValueError("DoH HTTP failure")
        result = json.loads(response.read(65536))
    if result.get("Status") != 0:
        raise ValueError("DNS response was not successful")
    return result.get("Answer", [])

https = query("HTTPS")
address_records = [a for a in query("A") if a.get("type") == 1]
records = [r for r in https if r.get("type") == 65 and r.get("name", "").rstrip(".") == host]
ech = next((m.group(1) for r in records if (m := re.search(r'\bech="?([A-Za-z0-9+/=]+)', r.get("data", "")))), None)
if not ech or not address_records:
    raise SystemExit("No ECH config or IPv4 addresses; refusing a plaintext fallback")
raw = base64.b64decode(ech, validate=True)
if len(raw) < 4:
    raise SystemExit("Invalid ECH config list")
seed = {
    "host": host,
    "fetched_at": int(time.time()),
    "ttl": min(600, *(int(r["TTL"]) for r in records + address_records)),
    "addresses": [r["data"] for r in address_records],
    "ech_config_base64": ech,
    "source": "https://cloudflare-dns.com/dns-query",
}
Path(sys.argv[2]).write_text(json.dumps(seed, indent=2) + "\n")
print(json.dumps({"host": host, "ttl": seed["ttl"], "address_count": len(seed["addresses"]), "ech_config_bytes": len(raw)}))
