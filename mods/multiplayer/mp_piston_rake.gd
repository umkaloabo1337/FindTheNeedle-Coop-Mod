extends "res://scripts/build/piston_rake.gd"

# Driving a piston rake (EA v14) in co-op.
#
# Machines run on the host only, so a guest's rake is frozen and its panel's
# drive button did nothing. A guest's drive now goes to the host, and a rake
# the host starts driving tells every guest, whose copy then drives along with
# the game's own drive code; the host's end position settles it.

var mp_transport: Node
var mp_following := false  # a guest driving because the host's rake does


func drive(direction: float, check: Callable) -> void:
	if not mp_following and is_instance_valid(mp_transport) and mp_transport.rake_drive_remote(self, direction):
		return
	var was := is_driving()
	super.drive(direction, check)
	if not mp_following and is_instance_valid(mp_transport) and is_driving() and not was:
		mp_transport.rake_drive_started(self, direction)


func _drive_done() -> void:
	super._drive_done()
	if is_instance_valid(mp_transport):
		mp_transport.rake_drive_finished(self)
