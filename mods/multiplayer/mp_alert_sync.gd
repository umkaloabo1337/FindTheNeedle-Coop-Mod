extends RefCounted

# A machine's sign and its panel's hint on a guest. Every machine works out
# its alert_reason() from its own state: the run timer, how long it starved,
# what sits in its mouth, the water and power it saw. A guest's machines are
# frozen and only carry the fields the host sends, so they reasoned from a
# standstill: the host's pulper said NO POWER while the guest's said NOT FED.
# The host sends what its machine says (reason and icon); a guest's machine is
# given a thin script on top of its own whose alert_reason()/alert_icon()
# answer with the host's words, so the sign, the panel, the production list
# and the run stats all read the same thing the game's own code shows.

const META := &"mp_alert"
const MAX_TEXT := 512
const DIR := "res://mods/multiplayer/mp_alert/"

var _wrappers := {}  # base Script -> wrapper Script (or null when it cannot be built)
var _hooks := {}     # instance id -> {"node": WeakRef, "base": Script, "wrapper": Script}


static func read(n: Node) -> Variant:
	if not n.has_method("alert_reason"):
		return null
	var reason := str(n.alert_reason())
	var icon := str(n.alert_icon()) if reason != "" and n.has_method("alert_icon") else ""
	return [reason.left(MAX_TEXT), icon.left(64)]


static func valid(v: Variant) -> bool:
	return v is Array and v.size() == 2 and v[0] is String and v[1] is String \
		and (v[0] as String).length() <= MAX_TEXT and (v[1] as String).length() <= 64


# Guest: what the host last said (read back for the field check).
static func shown(n: Node) -> Variant:
	return n.get_meta(META) if n.has_meta(META) else null


func apply(n: Node, v: Variant) -> void:
	if not valid(v):
		return
	n.set_meta(META, (v as Array).duplicate())


func wrapped(n: Node) -> bool:
	var hook: Dictionary = _hooks.get(n.get_instance_id(), {})
	return not hook.is_empty() and n.get_script() == hook.wrapper


# Guest: put the thin script on top of the machine's own. `replace` copies the
# script variables across (mp_machines' _replace_processor_script).
func wrap(n: Node, replace: Callable) -> void:
	if wrapped(n) or not n.has_method("alert_reason"):
		return
	var base: Script = n.get_script()
	if base == null or base.resource_path == "" or not base.resource_path.begins_with("res://"):
		return
	var wrapper: Variant = _wrappers.get(base, false)
	if wrapper is bool:
		wrapper = _build(base, n.has_method("alert_icon"))
		_wrappers[base] = wrapper
	if wrapper == null:
		return
	replace.call(n, wrapper)
	if n.get_script() == wrapper:
		_hooks[n.get_instance_id()] = {"node": weakref(n), "base": base, "wrapper": wrapper}


func _build(base: Script, with_icon: bool) -> Variant:
	var src := "extends \"%s\"\n\n" % base.resource_path
	# get_meta() with a null default still complains when the key is missing,
	# and the host's first word takes a field tick to arrive
	src += "func alert_reason() -> String:\n"
	src += "\tif has_meta(&\"mp_alert\"):\n"
	src += "\t\tvar a: Variant = get_meta(&\"mp_alert\")\n"
	src += "\t\tif a is Array and a.size() == 2:\n\t\t\treturn str(a[0])\n"
	src += "\treturn super.alert_reason()\n"
	if with_icon:
		src += "\nfunc alert_icon() -> String:\n"
		src += "\tif has_meta(&\"mp_alert\"):\n"
		src += "\t\tvar a: Variant = get_meta(&\"mp_alert\")\n"
		src += "\t\tif a is Array and a.size() == 2:\n\t\t\treturn str(a[1])\n"
		src += "\treturn super.alert_icon()\n"
	var script := GDScript.new()
	script.source_code = src
	if script.reload() != OK or not script.can_instantiate():
		push_warning("[mp] alert sign: cannot wrap %s" % base.resource_path)
		return null
	# the game tells machines apart by their script's file name (draw distance,
	# animation clipping); keep it
	# take_over_path: a wrapper from an earlier world (the host sent it again)
	# may still hold the path; setting resource_path then failed and left the
	# new one nameless
	script.take_over_path(DIR + base.resource_path.get_file())
	return script


# The script under the wrapper, for code that compares against the machine's
# own script (the processor hooks).
func base_of(n: Node) -> Script:
	var hook: Dictionary = _hooks.get(n.get_instance_id(), {})
	if not hook.is_empty() and n.get_script() == hook.wrapper:
		return hook.base
	return n.get_script()


func unwrap(n: Node, replace: Callable) -> void:
	var hook: Dictionary = _hooks.get(n.get_instance_id(), {})
	_hooks.erase(n.get_instance_id())
	if n.has_meta(META):
		n.remove_meta(META)
	if not hook.is_empty() and n.get_script() == hook.wrapper:
		replace.call(n, hook.base)


func prune() -> void:
	for id in _hooks.keys():
		if not is_instance_valid(_hooks[id].node.get_ref()):
			_hooks.erase(id)


func clear(replace: Callable) -> void:
	for id in _hooks.keys():
		var n: Variant = _hooks[id].node.get_ref()
		if is_instance_valid(n):
			unwrap(n, replace)
	_hooks.clear()
