# Find The Needle co-op mod

Adds co-op multiplayer to the Find The Needle demo. Several players dig the
same haystack, share the money and see each other's buildings.

Connections go through Steam's relay network, so there is no port forwarding
and no IP addresses to exchange. The host invites from the Steam friends list.

Unofficial mod, not affiliated with the game's developer. It contains no game
files, only its own scripts and a CC0 player model. Spanish version of this
file: [README.es.md](README.es.md).

![Multiplayer panel](screenshots/panel.png)

## Requirements

* Find The Needle demo (free on Steam), build V26 or newer
* Windows 64-bit
* The same mod version on every machine
* The game has to be launched from Steam, or the invites will not work

## Install

No installer to run: copy a folder, add two lines to a text file.

1. Download the zip from [Releases](../../releases) and unzip it.
2. Copy the `mods` folder next to `FindTheNeedle.exe`. In Steam: right-click
   the game, Manage, Browse local files.
3. Open `override.cfg`, in that same folder, with any text editor and add:

   ```ini
   [autoload]
   MPMod="*mods/multiplayer/mp.gd"
   ```

   If the file already has an `[autoload]` section, only the second line is
   needed.
4. Launch from Steam. There is a MULTIPLAYER entry in the main menu.

If you would rather not edit the file, `tools/install-helper.bat` (also
attached to each release) does that one step for you. It is not inside the
download because Nexus quarantines uploads that contain scripts.

To uninstall, delete that line and the `mods` folder, or run
`tools/uninstall-helper.bat`. Nothing is ever written outside it.

Game updates replace `override.cfg`, so add the lines again after each one.

## Playing

Host: MULTIPLAYER, CREATE GAME, INVITE FRIENDS, then start or load a save as
usual. Everyone else joins by accepting the Steam invite. If their game is
closed, Steam starts it and takes them in.

There is a direct-IP mode under "IP connection (advanced)" as a fallback.

| Key | Action |
|-----|--------|
| F2 | Multiplayer panel |
| Y | Chat |
| F8 | Resync the world |

## What is synced

* The haystack. Everyone digs the same pile.
* Buildings, placed and demolished.
* Money, debt, hay sold, needles found, the collection.
* The tech tree.
* Uncovered needles. They show up for everyone and can only be handed in once.
* New hay loads, which resync every client.
* Player positions, names and the tool in hand.

## Languages

The interface follows the game's own language setting. English, Spanish,
German, French, Italian, Czech, Polish, Russian, Turkish, Japanese, Korean and
Chinese are included, in `mp_i18n.gd`. Anything else falls back to English.
Tool names are not translated by the mod: they go through the game's own
translations, so they read the same as in the rest of the UI.

## Known limitations

* Machines that take hay from the pile on their own (piston rake, robotic arm,
  drone, scanner) only run on the host. On clients they stand still. This is
  deliberate: running them everywhere counted hay and money twice.
* Loose props (buckets, sacks, bales) are local to each player.
* Machine settings such as filters and switches are not synced.
* Bought tools are per player. Money is shared.
* Only the host saves. Clients never write to their own save files.
* The online leaderboard is disabled while the mod is loaded.

## Troubleshooting

No MULTIPLAYER entry: the game updated and replaced `override.cfg`. Add the
two lines again.

"Steam not available": the game was launched from the .exe instead of Steam.

A friend cannot join: check that both of you run the same mod version. The
panel shows it.

The world looks different between players: press F8.

Anything else: open an [issue](../../issues) with the log from
`%APPDATA%\Godot\app_userdata\Haystack Incremental\logs\`.

## How it works

The demo ships as one encrypted Godot `.pck`, which the mod never touches.

Godot reads `override.cfg` next to the executable at startup. The installer
registers `mp.gd` there as an autoload, so the mod is a handful of `.gd` files
living outside the game.

The demo has no Steam API, so the mod loads the
[GodotSteam](https://godotsteam.com) GDExtension at runtime with
`GDExtensionManager.load_extension()` and initialises Steam under the demo's
app id. That provides lobbies, invites and `SteamMultiplayerPeer`.

To let someone join, the host serialises its world in the same format the game
uses for saves, sends it compressed, and the client loads it with the game's own
loader into a scratch slot.

Syncing after that is incremental. The haystack is a height field and each peer
sends the vertices it changed. Buildings are diffed against the game's
`to_array()` and rebuilt through its own loader. Money and counters travel as
deltas, with the host as the authority.

Everything is applied by walking the live scene tree and calling the game's own
methods.

## Repository layout

```
mods/multiplayer/     what ships in the release
  mp.gd               session, lobby flow, RPCs
  mp_world.gd         world sync (haystack, buildings, state, needles)
  mp_steam.gd         GodotSteam loading, lobbies, invites
  mp_ui.gd            panel, chat, notifications
  mp_avatar.gd        the other players' figures
  mp_i18n.gd          UI strings per language
  models/             farmer model (CC0)
  steam/              GodotSteam GDExtension (prebuilt)
dev/mp_test.gd        test harness, not shipped
dev/models/           tooling used to prepare the model
docs/                 Nexus page copy
```

Nothing is compiled. Edit a file, restart the game.

Remote players are an animated farmer, `mods/multiplayer/models/farmer.glb`,
loaded at runtime with `GLTFDocument`. The overalls and the hat band take the
player's colour, the head follows where they look, the legs bend when they
crouch, and the clip (Idle, Walk, Run) follows their speed. If the file is
missing or fails to load, an older figure made of primitives stands in. The
`.glb` is the original pack trimmed to those three clips with
`dev/models/slim_glb.py`, which takes it from 1.3 MB to 500 KB.

Tool models hang off the avatar's hand. Each one is scaled to its real length
(`TOOL_LENGTHS`) along its longest axis and turned so the working end points
away from the hand. Set `flip_tool` on an avatar to turn a model 180 degrees
while testing a new one.

To use the test harness, copy `dev/mp_test.gd` next to `mp.gd` and start the
game with `MP_TEST_AVATAR=user://saves/slot_1.dat` set, plus `MP_TEST_TOOL=1`
for the spade. It drops two puppets holding that tool, one of them flipped, and
writes a screenshot.

## Credits

Mod by AleDev11. Find The Needle by
[FindTheNeedleDev](https://x.com/haydeveloper).
Farmer model from the [Ultimate Modular Men Pack](https://quaternius.com/packs/ultimatemodularcharacters.html)
by Quaternius, CC0. [GodotSteam](https://godotsteam.com) is MIT. Steamworks SDK
is Valve's.

MIT licence, see [LICENSE](LICENSE).
