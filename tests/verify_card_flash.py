#!/usr/bin/env python3
"""Static regression guard for the verified macOS Wallet flash behavior."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(source: str, needle: str, label: str) -> None:
    if needle not in source:
        raise SystemExit(f"missing {label}: {needle}")


models = (ROOT / "ios-app/Models.swift").read_text()
view_model = (ROOT / "ios-app/AppViewModel.swift").read_text()
rust = (ROOT / "rust-core/src/exploit.rs").read_text()
ffi = (ROOT / "rust-core/src/lib.rs").read_text()
header = (ROOT / "rust-core/include/airlift.h").read_text()

for asset in (
    '"cardBackgroundCombined@3x.png": pngData',
    '"cardBackgroundCombined@2x.png": pngData',
    'skins["cardBackgroundCombined.pdf"] = pdfData',
):
    require(models, asset, "three-file artwork pipeline")

for obsolete in (
    'skins["diffuse@',
    'skins["background@',
    'skins["strip@',
    'skins["background.pdf"]',
    'skins["strip.pdf"]',
):
    if obsolete in models:
        raise SystemExit(f"obsolete Wallet artwork variant returned: {obsolete}")

if 'Data("corrupted".utf8)' in view_model:
    raise SystemExit("Wallet cache regression: corrupt-byte overwrite returned")

require(view_model, 'for ext in [".cache", ".pkcache"]', "both Wallet cache roots")
require(view_model, '"FrontFace,PlaceHolder,Preview"', "three rendered cache leaves")
require(view_model, "al_exploit_remove_files", "Swift remove FFI call")
require(rust, 'format!("../../{link_destination}/{leaf}")', "protected move identifier")
require(rust, 'format!("{source}/removed-{index}")', "moved-file destination")
require(rust, "afc.remove_all(&source).await", "moved staging deletion")
require(ffi, "pub unsafe extern \"C\" fn al_exploit_remove_files", "Rust C export")
require(header, "int32_t al_exploit_remove_files", "public C declaration")

print("Wallet flash parity checks passed")
