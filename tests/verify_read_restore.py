#!/usr/bin/env python3
"""Prevent the AirTraffic read primitive from becoming a destructive move."""

from pathlib import Path


source = (Path(__file__).resolve().parents[1] / "rust-core/src/exploit.rs").read_text()
function_start = source.index("async fn exploit_read_file(")
function_end = source.index("async fn exploit_remove_files(", function_start)
read_impl = source[function_start:function_end]

restore_call = read_impl.index("exploit_write_single_file(")
conditional_cleanup = read_impl.index("if operation.is_ok()")
recovered_cleanup = read_impl.index("afc.remove(&recovered).await", conditional_cleanup)

if not restore_call < conditional_cleanup < recovered_cleanup:
    raise SystemExit("read restore must complete before recovered backup cleanup")

required = (
    "for attempt in 1..=3",
    "original source restored successfully",
    "source restore failed; original bytes retained",
    "preserving emergency backup",
)
for marker in required:
    if marker not in read_impl:
        raise SystemExit(f"missing safe-read marker: {marker}")

print("AirTraffic read restore checks passed")
