#!/usr/bin/env python3
# Usage: pipeline.py replay <demo.sdfz>   parse once (cached), then play
#        pipeline.py parse <demo.sdfz>    parse only
#        pipeline.py play <demo.sdfz> [camera.json shot.png]   (parsed before)
# The whole pipeline, Linux and Windows, Python stdlib only:
#   parse: BAR's headless engine re-simulates the replay with lua/dump_replay.lua -> dump -> bake -> .curves
#   play:  bake export-lua -> the BAR Replay mutator, copied into BAR's games/ folder -> BAR starts
# Settings (BAR data folder, out folder) live in config_path(); the CLI and the app share them.
# Shot mode (camera.json from BAR, out.png): jumps to the camera's frame, screenshots and quits;
# SHOT_UI=1 keeps the interface, SHOT_SEEK / SHOT_LEAD / SHOT_SPEED / SHOT_BENCH tune it.
import gzip, json, os, re, shutil, struct, subprocess, sys, time, zipfile, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WINDOWS = os.name == "nt"
EXE = ".exe" if WINDOWS else ""
MUTATOR = ROOT / "recoil" / "barreplay.sdd"
WIDGET = ROOT / "lua" / "dump_replay.lua"


# settings ----------------------------------------------------------------------------------------

def config_path():
    base = os.environ.get("APPDATA") if WINDOWS else os.environ.get("XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / "bar-replay.json"


# where BAR keeps its data (engine/, games/, maps/, demos/) on each kind of install
def bar_candidates():
    home = Path.home()
    if WINDOWS:
        local = Path(os.environ.get("LOCALAPPDATA", home / "AppData/Local"))
        return [local / "Programs/Beyond-All-Reason/data", Path("C:/Program Files/Beyond-All-Reason/data"),
                home / "Documents/Beyond All Reason"]
    return [home / ".var/app/info.beyondallreason.bar/data",  # Flatpak
            home / ".local/state/Beyond All Reason",  # AppImage
            home / "Documents/Beyond All Reason"]


def bar_ok(path):
    return bool(path) and any(Path(path, "engine").glob("recoil_*"))


def load_config():
    try:
        cfg = json.loads(config_path().read_text())
    except (OSError, ValueError):
        cfg = {}
    if not bar_ok(cfg.get("bar_data")):
        found = next((p for p in bar_candidates() if bar_ok(p)), None)
        cfg["bar_data"] = str(found or cfg.get("bar_data") or bar_candidates()[0])
    cfg.setdefault("out_dir", str(ROOT / "out"))
    return cfg


def save_config(cfg):
    config_path().parent.mkdir(parents=True, exist_ok=True)
    config_path().write_text(json.dumps(cfg, indent=2) + "\n")


def engine_dir(bar):
    return sorted(Path(bar, "engine").glob("recoil_*"))[-1]


def bake_exe():
    for p in (ROOT / "bin" / ("bake" + EXE), ROOT / "zig-out" / "bin" / ("bake" + EXE)):
        if p.exists():
            return p
    raise SystemExit("no bake binary: run `zig build` first")


def open_folder(path):
    Path(path).mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        os.startfile(path)
    else:
        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", str(path)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# demo files (.sdfz): gzip, a header, the start script, then the packet stream ---------------------

def demo_load(path):
    b = gzip.open(path).read()
    head = struct.unpack_from("<i", b, 20)[0]
    script, stream = struct.unpack_from("<ii", b, 304)
    return b, head, script, stream


def demo_script(path):
    b, head, script, _ = demo_load(path)
    return b[head:head + script].decode(errors="replace")


def script_field(text, key):
    m = re.search(rf"(?im)^\s*{key}=([^;]*)", text)
    return m.group(1) if m else "?"


# the last keyframe packet: the header's length stays 0 when a game crashed or was quit, and the
# engine then keeps simulating past the end of the recording
def demo_last_frame(path):
    b, head, script, stream = demo_load(path)
    end = head + script + stream if stream else len(b)
    i, last = head + script, 0
    while i + 8 <= end:
        _time, size = struct.unpack_from("<fI", b, i)
        i += 8
        if size >= 5 and i + size <= end and b[i] == 1:  # NETMSG_KEYFRAME: id byte, int32 frame
            last = struct.unpack_from("<i", b, i + 1)[0]
        i += size
    return last


def demo_info(path):
    """{game, map, players, length} or None for an unreadable file."""
    try:
        text = demo_script(path)
        secs = demo_last_frame(path) // 30
    except Exception:
        return None
    players = [script_field(body, "name") for body in re.findall(r"(?i)\[(?:player|ai)\d+\]\s*\{([^{}]*)\}", text)
               if script_field(body, "spectator") != "1"]
    return {"game": script_field(text, "gametype"), "map": script_field(text, "mapname"), "players": players,
            "length": f"{secs // 60}:{secs % 60:02}"}


# parse -------------------------------------------------------------------------------------------

def curves_path(cfg, demo):
    return Path(cfg["out_dir"], "curves", Path(demo).stem + ".curves")


def parse(cfg, demo):
    """Generator: yields ("proc", Popen) once (kill it to cancel), then ("progress", pct, text).
    Leaves <out>/curves/<name>.curves; raises RuntimeError with the log path on failure."""
    bar, demo = Path(cfg["bar_data"]), Path(demo).resolve()
    if script_field(demo_script(demo), "gametype").startswith("BAR Replay"):
        raise RuntimeError(f"{demo.name} is a recording of this player, not a match")
    curves = curves_path(cfg, demo)
    curves.parent.mkdir(parents=True, exist_ok=True)
    # ponytail: cache keyed by file name only; delete <out>/curves/ after a curves format change
    if curves.exists():
        yield "progress", 100, "cached"
        return
    total = demo_last_frame(demo)
    log = curves.parent / "dump.log"
    widget = bar / "LuaUI" / "Widgets" / WIDGET.name
    widget.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(WIDGET, widget)
    for f in ("bardump.jsonl", "bardump.bin"):
        (bar / f).unlink(missing_ok=True)
    # the widget stops at the replay's last frame (an unfinished replay never reaches GameOver)
    (bar / "bardump.request").write_text(f"dump {total}\n")
    engine = engine_dir(bar)
    headless = engine / ("spring-headless" + EXE)
    exe = headless if headless.exists() else engine / ("spring" + EXE)
    yield "progress", 0, f"loading BAR ({total // 1800} min of game)"
    try:
        with open(log, "w") as out:
            # ponytail: 2h timeout covers any real match at headless speed; raise it if a dump gets cut off
            proc = subprocess.Popen([str(exe), "--write-dir", str(bar), "--isolation", str(demo)], stdout=out,
                                    stderr=subprocess.STDOUT, **new_group())
            yield "proc", proc
            started, shown = time.time(), -1
            while proc.poll() is None:
                if time.time() - started > 7200:
                    proc.kill()
                time.sleep(1)
                frame = last_dump_frame(log) or last_dump_frame(bar / "infolog.txt")
                pct = frame * 100 // total if frame and total else -1
                if pct > shown:
                    shown = pct
                    yield "progress", pct, f"parsing {pct}%"
        if proc.returncode < 0 or not (bar / "bardump.jsonl").exists():
            raise RuntimeError(f"parse failed (engine exit {proc.returncode}), see {log}")
        yield "progress", 100, "baking"
        tmp = curves.with_suffix(".jsonl")
        shutil.move(bar / "bardump.jsonl", tmp)
        shutil.move(bar / "bardump.bin", tmp.with_suffix(".bin"))
        r = subprocess.run([str(bake_exe()), str(tmp), str(curves)], capture_output=True, text=True)
        with open(log, "a") as out:
            out.write(r.stdout + r.stderr)
        tmp.unlink(missing_ok=True)
        tmp.with_suffix(".bin").unlink(missing_ok=True)
        if r.returncode != 0:
            curves.unlink(missing_ok=True)
            raise RuntimeError(f"bake failed, see {log}")
    finally:
        (bar / "bardump.request").unlink(missing_ok=True)
        widget.unlink(missing_ok=True)
    yield "progress", 100, "parsed"


def last_dump_frame(log):
    try:
        with open(log, "rb") as f:
            f.seek(max(0, f.seek(0, 2) - 65536))
            hits = re.findall(rb"Replay Dump v2: frame (\d+)", f.read())
    except OSError:
        return None
    return int(hits[-1]) if hits else None


# a process group of its own: cancelling kills the engine, not the app
def new_group():
    return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WINDOWS else {"start_new_session": True}


# play --------------------------------------------------------------------------------------------

def newest_game(bar):
    """The archive name rapid's byar:test tag points at, e.g. 'Beyond All Reason test-31422-df3633c'."""
    for versions in Path(bar, "rapid").glob("*/byar/versions.gz"):
        for line in gzip.open(versions).read().decode().splitlines():
            tag, _md5, _dep, name = line.split(",", 3)
            if tag == "byar:test":
                return name
    raise RuntimeError("no BAR game installed (no byar:test in rapid versions)")


def start_script(meta, replay_script):
    """BAR start script for a local spectator game with the replay's map, teams and options."""
    def section(name):
        m = re.search(r"(?is)\[" + name + r"\]\s*\{(.*?)\}", replay_script)
        return ["\t\t" + l.strip() for l in (m.group(1) if m else "").splitlines() if l.strip()]
    mapname = re.search(r'map = "([^"]*)"', meta).group(1)
    teams = re.findall(r'\[(\d+)\] = \{ color = \{ ([\d.]+), ([\d.]+), ([\d.]+) \}, ally = (-?\d+)', meta)
    ids = sorted(int(t[0]) for t in teams)
    players = [t for t in teams if int(t[0]) != ids[-1]]  # highest team is Gaia
    out = ["[GAME]", "{", f"\tMapName={mapname};", "\tGameType=BAR Replay dev;", "\tIsHost=1;", "\tOnlyLocal=1;",
           "\tMyPlayerName=viewer;", "\tStartPosType=0;", "\tRecordDemo=0;",
           "\t[PLAYER0]", "\t{", "\t\tName=viewer;", "\t\tSpectator=1;", "\t}"]
    # the replay's own allyteams (numbered densely): weapons can only aim at enemies. Nothing fires:
    # the gadget locks every weapon's reload. NullAI holds each team.
    allies = sorted({int(t[4]) for t in players})
    for tid, r, g, b, ally in sorted(players, key=lambda t: int(t[0])):
        out += [f"\t[TEAM{tid}]", "\t{", "\t\tTeamLeader=0;", f"\t\tAllyTeam={allies.index(int(ally))};",
                f"\t\tRGBColor={r} {g} {b};", "\t}",
                f"\t[AI{tid}]", "\t{", "\t\tShortName=NullAI;", f"\t\tTeam={tid};", "\t\tHost=0;", f"\t\tName=team{tid};", "\t}"]
    for i in range(len(allies)):
        out += [f"\t[ALLYTEAM{i}]", "\t{", "\t}"]
    out += ["\t[MODOPTIONS]", "\t{"] + section("modoptions") + ["\t}", "\t[MAPOPTIONS]", "\t{"] + section("mapoptions") + ["\t}", "}"]
    return "\n".join(out) + "\n"


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{" + ", ".join(lua_value(x) for x in v) + "}"
    return "{" + ", ".join(f"[{json.dumps(k)}] = {lua_value(x)}" for k, x in v.items()) + "}"


def play(cfg, demo, shot=None):
    """Starts BAR on the demo's parsed curves and returns its Popen; the caller waits. `shot` =
    {"camera": json path, "png": out path} plays shot mode. The engine's output goes to <out>/play.log."""
    bar, out_dir, curves = Path(cfg["bar_data"]), Path(cfg["out_dir"]), curves_path(cfg, demo)
    out_dir.mkdir(parents=True, exist_ok=True)
    # a copy, not a link: Windows needs admin rights for symlinks
    game = bar / "games" / MUTATOR.name
    if game.is_symlink() or game.is_file():
        game.unlink()
    elif game.exists():
        shutil.rmtree(game)
    shutil.copytree(MUTATOR, game, ignore=shutil.ignore_patterns("replay"))
    r = subprocess.run([str(bake_exe()), "export-lua", str(curves), str(game / "replay")], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("export failed: " + r.stdout + r.stderr)
    # the replay's own start script gives the game version and options it ran with
    replay_script = demo_script(demo)
    gametype = script_field(replay_script, "gametype")
    version = gametype if gametype != "?" and not gametype.startswith("BAR Replay") else newest_game(bar)
    modinfo = game / "modinfo.lua"
    modinfo.write_text(re.sub(r"depend = \{.*\}", f'depend = {{ "{version}" }}', modinfo.read_text()))
    play_script = out_dir / "play_script.txt"
    play_script.write_text(start_script((game / "replay" / "meta.lua").read_text(), replay_script))
    if shot:
        cam = json.loads(Path(shot["camera"]).read_text())
        extra = "".join(f", {k} = {lua_value(conv(os.environ[env]))}" for k, env, conv in (
            ("ui", "SHOT_UI", bool), ("seek", "SHOT_SEEK", int), ("lead", "SHOT_LEAD", int),
            ("bench", "SHOT_BENCH", bool), ("speed", "SHOT_SPEED", float)) if os.environ.get(env))
        (game / "replay" / "shot.lua").write_text(f"return {{ frame = {cam['frame']}, state = {lua_value(cam['state'])}{extra} }}\n")
    log = open(out_dir / "play.log", "w")
    return subprocess.Popen([str(engine_dir(bar) / ("spring" + EXE)), "--write-dir", str(bar), "--isolation",
                             "--window", str(play_script)], stdout=log, stderr=subprocess.STDOUT, **new_group())


def latest_screenshot(bar):
    shots = sorted(Path(bar, "screenshots").glob("*.png"), key=lambda p: p.stat().st_mtime)
    return shots[-1] if shots else None


# map previews ------------------------------------------------------------------------------------

def find_7z(bar):
    for name in ("7z", "7za", "7zz"):
        if shutil.which(name):
            return shutil.which(name)
    for p in (Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "7-Zip/7z.exe",):
        if p.exists():
            return str(p)
    # the BAR launcher bundles 7za next to its data folder
    bundled = Path(bar).parent / "resources" / "app.asar.unpacked" / "node_modules" / "7zip-bin"
    os_dir = "win" if WINDOWS else "mac" if sys.platform == "darwin" else "linux"
    for p in sorted(bundled.glob(f"{os_dir}/*/7za*"), key=lambda p: "x64" not in p.parts):
        if p.is_file():
            return str(p)
    return None


def minimap(bar, name, out):
    """Writes the map's minimap as a 256² PNG; False when the map or a 7z tool (for .sd7) is missing."""
    want = re.sub(r"[^a-z0-9.-]+", "_", name.lower())
    maps = Path(bar, "maps")
    arch = next((p for p in maps.iterdir() if p.suffix in (".sd7", ".sdz") and p.stem == want), None) if maps.is_dir() else None
    if not arch:
        return False
    smf = b""
    if arch.suffix == ".sdz":
        with zipfile.ZipFile(arch) as z:
            smf = next((z.read(n) for n in z.namelist() if n.lower().endswith(".smf")), b"")
    elif find_7z(bar):
        smf = subprocess.run([find_7z(bar), "e", "-so", str(arch), "-r", "*.smf"], capture_output=True).stdout
    if smf[:15] != b"spring map file":
        return False
    SIZE = 256
    # mip 2 of the 1024² DXT1 minimap: skip mip 0 (1024²/2 bytes) and mip 1 (512²/2)
    at = struct.unpack_from("<i", smf, 64)[0] + 1024 * 1024 // 2 + 512 * 512 // 2

    def rgb565(c):
        return ((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31

    px = bytearray(SIZE * SIZE * 3)
    for by in range(SIZE // 4):
        for bx in range(SIZE // 4):
            c0, c1, bits = struct.unpack_from("<HHI", smf, at)
            at += 8
            a, b = rgb565(c0), rgb565(c1)
            if c0 > c1:
                pal = [a, b, tuple((2 * x + y) // 3 for x, y in zip(a, b)), tuple((x + 2 * y) // 3 for x, y in zip(a, b))]
            else:
                pal = [a, b, tuple((x + y) // 2 for x, y in zip(a, b)), (0, 0, 0)]
            for i in range(16):
                o = ((by * 4 + i // 4) * SIZE + bx * 4 + i % 4) * 3
                px[o:o + 3] = bytes(pal[(bits >> (2 * i)) & 3])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + px[y * SIZE * 3:(y + 1) * SIZE * 3] for y in range(SIZE))
    Path(out).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return True


# CLI ---------------------------------------------------------------------------------------------

def main(argv):
    if len(argv) < 2 or argv[0] not in ("replay", "parse", "play"):
        raise SystemExit(__doc__ or open(__file__).read().split("\nimport")[0])
    cfg = load_config()
    if not bar_ok(cfg["bar_data"]):
        raise SystemExit(f"no BAR engine in {cfg['bar_data']}: set the BAR data folder in the app or in {config_path()}")
    if argv[0] in ("replay", "parse"):
        for event in parse(cfg, argv[1]):
            if event[0] == "progress":
                print(event[2], flush=True)
        if argv[0] == "parse":
            return
    shot = {"camera": argv[2], "png": argv[3]} if len(argv) >= 4 else None
    proc = play(cfg, argv[1], shot)
    try:
        proc.wait(timeout=600 if shot else None)
    except subprocess.TimeoutExpired:
        proc.kill()
    if shot:
        png = latest_screenshot(cfg["bar_data"])
        if png:
            shutil.copy(png, argv[3])
    print(f"BAR exited ({proc.returncode}), log: {Path(cfg['out_dir'], 'play.log')}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except RuntimeError as e:
        raise SystemExit(str(e))
