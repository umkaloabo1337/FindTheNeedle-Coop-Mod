# Find The Needle co-op mod

Maintained by **umka1337**. Based on [AleDev11’s co-op mod](https://github.com/AleDev11/FindTheNeedle-Coop-Mod) (thanks for the original mod and the idea) and on the maintenance builds by **xRangerDE** (thanks for the groundwork). Current version `0.19.6-umka1337.94`, for the Early Access game on Windows/Steam.

The multiplayer menu follows three steps: create a session, invite friends, then select a save. Hosts can open the native save selector directly; guests see their actual connection and loading status. Direct IP connections remain available in the expandable advanced section.

Sessions support up to **eight players in total: one host and seven guests**. Upgrades and the account are shared; carried equipment remains personal. Every player needs the game and the same mod version. Optional Production Speed, Tool Upgrades and Autonomous Mice add-ons are installed separately; they are not included in the main ZIP. Never share your personal `mp_settings.cfg`, saves or diagnostic logs as part of an installation package.

## Balanced prices and legacy credit

Bucket capacity upgrades now cost 10,000 in total, faster pouring 12,000, and precise needle location 7,500. Sale ranks 5–8 cost 250, 300, 350 and 365. Existing ranks are never reduced or charged again.


Sale price now has 20 ranks, each adding five percentage points to the base price (up to ×2). All purchased upgrade levels are preserved. The 20-rank sale-price ladder has a monotonic price curve and still costs 12,885 in total. Seventeen upgrade ladders use fixed total budgets and no additional native late-rank surcharge.

When loading an older save, recorded overpayments for the repriced ranks are credited once, deducting refunds already received in .53 to the shared balance. Only the host or single-player performs this calculation. The credit marker and balance are stored in the same save snapshot; guest joins and repeat loads cannot pay it again. Gifted ranks and purchases without a recorded paid amount are not assigned an estimated refund. Existing saves are not modified by copying the mod files; the credit applies on the next load and is retained when the game is saved.

## Install

Download the ZIP from [Releases](https://github.com/umkaloabo1337/FindTheNeedle-Coop-Mod/releases).

1. Close the game and keep a backup of the existing mod and saves.
2. Copy the ZIP’s `mods` folder beside `FindTheNeedle.exe` (Steam: right-click the game → Manage → Browse local files).
3. Open `override.cfg` in the same folder and make sure it contains:

   ```
   [autoload]
   MPMod="*mods/multiplayer/mp.gd"
   ```

   Keep your existing settings and any other add-on autoload entries.
4. **Recommended for big yards** (otherwise the screen can go black after about an hour, D3D12 "not enough room in the RESOURCES descriptor heap"):

   ```
   [rendering]
   rendering_device/d3d12/max_resource_descriptors=262144
   ```

   If `[rendering]` already exists, add only the second line under it. If the line is missing, the mod adds it itself on the first start (the old file is kept as `override.cfg.mp_backup`); it applies from the next start.
5. Start through Steam. The host opens a lobby and loads the existing save; friends join through Steam invitations.

Game updates replace `override.cfg`; add the lines again after one. Every player needs the same mod version. See the [English](mods/multiplayer/README.txt), [German](mods/multiplayer/ANLEITUNG-DE.txt) and [Spanish](mods/multiplayer/LEEME.txt) instructions for detailed controls.

## New in 0.19.6-umka1337 (.87–.94)

- **Smoother belts for guests.** Mergers and splitters run on guests too; a belt that differs from the host's is corrected rider by rider instead of being emptied and refilled; riders renamed at a seam are recognised; queues in front of machines move up smoothly. Near a walking guest the share of riders seen jumping fell from 18–28% to 7–17%, also with 80–150 ms extra delay. Belts are not perfect yet: belts inside machines still show the host's picture.
- **The ending for everyone.** The needle case's button is pressed on every case, the forged key is one key for all (picked up, it goes for the others; put down, it lies there for everyone), the key turned in the floor hatch opens it everywhere, and the show below starts for everyone. Afterwards everyone stays in the yard and the host saves again.
- **Lost key:** if the delivery board says the key is out but nobody can find it, type `/schluessel` (or `/key`, `/llave`) in the chat (Y). The key is put at your feet for everyone.
- **Creative mode (sandbox)** from the game update of 13.11. works for guests: free building, everything unlocked, the F1 sandbox menu, and spawned items reach everyone. The cozy mode and the yard layout (shed, stand and shop spot) also come from the host.
- **Machine signs and panel hints** on guests say what the host's machines say (e.g. NO POWER instead of NOT FED).
- **Delivery truck:** its load stays laid out on guests between contracts.
- **Depot:** stock, refused kinds, limits and the in/out rates match on all players.
- **Jetpacks** of other players show their flames, smoke and glow.
- **Dropped connections** are written to `%APPDATA%\Godot\app_userdata\FindTheNeedle\mp_drops.log` (time, ping, Steam's reason and the events before). The file survives a restart; after a drop, send it from both sides together with `mp_trace.log`.

The full list is in the [changelog](CHANGELOG.md).

## Other mods and removal

The compatibility bridge supports the checked versions of Production Speed (0.3.19), Collection Tool Upgrades (0.1.0) and Autonomous Mice (0.1.6). It adapts their scripts in memory and leaves their files unchanged. Production Speed can still report capped scanner-speed ranks when Multiplayer Enhanced loads first or loads the add-ons automatically; this update does not remove that limit.

To remove Multiplayer Enhanced, close the game, remove only the `MPMod` entry from `override.cfg`, and remove only `mods/multiplayer`. Keep the other mod folders and their autoload entries. If an older installation replaced your configuration, restore the missing entries from your backup or the affected mods’ installation instructions. Removing a folder cannot restore overwritten configuration. The bridge is no longer active after removal; each remaining add-on must support your game version independently. Mod-specific data already saved in a world is not reverted by uninstalling.

## Language support

New action hints cover all 17 language options in the current game. The guided multiplayer panel and core multiplayer alerts cover all 17 locales, including right-to-left layout for Arabic and Persian. Remaining untranslated legacy descriptions use English.

## New controls and upgrades

- **Robot arms:** Arm Carry Size retains eight ranks up to +64% and costs 80,000 in total. Arm Spacing unlocks after the Standard Arm blueprint and reduces the required spacing by five percentage points per rank, down to 50%, for 150,000 in total. Working reach and physical base clearance remain unchanged. Existing purchased ranks are retained.

- **Building controls:** hold R and move the mouse horizontally for free rotation; tap R for the original steps. F6 reverses the belt being drawn. F9 (rebindable in Controls) follows adjacent conveyors at arbitrary horizontal angles and through connected bends. Long conveyor runs are split into connected native sections in one placement, retaining per-metre costs. Connection and collision checks still apply. Aim at an existing empty machine and hold R to rotate it; left-click confirms and right-click cancels. In F7 view, hover a machine and press E for its settings. The Devices panel can switch machines and complete conveyor lines for all players.
- **House building:** walls snap to exposed platform edges in native wall modules. Roofs align with wall tops and eaves. Optional charcoal, cream, red and green wall/window/door variants retain the native materials and save their color.
- **Supply Co:** aim at the shop and press N to move it with a placement preview. Left-click confirms and right-click cancels. The shop, interaction point and item delivery point move together; the host saves and shares the location.
- **Sale stations:** look at an empty sale station and press N to enter its placement preview. The native hint bar shows the selected key; an unused alternative is chosen if N is assigned. After confirmed pickup, carry the station away from its old location. Right-click cancels; E opens settings. Four upgrade ranks unlock up to five total sale stations; extra compact scales cost 500 each and use the same prices and shared account. Moving a loaded or unsettled station is blocked. The original stand remains available in old saves.
- **Direct arm connections:** arms can deliver directly into merger/splitter paths and take cargo from their paths. Manual links survive saves and resynchronization. The native merger scheduler preserves continuous center movement and scales with transport upgrades.
- **Right-click hopper intake:** while aiming at the hopper, right-click to transfer carried raw hay from your hand, shovel, pitchfork, sand shovel or vacuum. Partial transfers leave the unaccepted remainder in its source; embedded needles stay attached until the complete corresponding load enters. M remains available for the vacuum.
- **F7 building camera:** toggle the overhead view directly, then use B to select a building. WASD or arrows pan, Shift pans faster, the wheel zooms, left click places and right click cancels the current step. F7 or Escape restores the previous view. The overhead camera covers the playable map and zooms out to 128 m. Hall roofs, including extensions, and the stand canopy are hidden in this view so objects below remain visible and selectable. Each player can use a separate overhead view; machine animations and loose straw also synchronize within that viewport. Building remains subject to host validation, map boundaries and placement checks. F7 takes priority over the native debug-report binding. Ctrl+F7 still opens the report; other customized F7 actions are respected. Use PageUp/PageDown to change building height while arrow keys pan.
- **Loading Hopper:** a 2,500-cost structure. Place it freely or at a belt input. Press **M** while aiming at it to transfer vacuum contents, throw loose hay into the opening, or use a robotic arm. **E** controls output and portions from 100 to 1,000 (limited by belt upgrades), and purchases per-hopper capacity from 10,000 to 100,000. Existing hoppers keep their 50,000 capacity and contents. Full hoppers retain the unaccepted remainder.
- **Four/six/eight-port mergers and splitters:** two independent paid unlock chains, each 4 → 6 → 8 after Smart Splitter. Unlock prices are 1,500 / 4,000 / 8,000; each structure then costs 2,000 / 3,500 / 5,000 to build. A merger combines 3/5/7 inputs into one output; a splitter routes one input to 3/5/7 outputs, skipping blocked exits. Insert directly into a straight, level conveyor or place freely. Existing belt material is credited and cargo retained; a blocked insertion leaves the original belt unchanged. Existing mergers remain functional. New construction needs the new unlock. **E** selects the merger output or splitter input only when empty. Numbered side plates, native rollers and animated directional tread sectors identify the connections.
- **Larger Belt Portions:** 100 → 200 → 300 → 500 → 1,000 strands per portion for direct M output and hoppers. Four upgrades cost 25,000 in total. A blocked belt retains the hay in the vacuum or hopper.
- **Arm speed:** 20 total ranks; all 20 ranks cost 80,000 combined. Already purchased ranks are preserved.
- **Lift / stairs speed:** ten ranks up to four times their base transport speed, in addition to the belt motor. Existing ranks are preserved.
- **Splitter / merger speed:** ten ranks up to 250% internal speed, 40,000 combined. Applies to normal, compact, U, smart and T variants. Filters and blocked exits still apply.
- **Double Jump:** one shared 2,500 purchase in Fitness after Spring Heels. Release jump after taking off, then press again for one extra airborne jump. Landing restores it. An equipped jetpack retains its own control behavior.
- **Next Load details:** remaining buried needles and the number of represented types are shown on the delivery board and in its detail window.

Existing vacuum upgrades reach 50,000 capacity across 41 ranks and 1,000 strands/second at suction rank 20, with the complete capacity ladder costing 300,000 and the complete suction ladder costing 200,000. Outside direct belt/hopper transfers, M retains its existing physical-output behavior. The separate `drop_all.gd` is not needed.

The hopper has an industrial steel model and a matching image in the building catalog and hotbar. Its native hay surface follows the stored amount and stays inside the sloping walls. A brief intake effect runs only on a stock increase; restored contents and repeated snapshots do not replay it. The effect is visual only and creates no collectible hay. Its stock and controls appear in a readable HUD card. Single-player uses local checked transactions for construction and vacuum transfer, without opening a network session.

## Guest vacuum recovery

Vacuum fill and pending direct-transfer reservations are stored in `user://mp_vacuum_guest.0.dat` and `user://mp_vacuum_guest.1.dat`. These are private local recovery files; do not distribute them with the mod. Unchanged fill does not cause disk writes. Failed journal reads or writes lock the vacuum and report the problem instead of clearing the recovery data.

## Prestige and scanner dismantling

Use the delivery board’s Next Load sheet, then **Prestige · New map**. The host (or single-player) can preview the sale and select Standard, Large, Huge or Mountain once the physical haystack is empty and all six needle types have been collected. Buildings and saleable goods are converted to money, while tools, unlocks and purchased upgrades are retained. A new cycle requires its six needle types again. A backup is written before the map changes.

Scanners can be dismantled with needles inside. Unique unclaimed needles are placed on the floor; a needle already held by a player is not spawned again.

## Synchronization fixes

Needle pickup, scanner withdrawals and cabinet deposits now use host-owned identities. Repeated or competing requests cannot spend the same identity twice. Duplicate scanner references are normalized; separate needles of the same type remain separate. Historical cabinet stock is not deleted based on guesses about its origin.

Press recovery also covers raw physical riders beyond its intake and raw hay on a directly connected wrapper deck. Guest pelletizer changes are queued before the first host baseline can overwrite them. Splitter/merger jam detection compares actual cargo movement, while keeping native filtering and backpressure.

Robotic-arm operating status, claw loads and income/minute come from the host. Water-tap recovery, personal tool inventories, shared quests and purchases, host-side selling, mouse visuals and prior conveyor/lift corrections remain included. Stable machine hierarchies reuse cached part mappings; changed hierarchies rebuild them.

## Synchronization performance

Unchanged hayfield height buffers now skip the per-vertex GDScript scan after an exact comparison. Changed and restored heights still use the existing delta publication. An isolated native comparison measured 451 microseconds versus 2 microseconds median per unchanged-field call; this is a routine-level CPU measurement, not a total frame-rate result.

The local checks include 1,200 conveyor records, a guest process crash and rejoin, and production through a press, wrapper, scanner and 90-degree bend to sale. Downward-lift tests cover eight item kinds, backpressure and a junction rebuild. Guest vacuum contents now use the recovery journal described below.

## Verification and limits

Releases from 0.19.6-umka1337 on are tested with a host and a guest of the Early Access game (including the update of 13.11.2026) on one PC, headless, with the players' own saves (a mid-game yard and an endgame yard). Belt smoothness is measured as the share of riders near a walking guest that visibly jump or vanish. Earlier validation combined isolated GDRE/Godot tests with native headless demo instances using the BeltRunCore extension (Demo V66, Steam build 25963876; older results refer to V62). Separate host and guest save directories protect existing saves. Local multiplayer tests cover scanner inventory, competing and repeated purchases, personal tool transfers, vacuum/hopper quantities, production routes and the complete prestige save/reload. Packet loss and duplication are injected on loopback; Steam multiplayer is not started.

These results do **not** establish GPU frame rates, a two-PC Steam/WAN session, or freedom from every possible bug. Headless runs cannot measure rendered graphics performance. The supplied older game copy identifies as V33 and was not used as the V62 compatibility baseline. Host and single-player saves now include the vacuum fill and matching transfer reservation in the same snapshot as the world. Loading restores that snapshot once, including an uncommitted reservation or a transfer already received by a hopper. A save is deferred while shared floor cleanup is pending, and pause-menu exit waits for a successful save. A guest process restart now restores its last committed vacuum fill from a local journal scoped to the player profile and world. Open direct belt/hopper transfers are reconciled against host receipts before the vacuum is unlocked. The journal uses two checked generations and ignores incomplete writes. Keep the same local profile and host world when reconnecting. Recovery of unconfirmed local cleanup reports and rollback of a host to an earlier world snapshot remain outside this fix. Unsaved progress after a host crash still rolls back to the last successful save.

Only the host saves the shared world. Tools remain personal. Machines simulate on the host, with guest visual replication. Keep both installations on the same release and back up a save before changing mod versions. Do not downgrade a save containing new hoppers without a compatible backup.

## Credits and source

Maintained by umka1337. Original multiplayer mod and idea: [AleDev11](https://github.com/AleDev11/FindTheNeedle-Coop-Mod) — thank you. Maintenance builds up to 0.19.6-xRangerDE.93, which this release builds on: xRangerDE — thank you. Farmer model: Quaternius, CC0. GodotSteam: MIT. Steamworks SDK: Valve Corporation. The hopper shell is original procedural geometry in this fork; its feeder and cabinet detail reference installed game resources at runtime. Game binaries, decoded game sources, private saves and local test fixtures are not distributed in this repository.

The optional [Production Speed Update](https://www.nexusmods.com/findtheneedle/mods/9), [Collection Tool Upgrades](https://www.nexusmods.com/findtheneedle/mods/11) and [Autonomous Mice](https://www.nexusmods.com/findtheneedle/mods/7) originated with BadHippo. Their additional production/tool ranks and autonomous mouse behavior are separate from this fork's multiplayer integration and balance changes. The main ZIP does not include those add-ons. The integrated M-key transfer does not require the separate [Vaccuum Drops All](https://www.nexusmods.com/findtheneedle/mods/24) by Pruplexedv6.
