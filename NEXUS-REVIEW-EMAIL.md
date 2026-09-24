# Nexus Mods review request

Message to send to support@nexusmods.com when a release gets quarantined.
Update the version, the checksum and the mod link before sending.

---

Subject: Quarantined file, manual review request, Find The Needle Co-op Multiplayer (AleDev11)

Hello,

My mod's download has been quarantined and I would like to request a manual
review.

The upload no longer contains any script. The previous version shipped a .bat
installer and I removed it, so installing is now copying a folder and adding
two lines to a text file by hand. What is left that could trip the scanner is
two DLLs, so here is what they are and where they come from.

Mod page: https://www.nexusmods.com/findtheneedle/mods/1
Mod: Find The Needle Co-op Multiplayer
Author: AleDev11
File: FindTheNeedle_Multiplayer_v0.7.0.zip (1.5 MB)
SHA256: CF2C40C7B24B9B9B132AF9831355AA555F2626D8529E84F81104DAA65469DC37

The mod is open source, so every file in the archive can be checked against the
repository: https://github.com/AleDev11/FindTheNeedle-Coop-Mod

Contents of the archive:

- mp.gd, mp_ui.gd, mp_world.gd, mp_avatar.gd, mp_steam.gd, mp_i18n.gd:
  plain-text GDScript, the mod itself. The game is a Godot 4 title and loads
  them at startup.
- models/farmer.glb: a player model from Quaternius' Ultimate Modular Men
  Pack, CC0, trimmed to three animations.
- steam/win64/libgodotsteam.windows.template_release.x86_64.dll: GodotSteam,
  the MIT-licensed Steamworks plug-in for Godot. Official prebuilt release,
  unmodified: https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.22.1-gde
- steam/win64/steam_api64.dll: Valve's Steamworks SDK redistributable, as
  shipped inside that same GodotSteam package.
- godotsteam.gdextension, README.txt, LEEME.txt, models/CREDITS.txt: text
  files.

The mod adds co-op multiplayer to the game's demo. The demo ships without the
Steam API, so the mod loads GodotSteam at runtime and uses Steam's relay network
for the connection. That is what lets players invite each other from the Steam
friends list instead of forwarding a port.

One related note: the game itself, Find The Needle (free demo on Steam), was not
in your catalogue, so I submitted it as a suggested game when I created the
page. The mod is "awaiting approval" for that reason. If both can be looked at
together, all the better.

Both DLLs ship inside the download on purpose: the mod is for players, not for
developers, and asking them to fetch a library themselves and place it in the
right folder would make a simple mod hard to install. They are the unmodified
files from the official GodotSteam release, and the checksum above covers the
whole archive.

I am happy to answer any question or to provide anything else that helps the
review.

Thanks,
AleDev11
