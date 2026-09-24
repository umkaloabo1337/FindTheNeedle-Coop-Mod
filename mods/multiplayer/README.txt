FIND THE NEEDLE CO-OP MOD  v0.9.0
==================================

Unofficial mod. Every player needs the game (the free Steam demo) and this
same mod version. Spanish version of these notes: LEEME.txt

The connection runs over Steam's relay network: no port forwarding, no IP
addresses. The host invites from the Steam friends list.

INSTALL (two steps, no installer to run)
----------------------------------------
1. Copy the "mods" folder next to FindTheNeedle.exe.
   In Steam: right-click the game, Manage, Browse local files.

2. Open "override.cfg" (same folder as FindTheNeedle.exe) with Notepad and
   add these two lines at the end, then save:

[autoload]
MPMod="*mods/multiplayer/mp.gd"

   If the file already has an [autoload] line, just add the MPMod line
   under it.

3. Start the game FROM STEAM. The main menu now has MULTIPLAYER.

To uninstall: delete the MPMod line from override.cfg, and delete the mods
folder. Nothing else was ever changed.

Game updates replace override.cfg, so add the two lines again after each one.

PLAYING
-------
Host: MULTIPLAYER, CREATE GAME, INVITE FRIENDS, then start or load a save as
usual. The others accept the Steam invite. If their game is closed, Steam
opens it and takes them in.

Keys:  F2 panel   Y chat   F8 resync the world   F6 test menu

F6 opens the debug menu the game already has (money, items, unlocks, tech).
It is meant for setting up a session or trying things out. The game marks a
run that used it, so it no longer counts for the leaderboards.

LANGUAGES
---------
The mod follows the language you set in the game. English, Spanish, German,
French, Italian, Czech, Polish, Russian, Turkish, Japanese, Korean and
Chinese are included.

WHAT IS SHARED
--------------
  - The haystack. Everyone digs the same pile.
  - Buildings, placed and demolished.
  - Money, debt, hay sold, needles found, the collection.
  - The tech tree.
  - Uncovered needles. Everyone sees them, and they count once.
  - New hay loads, which resync every client.
  - Player positions, names and the tool in hand.
  - Loose items: buckets, sacks, bales, wads. You see what the others pick
    up, carry, drop and throw, and you can pick their things up yourself.
  - What is riding on the belts.

KNOWN LIMITATIONS
-----------------
  - Machines that turn hay into something (piston rake, robotic arm, drone,
    scanner, compressor, pulper, paper machine, press, wrapper, silo,
    pelletizer, launcher, hatch) only run on the host. Clients get the belts
    and the items they produce, but the machines themselves stand still.
    Running them everywhere counted the hay and the money twice.
  - Loose straw is local: what flies out when you dig and the hay on your
    fork. What it turns into (wads, tufts, bales) is shared.
  - Machine settings are not synced.
  - Bought tools are per player. Money is shared.
  - Only the host saves. Clients never write to their own saves.
  - The online leaderboard is disabled while the mod is loaded.

CREDITS
-------
  Farmer model: Ultimate Modular Men Pack by Quaternius, CC0.
  GodotSteam (GDExtension), MIT, https://godotsteam.com
  Steamworks SDK, (c) Valve Corporation.
  Source: https://github.com/AleDev11/FindTheNeedle-Coop-Mod
