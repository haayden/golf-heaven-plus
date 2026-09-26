"""Builds the Golf Heaven Plus download: UE4SS plus the mod, laid out to be extracted straight into
the game's Ride/Binaries/Win64 folder, so players don't need to install a mod loader first.

usage: python tools/release.py <version> [--win64 <path>]

UE4SS's own files come from a working install (--win64, default this machine's game folder), so the
download carries the exact UE4SS build the mod was tested with.
"""
import argparse
import pathlib
import re
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "mods" / "GolfHeavenPlus" / "Scripts"
DIST = ROOT / "dist"
DEFAULT_WIN64 = r"D:\SteamLibrary\steamapps\common\Ride\Ride\Binaries\Win64"

# Settings a player wants different from a mod developer: no debug console windows, and no hot
# reloading (reloading a mod mid-game froze the game in testing). Extra mod folders
# (+ModsFolderPaths) point into this machine and are dropped.
PLAYER_SETTINGS = {
    "EnableHotReloadSystem": "0",
    "EnableAutoReloadingLuaMods": "0",
    "ConsoleEnabled": "0",
    "GuiConsoleEnabled": "0",
}


def scripts_needed():
    """main.lua and every module it requires, following require() chains."""
    needed, todo = set(), ["main"]
    while todo:
        name = todo.pop()
        if name in needed:
            continue
        needed.add(name)
        text = (SCRIPTS / f"{name}.lua").read_text(encoding="utf-8")
        todo += re.findall(r'require\("([^"]+)"\)', text)
    return sorted(needed)


def player_settings(original):
    lines = []
    for line in original.splitlines():
        stripped = line.strip()
        if stripped.startswith("+ModsFolderPaths"):
            continue
        key = stripped.split("=", 1)[0].strip()
        if "=" in stripped and not stripped.startswith(";") and key in PLAYER_SETTINGS:
            line = f"{key} = {PLAYER_SETTINGS[key]}"
        lines.append(line)
    text = "\n".join(lines) + "\n"
    for key, value in PLAYER_SETTINGS.items():
        if not re.search(rf"^{key} = {value}$", text, re.M):
            raise SystemExit(f"UE4SS-settings.ini has no {key} line to set")
    overrides = text.split("[Overrides]")[1].split("[General]")[0]
    for line in overrides.splitlines():
        if not line.strip().startswith(";") and re.search(r"[A-Za-z]:[/\\]", line):
            raise SystemExit("UE4SS-settings.ini still points [Overrides] at a folder on this machine: " + line)
    return text


def build(version, win64):
    ue4ss = win64 / "ue4ss"
    DIST.mkdir(exist_ok=True)
    out = DIST / f"GolfHeavenPlus-{version}.zip"
    scripts = scripts_needed()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(win64 / "dwmapi.dll", "dwmapi.dll")
        z.write(ue4ss / "UE4SS.dll", "ue4ss/UE4SS.dll")
        z.write(ue4ss / "LICENSE", "ue4ss/LICENSE")
        z.writestr("ue4ss/UE4SS-settings.ini",
                   player_settings((ue4ss / "UE4SS-settings.ini").read_text(encoding="utf-8")))
        z.writestr("ue4ss/Mods/mods.txt", "GolfHeavenPlus : 1\n")
        for name in scripts:
            z.write(SCRIPTS / f"{name}.lua", f"ue4ss/Mods/GolfHeavenPlus/Scripts/{name}.lua")
    print(f"{out} ({out.stat().st_size / 1e6:.1f} MB): UE4SS + {len(scripts)} scripts ({', '.join(scripts)})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--win64", default=DEFAULT_WIN64, type=pathlib.Path)
    args = parser.parse_args()
    build(args.version, args.win64)
