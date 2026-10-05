# BAR-Rewind
### (Prototype)
Rewind, pause and scrub [Beyond All Reason](https://www.beyondallreason.info/) replays, rendered by BAR itself.

BAR replays only play forward: a `.sdfz` file is a list of player commands that the engine re-simulates.
bar-rewind runs a replay through the engine once ("parse"), records where everything is, and plays that
recording back inside BAR, where you can drag a timeline, play backwards and change speed.

### Jump anywhere

Click or drag the timeline and the match is there, at that moment.

![Jumping around the timeline](docs/rewind.gif)

### Play backwards

Press R and the fight runs in reverse: shots fly back into the guns and dead units come back.

![A fight playing backwards](docs/play-backwards.gif)

### Any speed, either way

Up/Down change the speed. At 64x a whole match unwinds in seconds.

![A match playing backwards at 64x](docs/play-backwards-64x.gif)

## Numbers

One 53-minute match (2240 units, 14k projectiles) on a Ryzen 7 5800X:

| | |
|-|-|
| Replay (`.sdfz`) | 1.7 MB |
| Parse (once per replay) | about 7 min |
| Parsed replay (`.curves`) | 174 MB |

## Install

Needs BAR installed and [Python 3](https://www.python.org/downloads/) (Windows: tick "Add to PATH").

1. Download `bar-rewind-linux.tar.gz` or `bar-rewind-windows.zip` from the releases and extract it.
2. Run `bar-rewind` (Linux) or `bar-rewind.bat` (Windows). The app opens in your browser.
3. Check the **BAR data folder** at the top. It's usually found on its own; if not, paste it and press Enter.
   It's the folder BAR keeps its data in, with `engine/`, `maps/` and `demos/` inside, not the install folder:
   - Linux Flatpak: `~/.var/app/info.beyondallreason.bar/data`
   - Linux AppImage: `~/.local/state/Beyond All Reason`
   - Windows: `%LOCALAPPDATA%\Programs\Beyond-All-Reason\data`
4. Click **Parse** on a replay (a minute or more, depending on its length), then **Play**.

In the player: drag the timeline, Space play/pause, R reverse, Left/Right skip 10 s, Up/Down speed.

Map previews of `.sd7` maps need [7-Zip](https://www.7-zip.org/) (`7z` on Linux); everything else works without it.

## Files it creates

- **Output folder** (default `out/` next to the app; change it at the top of the page): parsed replays
  (`curves/`), map previews, and the logs `curves/dump.log` (parse) and `play.log` (play).
- **Settings**: `bar-rewind.json` in `~/.config/` (Linux) or `%APPDATA%` (Windows), holding the two folders.
- **In BAR's data folder**: `games/barrewind.sdd`, the player BAR loads. Parsing briefly adds
  `LuaUI/Widgets/dump_replay.lua` and removes it again.

If something goes wrong, the page shows the end of the log; the full logs are in the output folder.

## Build from source

Needs [Zig](https://ziglang.org/) 0.16 and Python 3.

```sh
zig build run                    # the app
zig build run -- <replay.sdfz>   # parse (once, cached) and play one replay
zig build test
zig build dist                   # dist/bar-rewind-linux.tar.gz and dist/bar-rewind-windows.zip
```

- `lua/dump_replay.lua`: the BAR widget that records a replay while the headless engine re-simulates it
- `src/bake.zig`, `src/curves.zig`: recording → `.curves` (keyframes thinned with Douglas–Peucker), and
  `bake export-lua`, which writes them in the form the player reads
- `recoil/barrewind.sdd`: the BAR Rewind game (a mutator on top of BAR) that plays `.curves`: the
  `replay_player` gadget and the timeline widget
- `tools/pipeline.py`: parse and play (also a CLI, see its header); `tools/ui.py`: the browser app

## AI disclosure

The code was written by AI. I guided it: Provided sources, how to connect ideas, coming up with ideas on how to solve problems, talked it through what to build and how. 
(To save time and provide a tool quickly).

## License

GPL-2.0 (see `LICENSE`), like BAR's own code. Nothing from BAR is included: models, maps and the game
itself are loaded from your BAR install.
