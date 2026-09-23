#!/usr/bin/env python3
"""Ensure card discovery never reads or moves live Wallet files."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
view_model = (ROOT / "ios-app/AppViewModel.swift").read_text()
content_view = (ROOT / "ios-app/ContentView.swift").read_text()
rust = (ROOT / "rust-core/src/exploit.rs").read_text()

scan_start = view_model.index("func startCardScanning()")
scan_end = view_model.index("private func startLegacyCardScanning", scan_start)
scan_entry = view_model[scan_start:scan_end]

if "startLegacyCardScanning" not in scan_entry:
    raise SystemExit("card scan must enter the live-log scanner")

for unsafe in ("startWalletMetadataDiscovery", "al_exploit_read_file", "passes23.sqlite"):
    if unsafe in view_model:
        raise SystemExit(f"destructive Wallet metadata scan returned: {unsafe}")

if "/var/mobile/Library/Passes" in scan_entry:
    raise SystemExit("card scan entry touches a live Wallet path")

if (ROOT / "ios-app/WalletMetadataScanner.swift").exists():
    raise SystemExit("obsolete Wallet metadata scanner source still exists")

for marker in (
    "connect_os_trace",
    ".start_trace(None)",
    'connect_service("com.apple.syslog_relay"',
):
    if marker not in rust:
        raise SystemExit(f"missing non-destructive live-log scanner marker: {marker}")

if "Wallet files are never read or moved" not in content_view:
    raise SystemExit("scan safety promise is missing from the UI")

print("Non-destructive scanner checks passed")
