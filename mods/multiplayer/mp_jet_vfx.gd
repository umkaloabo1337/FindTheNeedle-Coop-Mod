extends "res://scripts/vfx/jetpack_vfx.gd"

# Another player's jetpack: the game's own flames, smoke and glow, lit while
# that player's pose says they thrust. The game's version reads its player's
# Jetpack, which a puppet has none of, so this one is told instead.
# Loaded only when the game has a jetpack (mp_avatar checks for the file).

var mp_lit := false


func _process(delta: float) -> void:
	_t += delta
	if mp_lit != _lit:
		_lit = mp_lit
		for f in flames:
			if is_instance_valid(f):
				f.emitting = _lit
		if is_instance_valid(smoke):
			smoke.emitting = _lit
	if not is_instance_valid(glow):
		return
	_glow = lerpf(_glow, 1.0 if _lit else 0.0, 1.0 - exp(-GLOW_RAMP * delta))
	var flicker := 1.0 + 0.15 * sin(_t * 31.0) + 0.1 * sin(_t * 13.7 + 1.3)
	glow.light_energy = GLOW_ENERGY * _glow * flicker
	glow.visible = _glow > 0.01
