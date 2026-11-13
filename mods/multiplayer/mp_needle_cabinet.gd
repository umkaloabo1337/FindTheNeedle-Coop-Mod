extends "res://scripts/build/needle_cabinet.gd"

var mp_needles: Node

func factory_tick(delta: float) -> void:
	if is_instance_valid(mp_needles) and mp_needles.mp.active() and not mp_needles.mp.is_host:
		return
	super.factory_tick(delta)

func prompt() -> String:
	var original := super.prompt()
	if int(GameState.mp_prestige.get("cycles", 0)) == 0:
		return original
	return original + "\n" + preload("res://mods/multiplayer/mp_prestige_state.gd").current_progress(GameState, NeedleTypes.pool(Cfg.DEMO_LAST_LOT), TranslationServer.get_locale())

# A press of the ending button is pressed on every player's case (mp_ending).
func press_ending() -> bool:
	var pressed := super.press_ending()
	if pressed and is_instance_valid(mp_needles) and mp_needles.mp.active() and is_instance_valid(mp_needles.mp.world_sync):
		var ending: Variant = mp_needles.mp.world_sync.get("ending_sync")
		if is_instance_valid(ending):
			ending.on_local_press(self)
	return pressed
