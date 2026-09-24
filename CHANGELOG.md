# Changelog

## v0.9.0

* Held tools are placed by hand. Each of the six tools has its own position,
  angle and length in the farmer's hand (`tool_poses.cfg`) instead of the
  automatic guess, which held them like spears and the toy shovel upside down.
  Five of them also have a crouch pose that the farmer eases into when
  crouching. Tools without an entry keep the automatic fit.
* `dev/tool_poser.gd` (not shipped) is the tool used to place them: an empty
  stage with a move/rotate gizmo, started with `dev/tool_poser.bat`.

## v0.8.0

* Loose items are shared. Buckets, sacks, bales and wads now exist once for
  the whole session: whoever made an item sends where it is, and picking up
  someone else's item hands it over to you. Items that a remote player owns
  are held still locally, so the yard cleaner and the machines leave them
  alone.
* Belt contents are shared. The host sends the ride list a few times a second
  and clients board it on their own belts, which keep turning in between, so
  the boxes and bales move instead of jumping.
* More machines are host-only, now that the belts and the items they make
  arrive over the wire: compressor, pulper, paper machine, briquette press,
  wrapper, silo, pelletizer, tube launcher, dump hatch and needle radar join
  the rake, the arm, the drone and the scanner. Running them on both sides
  would have turned the same hay into two bales.
* F6 opens the game's own debug menu, with buttons added for taking money
  away as well as granting it. Handy for setting up a session. The game marks
  a run that used it, so it no longer counts for the leaderboards.

## v0.7.0

* Remote players stand straight when idle. The old idle clip had the hips
  twisted and left the feet where the last step put them, so the shoes
  stretched after walking.
* Farmer height and crouch tuned in game so eyes meet at the camera height,
  standing and crouched. `dev/avatar_calib.gd` is the tool used for it.
* You can see your own body when you look down during a session: headless,
  a bit behind the camera, in your colour, with your shadow. Single player
  is unchanged.

## v0.6.0

* An optional install helper lives in `tools/` and is attached to the release,
  for anyone who would rather not edit `override.cfg` by hand. It is kept out
  of the download so the archive carries no scripts.

* No scripts in the download. The autoload line now uses a path relative to
  the game folder, so it is the same on every machine: copy the mods folder
  and add two lines to override.cfg by hand. The .bat installers are gone.
* Tested on game build V30.

## v0.5.0

* Remote players are an animated farmer (Quaternius, CC0) instead of a figure
  made of primitives. The overalls and the hat band take the player's colour,
  the head follows the look pitch, the knees bend when crouching, and the clip
  follows the real speed. The model adds 500 KB; if it is missing, the old
  figure is used.
* Held tools are scaled to a real-world length each, so the metal detector is
  no longer as long as a spade.
* The interface follows the game's language. English, Spanish, German, French,
  Italian, Czech, Polish, Russian, Turkish, Japanese, Korean and Chinese are
  included; anything else falls back to English. Tool names come from the
  game's own translations.

## v0.4.0

* Rewrote the installer as plain batch. `INSTALL.bat` and `UNINSTALL.bat` no
  longer call PowerShell with an execution-policy bypass. They are short
  scripts that add or remove one line in `override.cfg`.
* The installer now takes the current `override.cfg` as its base instead of
  restoring an old backup, so settings added by a game update survive.
* Turned the held tool models 180 degrees. Remote players were holding the
  spade and the pitchfork by the head. `flip_tool` on the avatar turns a model
  back, which helps when trying out new ones.
* Tested on game build V30.

## v0.3.0

* The panel no longer prints IP addresses, Steam IDs or lobby codes. Local
  addresses only show after pressing "Show my IPs", in the advanced section.
* Numbered steps in the panel (create game, invite friends, start playing) with
  the current one highlighted. The IP mode is folded away as an advanced option.
* Added English installer scripts next to the Spanish ones.

## v0.2.0

* Steam networking. Hosting, invites and joining go through Steam's relay, so
  there is no port forwarding and no IP addresses. The mod loads the GodotSteam
  GDExtension at runtime and initialises Steam under the demo's app id.
* Invites from the Steam overlay, from the friends list, or by accepting one
  while the game is closed.
* Player names come from Steam.
* Uncovered needles are shared. They show up for everyone and can only be
  handed in once.
* Clients spawn at the game's normal starting spot.
* Remote players got arms and hold their tool properly.
* Rebuilt the panel: centred, dimmed background, no more broken labels.

## v0.1.0

* First working co-op build over direct IP (ENet).
* Shared haystack, buildings, economy and tech tree.
* The host's world is handed to joining players through the game's own save
  format. Clients never write to their own saves.
* Remote player avatars with name tags, chat (Y) and resync (F8).
