extends "res://scripts/ui/pause_menu.gd"

# "Save and return to title" / "save and quit" in co-op.
#
# The mod used to replace both with its own demo-era version: save, show the
# loading screen, change to the menu scene. In the Early Access game nothing
# took that loading screen down again, so the player was left on a black
# screen with only the version in the corner. The game's own handlers do it
# right, so they run now; the mod only steps in where co-op differs:
# a guest never saves (the world is the host's), and a host waits while a
# shared clean-up is still running.

func _on_exit_to_title() -> void:
	var session := _mp_session()
	if session != null and not session.is_host:
		if _leaving:
			return
		_leaving = true
		Audio.play("ui_back")
		# ends the session and takes the guest back to the menu
		session.leave()
		return
	if _mp_cleanup_busy():
		return
	super._on_exit_to_title()


func _on_quit() -> void:
	var session := _mp_session()
	if session != null and not session.is_host:
		if _leaving:
			return
		_leaving = true
		get_tree().quit()
		return
	if _mp_cleanup_busy():
		return
	super._on_quit()


func _mp_session() -> Node:
	var session := get_node_or_null("/root/MPMod")
	return session if is_instance_valid(session) and session.active() else null


func _mp_cleanup_busy() -> bool:
	if SaveManager.has_method("mp_cleanup_pending") and SaveManager.mp_cleanup_pending():
		_status.text = "Aufräumen wird abgeschlossen. Danach speichern und beenden." if TranslationServer.get_locale().begins_with("de") else "Cleanup is finishing. Save and exit after it completes."
		return true
	return false
