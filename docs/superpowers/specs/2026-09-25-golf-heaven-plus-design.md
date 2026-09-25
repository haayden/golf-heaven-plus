# Golf Heaven Plus — design

Date: 2026-09-25 · Status: approved by Hayden ("go, glitches later")

A mod for **RV There Yet?** that expands the Golf Heaven post-game map. It adds a Mods sign on the
main menu, a shot trajectory preview, and later glitch fixes, extra holes, and possibly new maps.

## Facts this design rests on

- The game (v1.3.20702) runs Unreal **5.6.0** on the studio's `++RideGamejam+rel-1.3` branch, confirmed by UE4SS at startup. It is installed at
  `D:\SteamLibrary\steamapps\common\Ride`.
- **MelonLoader is Unity-only**, so the loader is **UE4SS experimental** (v3.0.1-1145, which supports UE 5.4–5.8).
  Existing RV mods (MoreRVers, ExtraRV, RvGodmod) use the same loader.
- Golf is native C++ (`RG*` classes) plus Blueprints on top. Everything below comes from our own dump
  (`mods/RVDump`, output in `sdk/`, which is gitignored):
  - `URGGolfSwingComponent` (on each club as `RGGolfSwing`) handles swing input. It fires
    `HandlePowerUpdated(Power)` while the meter moves, `HandleStrokeCompleted(Power, Precision, CleanHit)`
    on release, and `ApplyPowerCurve(NormalizedPower)`.
  - `BP_Interactable_GolfClub_C` does the shot math in Blueprint: `CalculateLandLocation(HitLocation,
    WithAllExternalMultipliers, out EndPosition)`, then `SetNewTrajectory(Start, End, ArcParam, out LaunchForce,
    out Valid)`. That matches UE's "suggest projectile velocity with a custom arc". It passes the result to
    `BP_Interactable_GolfBall_C::OnHitByGolfClub(..., LaunchForce, ..., SpinData, ...)`.
    The ball adds sidespin in flight (`ApplyMagnusEffect`) and backspin on impact.
  - Per-club defaults: every club has `MaxDistance` = 10000 (100 m). Each club also has a `DirectionalMultiplier`
    (Driver 1.5, Iron5 1.05, Iron7 0.8, Wedge 0.5, Putter 0.0425) and an `Arc Param` (Driver 0.7, Iron5 0.6,
    Iron7 0.5, Wedge 0.4, Putter 0.9). Default swing types are Driver = Target, irons and wedge = TargetHoldSteady,
    Putter = DragFollowThrough.
  - `ARGGolfGameManager` owns turns, scorecards, `CurrentHole`, `BallsInFlight`, and the events
    `OnGolfBallHit(…, AirDistance, TotalDistance)`, `OnSwingStarted/Completed/Aborted`, and `OnCurrentHoleChanged`.
  - `ARGGolfHole` holds `HoleNumber`, `HolePar`, the tee, ball, cup, and flag components, and a `GolfHoleSpline`.
  - Main menu: `WG_MainMenu_C` → `VerticalBox_96` holds one overlay per sign. Each overlay contains a `Shadow`
    image and a `WG_MainMenuButton_C`, a CommonUI button whose label comes from `DisplayText`. The no-smoking
    sign is `Overlay_227` at index 5, and Exit is `Overlay_7` at index 6.
- Engine `BasicShapes` (Sphere, Cylinder, Plane) and `EmissiveMeshMaterial` ship with the game, so the mod
  needs no custom assets for its visuals.
- Tooling: UE4SS Lua needs no build step. There is no Visual Studio and no UE 5.6 editor on the machine. The
  installed editor is 5.8, which only matters for phase 5.

## Architecture

One UE4SS Lua mod, `mods/GolfHeavenPlus`, split into small modules:

| File | Job |
|---|---|
| `Scripts/main.lua` | Wiring: loads config, registers hooks, starts features. |
| `Scripts/config.lua` | Reads and writes `config.txt` (`key=value`) next to the mod. It is the single source of truth for toggles. |
| `Scripts/menu.lua` | Adds the Mods sign and the settings signpost. |
| `Scripts/golf.lua` | Finds the local player's held club, target ball, and swing state. It is the only place that knows game member names. |
| `Scripts/trajectory.lua` | Predicts the flight path. The math lives here with no rendering. |
| `Scripts/render.lua` | Keeps a pool of local, non-replicated marker meshes and places them along a path. |

Dev setup: the installed `UE4SS-settings.ini` has `+ModsFolderPaths = <repo>/mods`, so the game runs the repo
copy directly and Ctrl+R hot-reloads it. `RVDump` stays dev-only.

Robustness rule: a game update can rename a Blueprint member. When `golf.lua` can't find what it needs, it
turns the affected feature off, logs one clear line, and leaves the game untouched.

## Phase 1 — Mods sign (main menu)

- When `WG_MainMenu_C` constructs, build an overlay that copies Exit's: a shadow `Image` using `Shadow_4`'s brush and
  transform, plus a new `WG_MainMenuButton_C` with `DisplayText` = "Mods". Insert it between the no-smoking sign
  and Exit. `UPanelWidget` has no reflected `InsertChildAt`, so the code removes `Overlay_7` (Exit), appends
  Mods, re-appends Exit, and restores Exit's slot padding and alignment.
- Clicks come from hooking `/Script/CommonUI.CommonButtonBase:HandleButtonClicked`, filtered to our button
  instances.
- **Mods screen = the signpost itself.** Clicking Mods collapses the game's signs and shows one sign per
  setting, with the value in the label (e.g. `Trajectory: On`, `Shot Tracer: On`), plus a `Back` sign. Clicking a setting toggles it,
  saves `config.txt`, and relabels the sign. Back restores the original signs. The only widgets used are ones
  the game already ships, so everything matches exactly.
- Later (not in v1): list other installed UE4SS mods with on/off toggles, using `RestartMod`/`UninstallMod` and `mods.txt`.

## Phase 2 — Trajectory preview + shot tracer

- **When it shows:** the local player holds a club, the club has a ball to hit (`ActorToHit`/`CurrentHitActor`),
  and the setting is on. Before the swing starts it shows the full-power arc faded. During the swing it follows
  the live power from `HandlePowerUpdated`. It hides on hit.
- **Prediction:** reuse the game's own math wherever possible. Get `EndPosition` from the club's
  `CalculateLandLocation` for the current power and `LaunchForce` from `SetNewTrajectory(Start, End,
  Arc Param)`. Then integrate the flight with world gravity, stepping and line-tracing so the arc stops where
  terrain or objects block it. The landing marker goes at the first hit.
- **Step 0 (discovery, in-game):** hook `CalculateLandLocation`, `SetNewTrajectory`, and
  `OnHitByGolfClub` during real shots. Log power, start, end, arc, launch force, and the ball's actual first
  impact. This confirms which member carries power into `CalculateLandLocation` and whether `LaunchForce` is an
  impulse (divide by mass) or a velocity. If calling the game's functions is not safe mid-swing, fall back to
  re-implementing them from the logged numbers.
- **Accuracy target:** with a clean hit (no sidespin), the predicted landing is within 1.5 m of the actual first
  impact on a 100 m+ driver shot, measured with the discovery logging. Sidespin curve is out of scope for v1;
  the arc shows the ideal line.
- **Rendering:** a pool of about 40 small spheres (engine `Sphere`, emissive material, no collision, no
  shadows), spawned locally so only this player sees them. A flat ring (`Plane`/`Cylinder`) marks the landing
  spot.
- **Shot tracer:** while the local player's ball is in flight, record its location every tick and draw the
  trail with the same pool style in a second color. The trail clears on the next swing.
- **Multiplayer:** everything is local-only visuals, so a host or client with the mod sees them and nobody
  else is affected.

## Phase 3 — Glitch fixes

Waiting on Hayden's list. There are useful hooks: `Golf_MoveBallInFront`, the ball's `PushOutFromStuff`,
`ResetBall`, and `SetBallLocationAndClearForces`.

## Phase 4 — More holes (roadmap)

Spawn the game's own `BP_GolfHole`/`BP_GolfCup`/tee/flag actors at authored spots on existing terrain and
register them with `ARGGolfGameManager`. This needs its own spec after studying how holes are registered and
replicated.

## Phase 5 — New maps (roadmap)

This needs a UE **5.6** editor, a modkit project that mirrors the game's paths, and cooked IoStore paks loaded
via `LogicMods`/`~mods`. It gets its own spec when phases 1–4 are done.

## Verification

- Phase 1: a screenshot shows the Mods sign between the no-smoking sign and Exit, matching the other signs.
  Clicking it shows the settings signs, a toggle survives a game restart, and Back restores the menu. New Game,
  Load, and Exit still work.
- Phase 2: the discovery log proves the accuracy target on at least three driver and three iron shots, plus a
  screenshot of the arc in Golf Heaven. With the setting off, nothing is spawned.
