# Changelog

## Unreleased

- **Remote players are an animated farmer.** A rigged low-poly farmer
  (Quaternius, CC0) replaces the figure made of primitives. The overalls and
  the hat band take the player's colour, the head follows the look pitch, the
  right arm reaches forward with the tool, the knees bend when crouching, and
  the clip follows the real speed (Walk when slow, Run at walking and sprint
  speed). The model adds 500 KB; if it is missing, the old figure is used.
- **Held tools at their real size.** Each tool is scaled to a real-world length
  instead of 1.2 m for all, so the metal detector is no longer as long as a
  spade.

## v0.4.0

- **Installer rewritten as plain batch.** `INSTALL.bat` and `UNINSTALL.bat` no
  longer call PowerShell with an execution-policy bypass. They are short,
  readable scripts that add (or remove) one line in `override.cfg` — easier to
  audit, and friendlier to Nexus Mods' file checks.
- **Game updates no longer lose the developer's settings.** The installer takes
  the current `override.cfg` as its base instead of restoring an old backup, so
  anything a game update added is kept.
- **Held tools face the right way.** Remote players were holding the spade and
  the pitchfork by the head; the model is now turned 180 degrees. `flip_tool`
  on the avatar turns it back, which helps when trying out new tool models.
- Tested on game build V30.

## v0.3.0

- **Streamer safety:** the panel no longer prints IP addresses, Steam IDs or
  lobby codes. Local addresses only appear after pressing *Show my IPs*, which
  lives in the advanced section.
- **Clearer panel:** numbered steps (create game → invite friends → start
  playing) with the current one highlighted, and the IP mode folded away as an
  advanced option.
- English installer scripts (`INSTALL.bat` / `UNINSTALL.bat`) beside the
  Spanish ones.

## v0.2.0

- **Steam networking.** Hosting, invites and joining now go through Steam's
  relay: no port forwarding, no IPs, no VPN. The mod loads the GodotSteam
  GDExtension at runtime and initialises Steam under the demo's app id.
- Invite from the Steam overlay, from the friends list, or by accepting an
  invite while the game is closed.
- Player names come from Steam.
- Loose needles are shared: uncovered needles show up for everyone and can only
  be handed in once.
- Clients spawn at the game's normal starting spot.
- Remote players got arms and hold their tool properly.
- Panel rebuilt: centred, dimmed background, no more broken labels.

## v0.1.0

- First working co-op build over direct IP (ENet).
- Shared haystack, buildings, economy and tech tree.
- The host's world is handed to joining players through the game's own save
  format; clients never write to their own saves.
- Remote player avatars with name tags, chat (`Y`), resync (`F8`).
