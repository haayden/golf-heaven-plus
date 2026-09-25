"""Take an in-game screenshot with UI through the GHPDev harness and save a small preview.

Usage: python tools/shot.py [--crop left,top,right,bottom] [--width 1400] [--name label]
Crop box is in fractions of the full frame (0-1), e.g. --crop 0.05,0,0.4,1 for the signpost.
Prints the preview path.
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SHOTS = Path(os.environ["LOCALAPPDATA"]) / "Ride" / "Saved" / "Screenshots" / "Windows"
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--crop", default="0,0,1,1")
    parser.add_argument("--width", type=int, default=1400)
    parser.add_argument("--name", default="shot")
    args = parser.parse_args()

    before = set(SHOTS.glob("*.png")) if SHOTS.exists() else set()
    subprocess.run([GIT_BASH, str(REPO / "tools" / "ghp.sh"), "console", "shot showui"], check=True)
    deadline = time.time() + 15
    new = []
    while time.time() < deadline and not new:
        time.sleep(0.5)
        new = sorted(set(SHOTS.glob("*.png")) - before, key=lambda p: p.stat().st_mtime)
    if not new:
        print("no screenshot appeared", file=sys.stderr)
        return 1
    time.sleep(0.5)  # let the writer finish

    image = Image.open(new[-1])
    left, top, right, bottom = (float(v) for v in args.crop.split(","))
    w, h = image.size
    image = image.crop((int(left * w), int(top * h), int(right * w), int(bottom * h)))
    if image.width > args.width:
        image = image.resize((args.width, round(image.height * args.width / image.width)))
    out_dir = REPO / "dev" / "shots"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{args.name}-{time.strftime('%H%M%S')}.png"
    image.save(out)
    new[-1].unlink()  # keep the game's screenshot folder clean
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
