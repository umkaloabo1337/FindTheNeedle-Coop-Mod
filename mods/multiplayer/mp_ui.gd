# UI for the multiplayer mod: lobby panel (F2 or the menu's MULTIPLAYER entry),
# notification feed, chat (Y) and the player list.
extends CanvasLayer

const COL_TITLE := Color(1.0, 0.86, 0.34)
const COL_TEXT := Color(0.95, 0.96, 0.99)
const COL_DIM := Color(0.7, 0.73, 0.79)
const COL_BG := Color(0.03, 0.04, 0.06, 0.92)
const FEED_SECONDS := 7.0

var mp: Node

var _root: ColorRect
var _panel: PanelContainer
var _name_edit: LineEdit
var _ip_edit: LineEdit
var _port_edit: SpinBox
var _status: Label
var _progress: ProgressBar
var _players_label: RichTextLabel
var _host_btn: Button
var _steam_host_btn: Button
var _invite_btn: Button
var _steam_label: Label
var _ip_toggle: Button
var _ips_btn: Button
var _steps_label: RichTextLabel
var _help_label: Label
var _close_btn: Button
var _title_label: Label
var _subtitle_label: Label
var _show_ips := false  # never show addresses unless asked (streamer safety)
var _ip_box: VBoxContainer
var _join_btn: Button
var _leave_btn: Button
var _resync_btn: Button
var _ips_label: Label

var _feed: VBoxContainer
var _chat_edit: LineEdit
var _roster: RichTextLabel
var _mouse_was_captured := false


func _ready() -> void:
	layer = 110
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_feed()
	_build_roster()
	_build_chat()
	_build_panel()
	refresh()


# ---------------------------------------------------------------- building

var _font_cache: Font = null
var _font_tried := false


# the game's bold UI font, if its UiFont helper is there
func _font() -> Font:
	if not _font_tried:
		_font_tried = true
		var cls := _global_class("UiFont")
		if cls != null:
			_font_cache = cls.call("bold")
	return _font_cache


func _global_class(n: String) -> Script:
	for c in ProjectSettings.get_global_class_list():
		if str(c["class"]) == n:
			return load(str(c["path"]))
	return null


# wrap only for long text that sits in a box with a real width (a wrapping
# label inside an HBox collapses to zero width and stacks one letter per line)
func _label(text: String, size := 18, col := COL_TEXT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 560
	var f := _font()
	if f != null and size >= 20:
		l.add_theme_font_override("font", f)
	return l


func _button(text: String, cb: Callable, accent := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 44)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 19)
	var f := _font()
	if f != null:
		b.add_theme_font_override("font", f)
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		var base := Color(0.16, 0.14, 0.06) if accent else Color(0.1, 0.11, 0.14)
		sb.bg_color = base.lightened(0.12) if st == "hover" else (base.darkened(0.3) if st == "disabled" else base)
		sb.border_width_left = 4 if st == "hover" or accent else 0
		sb.border_color = COL_TITLE
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.corner_radius_top_left = 3
		sb.corner_radius_top_right = 3
		sb.corner_radius_bottom_left = 3
		sb.corner_radius_bottom_right = 3
		b.add_theme_stylebox_override(st, sb)
	b.add_theme_color_override("font_color", COL_TITLE if accent else COL_TEXT)
	b.add_theme_color_override("font_disabled_color", Color(0.45, 0.46, 0.5))
	b.pressed.connect(cb)
	return b


func _edit(text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.custom_minimum_size = Vector2(0, 40)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_size_override("font_size", 19)
	return e


func _field(parent: Control, caption: String, ctl: Control) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_label(caption, 14, COL_DIM))
	box.add_child(ctl)
	parent.add_child(box)


func _build_panel() -> void:
	# full-screen layer: dims the game and centres the panel
	_root = ColorRect.new()
	_root.color = Color(0, 0, 0, 0.45)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.border_width_left = 5
	sb.border_color = COL_TITLE
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 24
	sb.content_margin_bottom = 24
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_panel.add_child(v)
	_title_label = _label(mp.t("title"), 34, COL_TITLE)
	v.add_child(_title_label)
	_subtitle_label = _label(mp.t("subtitle") % mp.VERSION, 14, COL_DIM)
	v.add_child(_subtitle_label)

	# step-by-step guide; the current step is highlighted in refresh()
	_steps_label = RichTextLabel.new()
	_steps_label.bbcode_enabled = true
	_steps_label.fit_content = true
	_steps_label.scroll_active = false
	_steps_label.custom_minimum_size = Vector2(560, 0)
	_steps_label.add_theme_font_size_override("normal_font_size", 17)
	v.add_child(_steps_label)

	_name_edit = _edit(mp.my_name, mp.t("name_hint"))
	_name_edit.max_length = 24
	_name_edit.text_changed.connect(func(t: String) -> void: mp.set_player_name(t))
	_field(v, mp.t("your_name"), _name_edit)

	# --- Steam: the easy way, no ports and no IPs
	_steam_label = _label("", 15, COL_DIM, true)
	v.add_child(_steam_label)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 10)
	_steam_host_btn = _button(mp.t("create_game"), func() -> void: mp.host_steam(), true)
	_invite_btn = _button(mp.t("invite_friends"), func() -> void: mp.invite_friends(), true)
	srow.add_child(_steam_host_btn)
	srow.add_child(_invite_btn)
	v.add_child(srow)
	_ip_toggle = _button(mp.t("ip_section"), func() -> void:
		_ip_box.visible = not _ip_box.visible)
	v.add_child(_ip_toggle)
	_ip_box = VBoxContainer.new()
	_ip_box.add_theme_constant_override("separation", 10)
	_ip_box.visible = false
	v.add_child(_ip_box)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 10)
	_ip_edit = _edit(mp.last_ip, mp.t("ip_hint"))
	_field(row2, mp.t("host_ip"), _ip_edit)
	_port_edit = SpinBox.new()
	_port_edit.min_value = 1024
	_port_edit.max_value = 65535
	_port_edit.value = mp.last_port
	_port_edit.custom_minimum_size = Vector2(140, 40)
	var port_box := VBoxContainer.new()
	port_box.add_theme_constant_override("separation", 4)
	port_box.add_child(_label(mp.t("port"), 14, COL_DIM))
	port_box.add_child(_port_edit)
	row2.add_child(port_box)
	_ip_box.add_child(row2)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 10)
	_host_btn = _button(mp.t("create_server"), _on_host, true)
	_join_btn = _button(mp.t("join"), _on_join, true)
	row3.add_child(_host_btn)
	row3.add_child(_join_btn)
	_ip_box.add_child(row3)

	# Addresses stay hidden: this panel is often on screen while streaming.
	_ips_btn = _button(mp.t("show_ips"), func() -> void:
		_show_ips = not _show_ips
		refresh())
	_ip_box.add_child(_ips_btn)

	var row4 := HBoxContainer.new()
	row4.add_theme_constant_override("separation", 10)
	_leave_btn = _button(mp.t("disconnect"), func() -> void: mp.leave(mp.t("session_closed")))
	_resync_btn = _button(mp.t("resync"), func() -> void: mp.request_resync())
	row4.add_child(_leave_btn)
	row4.add_child(_resync_btn)
	v.add_child(row4)

	v.add_child(HSeparator.new())
	_status = _label("", 17, COL_TEXT, true)
	v.add_child(_status)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 14)
	_progress.show_percentage = false
	_progress.visible = false
	v.add_child(_progress)

	_players_label = RichTextLabel.new()
	_players_label.bbcode_enabled = true
	_players_label.fit_content = true
	_players_label.scroll_active = false
	_players_label.custom_minimum_size = Vector2(560, 0)
	_players_label.add_theme_font_size_override("normal_font_size", 17)
	v.add_child(_players_label)

	_ips_label = _label("", 14, COL_DIM, true)
	_ip_box.add_child(_ips_label)
	_help_label = _label(mp.t("panel_help"), 14, COL_DIM, true)
	v.add_child(_help_label)
	_close_btn = _button(mp.t("close"), close_panel)
	v.add_child(_close_btn)


func _build_feed() -> void:
	_feed = VBoxContainer.new()
	_feed.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_feed.position = Vector2(24, -300)
	_feed.custom_minimum_size = Vector2(620, 0)
	_feed.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_feed.alignment = BoxContainer.ALIGNMENT_END
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_feed)
	# bottom centre, above the hotbar: clear of the menu column and the HUD cards
	_feed.anchor_left = 0.5
	_feed.anchor_right = 0.5
	_feed.anchor_top = 1.0
	_feed.anchor_bottom = 1.0
	_feed.offset_top = -420
	_feed.offset_bottom = -200
	_feed.offset_left = -360
	_feed.offset_right = 360


func _build_roster() -> void:
	_roster = RichTextLabel.new()
	_roster.bbcode_enabled = true
	_roster.fit_content = true
	_roster.scroll_active = false
	_roster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster.add_theme_font_size_override("normal_font_size", 16)
	_roster.add_theme_constant_override("outline_size", 5)
	_roster.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_roster.anchor_left = 1.0
	_roster.anchor_right = 1.0
	_roster.offset_left = -300
	_roster.offset_right = -16
	_roster.offset_top = 150
	_roster.offset_bottom = 400
	add_child(_roster)


func _build_chat() -> void:
	_chat_edit = LineEdit.new()
	_chat_edit.placeholder_text = mp.t("chat_hint")
	_chat_edit.anchor_left = 0.5
	_chat_edit.anchor_right = 0.5
	_chat_edit.anchor_top = 1.0
	_chat_edit.anchor_bottom = 1.0
	_chat_edit.offset_left = -360
	_chat_edit.offset_right = 360
	_chat_edit.offset_top = -190
	_chat_edit.offset_bottom = -150
	_chat_edit.max_length = 200
	_chat_edit.visible = false
	_chat_edit.add_theme_font_size_override("font_size", 18)
	_chat_edit.text_submitted.connect(_on_chat_submit)
	add_child(_chat_edit)


# ---------------------------------------------------------------- behaviour

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k: int = event.keycode
	if _chat_edit.visible:
		if k == KEY_ESCAPE:
			_close_chat()
			get_viewport().set_input_as_handled()
		return
	if k == KEY_F2:
		if _root.visible:
			close_panel()
		else:
			open_panel()
		get_viewport().set_input_as_handled()
	elif k == KEY_ESCAPE and _root.visible:
		close_panel()
		get_viewport().set_input_as_handled()
	elif k == KEY_Y and mp.active() and mp.in_world() and not _root.visible:
		_open_chat()
		get_viewport().set_input_as_handled()
	elif k == KEY_F8 and mp.active():
		mp.request_resync()
		get_viewport().set_input_as_handled()


func _world_player() -> Node:
	if mp.world_sync != null and is_instance_valid(mp.world_sync.player):
		return mp.world_sync.player
	return null


func _release_mouse() -> void:
	var p := _world_player()
	_mouse_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if p != null and p.has_method("capture_mouse"):
		p.capture_mouse(false)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _restore_mouse() -> void:
	if not _mouse_was_captured:
		return
	var p := _world_player()
	if p != null and p.has_method("capture_mouse"):
		p.capture_mouse(true)


func open_panel() -> void:
	if _root.visible:
		return
	_name_edit.text = mp.my_name
	_ip_edit.text = mp.last_ip
	_port_edit.value = mp.last_port
	_root.visible = true
	_release_mouse()
	refresh()


func close_panel() -> void:
	if not _root.visible:
		return
	_root.visible = false
	_restore_mouse()


func _open_chat() -> void:
	_chat_edit.visible = true
	_chat_edit.text = ""
	_release_mouse()
	_chat_edit.grab_focus.call_deferred()


func _close_chat() -> void:
	_chat_edit.release_focus()
	_chat_edit.visible = false
	_restore_mouse()


func _on_chat_submit(text: String) -> void:
	mp.send_chat(text)
	_close_chat()


func _on_host() -> void:
	mp.set_player_name(_name_edit.text)
	mp.host(int(_port_edit.value))


func _on_join() -> void:
	mp.set_player_name(_name_edit.text)
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		notify(mp.t("ask_ip"))
		return
	mp.join(ip, int(_port_edit.value))


func set_status(text: String) -> void:
	_status.text = text


func set_progress(v: float) -> void:
	_progress.visible = v >= 0.0
	if v >= 0.0:
		_progress.value = v * 100.0


func notify(text: String) -> void:
	print("[MPMod] ", text)
	set_status(text)
	var l := _label(text, 18, COL_TEXT)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_push_feed(l)


func chat_line(who: String, col: Color, text: String) -> void:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", 18)
	r.add_theme_constant_override("outline_size", 6)
	r.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	r.text = "[color=#%s][b]%s:[/b][/color] %s" % [col.to_html(false), _esc(who), _esc(text)]
	_push_feed(r)


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _push_feed(c: Control) -> void:
	_feed.add_child(c)
	while _feed.get_child_count() > 8:
		_feed.get_child(0).queue_free()
		_feed.remove_child(_feed.get_child(0))
	var t := create_tween()
	t.tween_interval(FEED_SECONDS)
	t.tween_property(c, "modulate:a", 0.0, 1.2)
	t.tween_callback(c.queue_free)


# Three numbered steps with the current one highlighted, so nobody has to
# guess what to press next.
func _steps_text() -> String:
	var steps := [mp.t("create_game"), mp.t("invite_friends"), mp.t("step_play")]
	var at := 0
	if mp.active() and mp.is_host:
		at = 1 if not mp.in_world() else 2
		if mp.players.size() > 1:
			at = 2
	elif mp.active():
		steps = [mp.t("step_connecting"), mp.t("step_entering"), mp.t("step_dig")]
		at = 1 if mp.phase == mp.Phase.LOADING else (2 if mp.in_world() else 0)
	var out := PackedStringArray()
	for i in steps.size():
		var col := COL_TITLE.to_html(false) if i == at else "8a8f99"
		var mark := "▶" if i == at else "%d ·" % (i + 1)
		out.append("[color=#%s]%s %s[/color]" % [col, mark, steps[i]])
	return "   ".join(out)


# Button and label text is set when the panel is built; re-apply it so a
# language change in the game's options shows up without a restart.
func _apply_texts() -> void:
	_title_label.text = mp.t("title")
	_subtitle_label.text = mp.t("subtitle") % mp.VERSION
	_steam_host_btn.text = mp.t("create_game")
	_invite_btn.text = mp.t("invite_friends")
	_ip_toggle.text = mp.t("ip_section")
	_host_btn.text = mp.t("create_server")
	_join_btn.text = mp.t("join")
	_leave_btn.text = mp.t("disconnect")
	_resync_btn.text = mp.t("resync")
	_close_btn.text = mp.t("close")
	_help_label.text = mp.t("panel_help")
	_name_edit.placeholder_text = mp.t("name_hint")
	_ip_edit.placeholder_text = mp.t("ip_hint")
	_chat_edit.placeholder_text = mp.t("chat_hint")


func refresh() -> void:
	if _panel == null:
		return
	_apply_texts()
	var on: bool = mp.active()
	var steam_ok: bool = mp.steam_ready()
	_steam_host_btn.disabled = on or not steam_ok
	_invite_btn.disabled = not (on and mp.is_host and mp.over_steam)
	if steam_ok:
		_steam_label.text = mp.t("steam_ready") % mp.steam.persona
	else:
		_steam_label.text = mp.t("steam_missing") % mp.steam.load_status
	_host_btn.disabled = on
	_join_btn.disabled = on
	_leave_btn.disabled = not on
	_resync_btn.disabled = not (on and mp.in_world())
	_name_edit.editable = not on
	_ip_edit.editable = not on
	var lines := PackedStringArray()
	if on:
		lines.append("[color=#%s]%s[/color]" % [COL_TITLE.to_html(false), mp.t("role_host") if mp.is_host else mp.t("role_client")])
		for id in mp.players:
			var p: Dictionary = mp.players[id]
			var st := {"world": mp.t("state_world"), "loading": mp.t("state_loading"), "lobby": mp.t("state_lobby"), "menu": mp.t("state_menu")}.get(str(p.get("state", "")), "")
			lines.append("[color=#%s]●[/color] %s%s  [color=#8a8f99]%s[/color]" % [
				(p["color"] as Color).to_html(false), _esc(str(p["name"])),
				mp.t("host_suffix") if id == 1 else "", st])
	else:
		lines.append("[color=#8a8f99]%s[/color]" % mp.t("offline"))
	_players_label.text = "\n".join(lines)
	_steps_label.text = _steps_text()
	# addresses are private: only drawn when the player asks for them
	if _show_ips:
		var ips := PackedStringArray()
		for a in IP.get_local_addresses():
			if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254"):
				var tag := ""
				if a.begins_with("100."):
					tag = " (Tailscale)"
				elif a.begins_with("26."):
					tag = " (Radmin)"
				elif a.begins_with("192.168.") or a.begins_with("10."):
					tag = " (red local)"
				ips.append(a + tag)
		_ips_label.text = mp.t("your_ips") % (", ".join(ips) if not ips.is_empty() else "-")
		_ips_btn.text = mp.t("hide_ips")
	else:
		_ips_label.text = mp.t("ips_hidden")
		_ips_btn.text = mp.t("show_ips")
	# roster in the corner while playing together
	if on and mp.players.size() > 0:
		var rl := PackedStringArray()
		for id in mp.players:
			var p: Dictionary = mp.players[id]
			rl.append("[right][color=#%s]●[/color] %s[/right]" % [(p["color"] as Color).to_html(false), _esc(str(p["name"]))])
		_roster.text = "\n".join(rl)
		_roster.visible = true
	else:
		_roster.visible = false


# ---------------------------------------------------------------- main menu

func hook_menu(menu: Node) -> void:
	for i in 120:
		var b := _find_mp_button(menu)
		if b != null:
			for c in b.pressed.get_connections():
				b.pressed.disconnect(c["callable"])
			b.pressed.connect(func() -> void:
				Audio.play("ui_open")
				open_panel())
			b.visible = true
			return
		await get_tree().process_frame
		if not is_instance_valid(menu):
			return
	push_warning("[MPMod] could not find the MULTIPLAYER button in the menu")


func _find_mp_button(n: Node) -> Button:
	var want := [n.tr("MULTIPLAYER"), "MULTIPLAYER"]
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is Button and (c as Button).text in want:
			return c
		stack.append_array(c.get_children())
	return null
