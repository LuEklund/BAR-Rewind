#!/usr/bin/env python3
# Usage: tools/dist.py   (or: zig build dist)
# Packs dist/bar-replay-linux.tar.gz and dist/bar-replay-windows.zip: bake built for that OS (baseline
# x86_64, runs on any CPU), the Python app, the dump widget and the BAR Replay mutator.
# Users extract one and run bar-replay (Linux) or bar-replay.bat (Windows). Needs Python 3 and BAR.
import io, shutil, subprocess, tarfile, time, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
FILES = ["tools/pipeline.py", "tools/ui.py", "lua/dump_replay.lua", "README.md", "LICENSE"]
BAT = '@echo off\r\nwhere py >nul 2>nul && (py -3 "%~dp0tools\\ui.py") || (python "%~dp0tools\\ui.py")\r\nif errorlevel 1 pause\r\n'
SH = '#!/bin/sh\nexec python3 "$(dirname "$(realpath "$0")")/tools/ui.py" "$@"\n'


def mutator_files():
    src = ROOT / "recoil/barreplay.sdd"
    return [p for p in src.rglob("*") if p.is_file() and "replay" not in p.relative_to(src).parts[:1]]


def build_bake(target, name):
    out = DIST / "stage" / name
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["zig", "build-exe", str(ROOT / "src/bake.zig"), "-OReleaseFast", "-target", target,
                    "-mcpu=baseline", f"-femit-bin={out}"], check=True, cwd=DIST / "stage")
    return out


def entries(bake, bake_name, launcher, launcher_text):
    """(path inside the package, source path or text, executable)"""
    yield f"bin/{bake_name}", bake, True
    yield launcher, launcher_text, True
    for f in FILES:
        yield f, ROOT / f, f.endswith(".py")
    for p in mutator_files():
        yield p.relative_to(ROOT).as_posix(), p, False


def pack_tar(path, items):
    with tarfile.open(path, "w:gz") as tar:
        for name, src, exe in items:
            data = src.encode() if isinstance(src, str) else Path(src).read_bytes()
            info = tarfile.TarInfo("bar-replay/" + name)
            info.size, info.mode, info.mtime = len(data), 0o755 if exe else 0o644, time.time()
            tar.addfile(info, io.BytesIO(data))


def pack_zip(path, items):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, src, _ in items:
            data = src.encode() if isinstance(src, str) else Path(src).read_bytes()
            z.writestr("bar-replay/" + name, data)


DIST.mkdir(exist_ok=True)
linux = build_bake("x86_64-linux-musl", "bake")
pack_tar(DIST / "bar-replay-linux.tar.gz", entries(linux, "bake", "bar-replay", SH))
windows = build_bake("x86_64-windows-gnu", "bake.exe")
pack_zip(DIST / "bar-replay-windows.zip", entries(windows, "bake.exe", "bar-replay.bat", BAT))
shutil.rmtree(DIST / "stage")
print(DIST / "bar-replay-linux.tar.gz")
print(DIST / "bar-replay-windows.zip")
