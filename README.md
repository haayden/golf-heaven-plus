# Golf Heaven Plus

A mod for **RV There Yet?** that makes the Golf Heaven course nicer to play. It shows where your shot will land, lets you aim without shuffling your feet, and makes putting work by feel with a power gauge. It also speeds up the golf cart.

## Install

RV There Yet? is an Unreal Engine game, so this mod runs on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), not MelonLoader, which only works with Unity games. UE4SS is included in the download.

1. Download the **GolfHeavenPlus** zip from the [latest release](https://github.com/haayden/golf-heaven-plus/releases/latest).
2. In Steam, right-click **RV There Yet?** and choose **Manage** → **Browse local files**.
3. Open `Ride\Binaries\Win64`. It's the folder that holds `Ride-Win64-Shipping.exe`.
4. Extract the zip into that folder. You should now have `dwmapi.dll` and a `ue4ss` folder next to the game's exe.
5. Start the game. Use the **Mods** sign on the main-menu signpost to turn each feature on or off.

To uninstall, delete `dwmapi.dll` and the `ue4ss` folder from `Ride\Binaries\Win64`.

## Features

- **Trajectory preview**: while you line up a shot, a line shows where the ball will fly and land with the club in your hands. It follows the power meter during the swing. Only you see it.
- **Aim assist**: turning with the mouse walks you around the ball so it stays in front of you. Each scroll-wheel notch nudges your aim by one degree.
- **Real putting**:
  - How far you draw the putter back sets how far the putt rolls.
  - A gauge on the right of the screen shows that distance. A blue marker holds your last putt so you can repeat it.
  - Auto-putt: once you've drawn back, your first push forward takes the putt, so a soft follow-through still gets the full distance.
  - Putts roll flat instead of hopping.
  - A ball rolling across the hole drops in unless it's going too fast.
- **Power readout**: the club panel shows your live swing power and carry distance, plus the last shot's numbers.
- **Fast golf cart**: tops out around 60 km/h instead of 40. Hold **Left Shift** while driving for turbo, up to about 125 km/h.
- **Scorecard cleanup**: a player who leaves and rejoins no longer shows up on the scorecard more than once.

## Multiplayer

Everyone in the lobby should install the same version. Each player gets their own trajectory preview, aim assist, gauge and power readout on their own screen. The fast cart and turbo work for whoever is driving.

The host's game runs the ball physics, and every player's game reports their putter backswing to the host. So the host's copy applies everyone's backswing distance, flat roll and cup catching. If the host doesn't have the mod, guests putt with the game's normal feel.

## Notes

- Built for the Steam version of RV There Yet? (Unreal Engine 5.6). A game update can break it until the mod is updated.
- UE4SS is by the [UE4SS team](https://github.com/UE4SS-RE/RE-UE4SS) and is included under its MIT license (`ue4ss/LICENSE`).

## Development

The mod's source is in `mods/GolfHeavenPlus/Scripts`. `mods/GHPDev` is a development-only remote-control harness and is never shipped. `python tools/release.py <version>` builds the download zip from a working UE4SS install.
