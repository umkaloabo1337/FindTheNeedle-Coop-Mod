FIND THE NEEDLE - MULTIPLAYER (co-op) MOD  v0.5.0
==================================================

Unofficial mod for private use. Every player needs the game (the free Steam
demo) and THIS SAME mod in the SAME version.

No port forwarding and nothing else to install: the connection runs over
Steam's relay network, like any official co-op game.
(Spanish version of these notes: LEEME.txt)

INSTALL
-------
1. Copy the "mods" folder next to FindTheNeedle.exe
   (Steam > right-click the game > Manage > Browse local files).
2. Run  mods\multiplayer\INSTALL.bat
3. Start the game FROM STEAM. The main menu now has MULTIPLAYER.

To remove it: UNINSTALL.bat (puts the game back as it was).

IMPORTANT: after every game update, run INSTALL.bat again. The update
overwrites the file that registers the mod.

PLAYING
-------
Host (the one whose save is played):
  1. MULTIPLAYER > CREATE GAME
  2. INVITE FRIENDS (opens the Steam friends list), or let them join from
     your profile with "Join game".
  3. Start or load your save as usual: your friends appear in it.

Friends:
  Accept the Steam invite. Nothing to type. If the game was closed, Steam
  opens it and takes you straight in.

There is also a direct-IP mode under CONEXION POR IP (AVANZADO) as a fallback.

KEYS
----
  F2  multiplayer panel (also in game)
  Y   chat
  F8  resync the world if something looks different

LANGUAGES
---------
  The mod follows the language you set in the game. English, Spanish,
  German, French, Italian, Czech, Polish, Russian, Turkish, Japanese,
  Korean and Chinese are included.

WHAT IS SHARED
--------------
  - The haystack: what one digs, everyone sees.
  - Buildings: placing and demolishing structures, conveyors, platforms.
  - Money, debt, hay sold, needles found and the collection.
  - The tech tree.
  - Uncovered needles: visible to all, handed in only once.
  - New hay loads (everyone is resynced).
  - You see each other with Steam names and the tool in hand.

LIMITATIONS OF THIS VERSION
---------------------------
  - Machines that feed themselves from the pile (piston rake, robotic arm,
    drone, scanner) run only on the host; on clients they stand still.
  - Loose props (buckets, sacks, bales) are per-player.
  - Machine settings (filters, switches) are not shared.
  - Bought tools are per-player (money is shared).
  - Only the host saves. Clients never touch their own save files.
  - The online leaderboard is disabled while the mod is active.

THIRD-PARTY CREDITS
-------------------
  GodotSteam (GDExtension) - MIT - https://godotsteam.com
  Steamworks SDK (steam_api64.dll) - (c) Valve Corporation
