#!/usr/bin/env python3
"""Static guard for the pairing + hash-scanner-only release."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
view = (ROOT / "ios-app/ContentView.swift").read_text()
app_model = (ROOT / "ios-app/AppViewModel.swift").read_text()
info = (ROOT / "ios-app/Info.plist").read_text()
workflow = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()

required = (
    'case english = "en"',
    'case chinese = "zh"',
    'languageRaw = AppLanguage.english.rawValue',
    'Wallet Hash Exporter',
    'Read Wallet directly',
    '直接读取 Wallet',
    'Copy All Hashes',
    '复制全部 Hash',
    'Reading temporarily removes cards from Wallet',
    '读取过程会导致卡片暂时从 Wallet 中消失',
    'Settings › Wallet & Apple Pay › AutoFill Cards',
    '设置 › 钱包与 Apple Pay › 自动填充卡片',
)
for marker in required:
    if marker not in view:
        raise SystemExit(f"missing scanner-only UI marker: {marker}")

for removed in (
    "PasscodeThemeTab",
    "TendiesView",
    "flashCards()",
    "Set Skin",
    "Assign Card Skin",
    "PhotosPicker",
    "NFC",
    "Side button",
    "Tap card",
):
    if removed in view:
        raise SystemExit(f"removed feature returned to UI: {removed}")

for removed in ("flashCards", "passth", "tendie", "wallpaper", "setCardImage"):
    if removed.lower() in app_model.lower():
        raise SystemExit(f"removed feature remains in app model: {removed}")

for deleted_source in (
    "Models.swift",
    "RespringHelper.swift",
    "TendiesEngine.swift",
    "TendiesModel.swift",
    "TendiesView.swift",
    "Utilities.swift",
):
    if (ROOT / "ios-app" / deleted_source).exists():
        raise SystemExit(f"removed feature source still exists: {deleted_source}")

for removed_type in ("NSPhotoLibraryUsageDescription", "com.aircard.passthm", "com.aircard.tendies"):
    if removed_type in info:
        raise SystemExit(f"obsolete release capability remains: {removed_type}")

for marker in ("release/AirCard-Hash-Scanner.ipa", "contents: write", "paths-ignore:"):
    if marker not in workflow:
        raise SystemExit(f"release workflow marker missing: {marker}")

print("Scanner-only bilingual release checks passed")
