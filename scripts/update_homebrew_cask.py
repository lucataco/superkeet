#!/usr/bin/env python3

import os
import pathlib
import re
import sys
import tempfile


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: update_homebrew_cask.py <cask-path> <version> <sha256>",
            file=sys.stderr,
        )
        return 1

    cask_path = pathlib.Path(sys.argv[1])
    version = sys.argv[2]
    sha256 = sys.argv[3]

    text = cask_path.read_text()
    updated, version_count = re.subn(
        r'(^\s*version\s+")([^"]+)(")',
        rf"\g<1>{version}\g<3>",
        text,
        flags=re.MULTILINE,
    )
    updated, sha_count = re.subn(
        r'(^\s*sha256\s+")([^"]+)(")',
        rf"\g<1>{sha256}\g<3>",
        updated,
        flags=re.MULTILINE,
    )

    if version_count != 1 or sha_count != 1:
        print(
            f"failed to update {cask_path}: expected one version and one sha256 "
            f"replacement, got version={version_count}, sha256={sha_count}",
            file=sys.stderr,
        )
        return 1

    if updated == text:
        print(f"no changes needed for {cask_path}")
        return 0

    write_atomic(cask_path, updated)
    print(f"updated {cask_path} to {version}")
    return 0


def write_atomic(path: pathlib.Path, content: str) -> None:
    """Write content to path via a temp file in the same directory, then rename.

    A direct write that is interrupted mid-flight would leave a corrupt cask
    file that breaks `brew install` for every tap user. `os.replace` is atomic
    on the same filesystem, so the temp file is created alongside the target.
    """
    dir_path = path.parent
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".update-", suffix=".rb")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise


if __name__ == "__main__":
    raise SystemExit(main())
