extends RefCounted

# The depot panel's "in / out per minute". The panel counts them itself from
# the depot changes it sees, and a guest's depot is frozen: its panel showed 0
# for every kind while the host's counted (measured: +36 / -224 hay bales a
# minute on the host, 0 / 0 on the guest, with the stock equal to the piece).
# The host keeps a hidden copy of the game's own panel and reads its rates; a
# guest's panel answers with the host's numbers.

const PANEL := "res://scripts/ui/depot_panel.gd"
const MAX_KINDS := 64

var _counter: Node = null      # host: a hidden depot panel that only counts
var _patched: Node = null      # guest: the world's panel answering from rates
static var _rate_script: Script = null


# Host: {kind: [in, out]} per minute, only kinds that move.
func host_rates(owner: Node, builds: Node) -> Dictionary:
	if not _ensure_counter(owner, builds):
		return {}
	var out := {}
	if not _counter.has_method("kinds") or not _counter.has_method("rate"):
		return out
	for id in _counter.kinds():
		if out.size() >= MAX_KINDS:
			break
		var a := snappedf(float(_counter.rate(id, 1)), 0.1)
		var b := snappedf(float(_counter.rate(id, -1)), 0.1)
		if absf(a) > 0.0 or absf(b) > 0.0:
			out[str(id)] = [a, b]
	return out


func _ensure_counter(owner: Node, builds: Node) -> bool:
	if is_instance_valid(_counter):
		return true
	if builds == null or not is_instance_valid(owner):
		return false
	var depot: Node = null
	for n in builds.get("wrappers"):
		if is_instance_valid(n) and n is Depot:
			depot = n
			break
	if depot == null:
		return false
	var scr: Script = load(PANEL)
	if scr == null:
		return false
	_counter = scr.new()
	_counter.name = "MPDepotRateCounter"
	owner.add_child(_counter)
	if _counter is CanvasItem:
		(_counter as CanvasItem).hide()
	elif _counter.has_method("hide"):
		_counter.call("hide")
	_counter.set("_depot", depot)
	if _counter.has_method("_resync"):
		_counter._resync()
	return true


func shutdown() -> void:
	if is_instance_valid(_counter):
		_counter.queue_free()
	_counter = null
	# after the session the panel counts for itself again
	if is_instance_valid(_patched) and "mp_rates" in _patched:
		_patched.set("mp_rates", {})
	_patched = null


# Guest: hand the host's rates to the world's depot panel.
func apply(world: Node, rates: Variant) -> void:
	if not (rates is Dictionary) or (rates as Dictionary).size() > MAX_KINDS or not is_instance_valid(world):
		return
	var panel: Variant = world.get("depot_panel")
	if not is_instance_valid(panel):
		return
	if panel != _patched:
		if not _patch(panel):
			return
		_patched = panel
	var clean := {}
	for id in rates:
		var row: Variant = rates[id]
		if row is Array and row.size() == 2 and (row[0] is float or row[0] is int) and (row[1] is float or row[1] is int) \
				and is_finite(float(row[0])) and is_finite(float(row[1])):
			clean[str(id)] = [float(row[0]), float(row[1])]
	panel.set("mp_rates", clean)


func _patch(panel: Node) -> bool:
	if "mp_rates" in panel:
		return true
	var base: Script = panel.get_script()
	if base == null or base.resource_path != PANEL:
		return false
	if _rate_script == null:
		_rate_script = _build_script(base)
	if _rate_script == null:
		return false
	var saved := {}
	for property in panel.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			saved[property.name] = panel.get(property.name)
	panel.set_script(_rate_script)
	for key in saved:
		if key in panel:
			panel.set(key, saved[key])
	return "mp_rates" in panel


# The override must repeat rate()'s exact signature, which the game declares
# with types; read it off the script rather than guess it.
static func _build_script(base: Script) -> Script:
	var info: Dictionary = {}
	for m in base.get_script_method_list():
		if m.name == "rate":
			info = m
			break
	if info.is_empty() or info.args.size() != 2:
		return null
	var params := []
	for a in info.args:
		var t := ""
		if int(a.type) != TYPE_NIL:
			if int(a.type) == TYPE_OBJECT:
				t = (": " + String(a.class_name)) if String(a.class_name) != "" else ""
			else:
				t = ": " + type_string(int(a.type))
		params.append(String(a.name) + t)
	var ret := ""
	var r: Dictionary = info["return"]
	if int(r.type) != TYPE_NIL:
		ret = " -> " + type_string(int(r.type))
	var id_name := String(info.args[0].name)
	var sign_name := String(info.args[1].name)
	var src := "extends \"%s\"\nvar mp_rates := {}\nfunc rate(%s)%s:\n\tvar row: Variant = mp_rates.get(str(%s))\n\tif row is Array and row.size() == 2:\n\t\treturn row[0] if int(%s) > 0 else row[1]\n\tif not mp_rates.is_empty():\n\t\treturn 0.0\n\treturn super(%s, %s)\n" % [PANEL, ", ".join(params), ret, id_name, sign_name, id_name, sign_name]
	var scr := GDScript.new()
	scr.source_code = src
	if scr.reload() != OK:
		return null
	return scr
