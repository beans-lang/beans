#!/usr/bin/env python3
"""Create a sorted zip with fixed timestamps and permissions."""

from pathlib import Path
import sys
import zipfile


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make_deterministic_zip.py <root> <output.zip>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        paths = [root, *sorted(root.rglob("*"), key=lambda p: p.as_posix())]
        for path in paths:
            relative = path.relative_to(root.parent).as_posix()
            directory = path.is_dir()
            name = relative + ("/" if directory else "")
            info = zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = ((0o40755 if directory else 0o100755) << 16)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, b"" if directory else path.read_bytes())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
