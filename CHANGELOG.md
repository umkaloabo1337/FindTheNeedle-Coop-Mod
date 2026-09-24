# Changelog

## v0.13.0

* A guest who accepts an invite is told what is going on. A card lists the
  five steps (connecting, the host is picking a save, receiving the yard with
  the real transfer percentage, loading, in) and a line under it says what
  they should do, which is usually nothing. It gets out of the way once they
  land, and comes back if the host walks out to the menu.
* Joining, leaving and chat no longer drop a bare line of text in the middle
  of the screen. Each one is a card in the player's own colour, they stack,
  they fade on their own, and the same message twice gets a ×2 instead of a
  second card.
* The loading screen a guest sees while entering was hard-coded in Spanish.
  It follows the game's language like everything else now.
* Machines move smoothly instead of in steps. Their parts were chasing the
  newest pose with a fixed pull, so every packet gave them a shove and they
  coasted in between. Each part now walks from where it was to where it got
  to, over the gap between packets.
* A machine's parts are all sent again every couple of seconds. Poses travel
  on a channel that does not resend what it drops, so a part that moved once
  and stopped, like an arm parking or a lid closing, could stay wrong on the
  other screen for good. It also puts right anything that started out
  differently.
* Smoke, flames and lamps show up on machines that are not yours. The
  generator's smoke is a value inside a shader and its fire is a light, not
  particles, so a frozen machine looked cold. Those are copied now as well.
* Straw somebody throws lands where it lands instead of stuttering: copies
  slide to the position they were last seen at, and they are picked up twice
  as often, so they show the moment they leave a hand.
* A fistful of straw is drawn as a small pile, the one the belts carry,
  instead of a bundle of upright strands. It was also growing with every pose
  packet that arrived, which is how it ended up the size of a bale.

## v0.12.0

* Machines no longer come out crooked on the other screen. Each moving part
  was named by its place in the machine's list of child nodes, and that list
  is not the same on both sides: the game adds and drops nodes of its own as
  it runs (alert markers, dust, range rings). One extra node and every part
  was handed the pose of another. Parts are named by where they hang now.
* A part's orientation is sent whole instead of being rebuilt from a rotation
  and a scale, which straightened out the parts that are skewed, and the
  easing works axis by axis for the same reason.
* Straw somebody else dropped can be picked up. Their copies had no collision
  at all, so your hand went through them. They are solid now, and taking one
  hands it over: theirs goes, yours becomes real, and one straw stays one
  straw.

## v0.11.0

* You can see what somebody is holding. Straw picked up by hand shows in the
  remote farmer's fist, fanned out the way the game holds it, and a needle
  shows as the needle it really is. The pose packet carries one more number
  for it; nothing else changed on the wire.
* Straw held in a hand, a bucket or on a tool is no longer also scattered on
  everyone else's floor. It travels with whatever holds it.
* Other players see you push the wheelbarrow. Your farmer holds it by both
  handles, leans into it and puts the tool away, instead of standing next to
  a barrow that floats where your first-person view has it. It has a
  hand-placed pose for standing and one for crouching, both made in the tool
  poser (entry 7). Needs this version on both sides; older ones still see
  the loose barrow.

## v0.10.0

* Machines were never really stopped on clients. The game runs them from one
  central clock that walks its own list and only skips a machine whose physics
  processing is off, which `process_mode` does not touch. Nine of the fourteen
  we thought were parked kept eating hay, filling belts and making items on
  every player's machine at once, each with its own numbers. That is what made
  one player see a machine working and the other see it idle. They are out of
  the loop now.
* Machines move on clients again. The host sends where their moving parts are,
  which parts are drawn and which particles are running, so smoke, flames and
  lamps come across too. It makes no difference whether a machine is driven by
  an animation or from code.
* Machine settings are shared: switches, splitter filters and priorities, rake
  and pelletizer throw distance, launcher aim and power, silo and press stock,
  lamp brightness, and the generator's fuel and output, which is what the
  client's power grid reads to keep the yard running.
* Loose straw is shared. The straw you dig up now lands on everyone's floor.
  The copies have no physics and cannot be picked up, so a straw can never be
  turned into hay twice.
* Nobody was paying for a new load of hay. The client's charge never left,
  because ordering a load stops its updates first, and the host then undid its
  own charge assuming the client's was on the way.
* Needles that surface on their own as the pile is dug are announced by the
  host only. Both sides popping them out gave two bodies for one needle.

## v0.9.1

* Items somebody else owns can be picked up again. Their copy was moved by
  setting its transform, which on a frozen body leaves the collision shape
  where it was: you saw the bale in front of you while its shape sat back at
  the spot where it first appeared, so the pick-up ray went straight past it.
  Copies are now moved the way the game moves a held item, telling the
  physics server as well, and they are static rather than kinematic so they
  no longer shove anyone as they follow their owner.
* A player holding the toy shovel no longer shows a second, floating one to
  everyone else. The toy shovel is a real item even while held, and its copy
  followed the holder's first-person view next to the one in the farmer's
  hand. Copies of held tools are now hidden while they are up there.

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
