# Find The Needle — Multiplayer (co-op) Mod

Play *Find The Needle* (Steam demo) together with your friends. One haystack,
several players, everyone digging at the same time.

Connection goes through **Steam's relay network**, the same thing official co-op
games use: **no port forwarding, no IP addresses, no VPN**. You invite from the
Steam friends list and your friend drops straight into your yard.

> Unofficial mod. Not affiliated with, or endorsed by, the game's developer.
> It ships **no game files** — only its own scripts, which the game loads at
> startup, and a free (CC0) player model. Español: [README.es.md](README.es.md)

![The multiplayer panel](screenshots/panel.png)

---

## Requirements

- *Find The Needle Demo* installed from Steam (free) — build **V26** or newer.
- Windows 64-bit.
- Every player needs the **same version of this mod**.
- Launch the game **from Steam** (invites need the Steam overlay).

## Install

1. Download the latest `FindTheNeedle_Multiplayer_vX.Y.Z.zip` from
   [Releases](../../releases).
2. Unzip it and copy the `mods` folder next to `FindTheNeedle.exe`
   (Steam → right-click the game → Manage → Browse local files).
3. Run `mods\multiplayer\INSTALL.bat`.
4. Start the game from Steam. The main menu now has a **MULTIPLAYER** entry.

To remove it, run `mods\multiplayer\UNINSTALL.bat`. It puts the game back
exactly as it was.

> **After every game update, run `INSTALL.bat` again.** Steam updates overwrite
> `override.cfg`, which is the file that registers the mod.

## How to play

**Host** (the one whose save everyone plays on):

1. `MULTIPLAYER` → **CREATE GAME**
2. **INVITE FRIENDS** (opens the Steam overlay) — or let them join from your
   profile with *Join game*.
3. Start or load your save as usual. Your friends appear in it.

**Friends:** accept the Steam invite. That is all — no address to type. If the
game was closed, Steam launches it and takes you straight in.

There is also a direct-IP mode under *IP connection (advanced)* as a fallback.

### Controls

| Key | Action |
|-----|--------|
| `F2` | Multiplayer panel (also in game) |
| `Y` | Chat |
| `F8` | Resync the world if something looks different |

## What is shared

- **The haystack.** Everyone digs the same pile and sees it change live.
- **Buildings.** Placing and demolishing structures, conveyors, platforms.
- **Economy.** Money, debt, hay sold, needles found, the collection.
- **Tech tree.** An upgrade bought by one player unlocks for everybody.
- **Loose needles.** Uncovered needles are visible to all and can only be
  handed in once.
- **New hay loads.** Ordering a new pile resyncs everyone.
- **Players.** You see each other with Steam names and the tool in hand.

## Current limitations

- Machines that feed themselves from the pile (piston rake, robotic arm, drone,
  scanner) run **only on the host**; on clients they stand still. This is
  deliberate: it stops hay and money being counted twice.
- Loose props (buckets, sacks, bales) are per-player.
- Machine settings (filters, switches) are not shared.
- Bought tools are per-player; money is shared.
- Only the host saves. Clients never touch their own save files.
- The online leaderboard is disabled while the mod is active, so modded runs
  never reach it.

## Troubleshooting

**The MULTIPLAYER entry is missing** — the game updated and wiped
`override.cfg`. Run `INSTALL.bat` again.

**"Steam not available"** — launch the game from Steam, not from the .exe.

**A friend cannot join** — both of you need the same mod version; the panel
says which one you are running.

**The world looks different between players** — press `F8` to resync.

**Anything else** — open an [issue](../../issues) with the log from
`%APPDATA%\Godot\app_userdata\Haystack Incremental\logs\`.

## Privacy while streaming

The panel never shows IP addresses, Steam IDs or lobby codes. Local addresses
are only drawn after you press *Show my IPs*, in the advanced section.

## How it works

The demo ships as a single encrypted Godot `.pck`, so the mod never touches it.
Instead:

- **Loading.** Godot reads `override.cfg` next to the executable at startup.
  The installer registers `mp.gd` there as an autoload, so the mod is just a
  few `.gd` files living outside the game.
- **Steam.** The demo has no Steam API, so the mod loads the
  [GodotSteam](https://godotsteam.com) GDExtension at runtime with
  `GDExtensionManager.load_extension()` and initialises Steam under the demo's
  app id. That gives us Steam lobbies, invites and `SteamMultiplayerPeer`,
  which relays traffic through Steam instead of a direct socket.
- **Joining.** The host serialises its world in the same shape the game's own
  save uses, sends it compressed over the wire, and the client loads it with
  the game's own loader into a scratch slot — never touching the player's saves.
- **Staying in sync.** The haystack is a height field; each peer sends the
  vertices that changed. Buildings are diffed against the game's own
  `to_array()` and re-created through its own loader. Money and counters are
  sent as deltas with the host as the authority.

Everything is applied by walking the live scene tree and calling the game's own
methods, so no game code is copied or redistributed.

## For contributors

The mod is plain GDScript in `mods/multiplayer`: `mp.gd` (session and RPCs),
`mp_world.gd` (world sync), `mp_steam.gd` (Steam), `mp_ui.gd` (panel) and
`mp_avatar.gd` (the remote-player figure). Nothing is compiled — edit a file and
restart the game.

Remote players are an animated farmer, `mods/multiplayer/models/farmer.glb`,
loaded at runtime with Godot's `GLTFDocument`. The overalls and the hat band
take the player's colour, the head follows where they look, the legs bend
when they crouch and the clip (Idle, Walk, Run) follows their speed. If the
file is missing or fails to load, the old figure made of primitives stands in.
The `.glb` is the pack's original trimmed to those three clips with
`dev/models/slim_glb.py` (1.3 MB → 500 KB).

Tool models hang off the avatar's hand in `mp_avatar.gd`. Each model is scaled
to its real length (`TOOL_LENGTHS`) along its longest axis and turned so its
working end points away from the hand; set `flip_tool` on an avatar to turn a
model 180 degrees while testing a new one.

`dev/mp_test.gd` is a test harness: copy it next to `mp.gd` and start the game
with `MP_TEST_AVATAR=user://saves/slot_1.dat` (plus `MP_TEST_TOOL=1` for the
spade) to get a screenshot of two puppets holding that tool, one of them
flipped.

## Credits

- Mod by **AleDev11**.
- *Find The Needle* by [FindTheNeedleDev](https://x.com/haydeveloper).
- Farmer model from the [Ultimate Modular Men Pack](https://quaternius.com/packs/ultimatemodularcharacters.html)
  by **Quaternius** — CC0.
- [GodotSteam GDExtension](https://godotsteam.com) — MIT.
- Steamworks SDK — © Valve Corporation.

## Licence

The mod's own code is MIT — see [LICENSE](LICENSE). This repository contains no
assets or code from the game.
