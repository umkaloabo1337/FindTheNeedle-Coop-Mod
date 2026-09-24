FIND THE NEEDLE CO-OP MOD  v0.7.0
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

Keys:  F2 panel   Y chat   F8 resync the world

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

KNOWN LIMITATIONS
-----------------
  - Machines that take hay from the pile on their own (piston rake, robotic
    arm, drone, scanner) only run on the host; on clients they stand still.
  - Loose props (buckets, sacks, bales) are local to each player.
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
