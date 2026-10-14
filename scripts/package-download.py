"""Package an unsigned iPhone build without publishing device signing profiles."""
import hashlib
import json
import plistlib
import sys
import zipfile
from pathlib import Path

app, output = map(Path, sys.argv[1:])
info = plistlib.loads((app / "Info.plist").read_bytes())
files = sorted(path for path in app.rglob("*") if path.is_file())
if any(path.name == "embedded.mobileprovision" or "_CodeSignature" in path.parts for path in files):
    raise SystemExit("Refusing to publish a signed build or provisioning profile. Build with CODE_SIGNING_ALLOWED=NO.")
output.mkdir(parents=True, exist_ok=True)
ipa = output / "Follow-unsigned.ipa"
with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, str(Path("Payload/Follow.app") / path.relative_to(app)))
receipt = {
    "file": ipa.name,
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "minimumIOS": info["MinimumOSVersion"],
    "signing": "unsigned; sign for your device before installing",
    "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
    "bytes": ipa.stat().st_size,
}
(output / "download.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
