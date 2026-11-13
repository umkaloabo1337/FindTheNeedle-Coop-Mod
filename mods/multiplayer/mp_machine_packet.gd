extends RefCounted

const ArmVisual = preload("res://mods/multiplayer/mp_arm_visual.gd")

static func valid(batch: Variant) -> bool:
	if not (batch is Dictionary):
		return false
	for key in batch:
		if not (key is String) or not (batch[key] is Dictionary):
			return false
		var entry: Dictionary = batch[key]
		if entry.has("a") and not ArmVisual.valid(entry.a):
			return false
		if entry.has("i") != entry.has("t") or entry.has("xi") != entry.has("xv"):
			return false
		if entry.has("i"):
			if not (entry.i is PackedInt32Array) or not (entry.t is PackedFloat32Array):
				return false
			if entry.i.size() > 120 or entry.t.size() != entry.i.size() * 12:
				return false
			if not _finite(entry.t):
				return false
		if entry.has("f"):
			if not (entry.f is PackedInt32Array) or entry.f.size() > 240 or entry.f.size() % 2 != 0:
				return false
		if entry.has("xi"):
			if not (entry.xi is PackedInt32Array) or not (entry.xv is PackedFloat32Array):
				return false
			if entry.xi.size() != entry.xv.size() * 2:
				return false
			if not _finite(entry.xv):
				return false
	return true


# No infinity or NaN in the numbers. A script loop over every value cost a
# guest more than applying the poses did. The array's own search finds the
# infinities natively, and a NaN anywhere makes a sum NaN, so one sum covers
# it, added twelve values (one transform) at a time.
static func _finite(values: PackedFloat32Array) -> bool:
	if values.has(INF) or values.has(-INF):
		return false
	var total := 0.0
	var at := 0
	var n := values.size()
	while at + 12 <= n:
		total += values[at] + values[at + 1] + values[at + 2] + values[at + 3] + values[at + 4] + values[at + 5] + values[at + 6] + values[at + 7] + values[at + 8] + values[at + 9] + values[at + 10] + values[at + 11]
		at += 12
	while at < n:
		total += values[at]
		at += 1
	return is_finite(total)
