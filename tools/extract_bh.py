import re
from pathlib import Path

s = Path(r"c:\Users\heidari-f\Desktop\backhaul-core\backhaul.sh").read_text(
    encoding="utf-8", errors="ignore"
)
parts = re.findall(r"='([^']{3,300})'", s)
# concat adjacent fragments to recover split tokens
joined = "".join(parts)
for token in ("spoof_dst_ip", "spoof_src_ip", "custom_packet", "github.com", "bind_addr", "remote_addr", "[ipx]", "transport"):
    i = joined.find(token)
    print(token, "->", repr(joined[i - 20 : i + 80]) if i >= 0 else "NOT FOUND")

for key in ("spoof", "ipx", "custom", "toml", "config", "github", "backhaul", "tun", "icmp", "transport", "ports", "dst", "src"):
    hits = sorted({p for p in parts if key in p.lower()})
    if hits:
        print(f"=== {key} ===")
        for h in hits:
            print(h)
