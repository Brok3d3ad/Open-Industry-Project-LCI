@tool
class_name VSU
extends BeltConveyor

## Belt conveyor variant with side-mounted legs and a flag-driven incline.
##
## The deck is the stock `BeltConveyor` — same look, resize handles, snapping and
## speed/running comms. Differences: the support legs mount OUTBOARD (posts run up
## the outside faces of the deck instead of underneath it), and the deck incline is
## driven by two flags — [member incline_up] / [member incline_down]. Toggle them in
## the inspector, or let the PLC drive them through the BOOL read tags below
## (Enable Comms + running simulation). The deck ramps toward the target angle at
## [member tilt_speed]; both flags off levels the deck back to 0°.

## Tilt the deck up to [member up_angle]. Wins over [member incline_down] when both are set.
@export var incline_up: bool = false
## Tilt the deck down to -[member down_angle].
@export var incline_down: bool = false
## Deck angle while [member incline_up] is on, degrees.
@export_range(0.0, 45.0, 0.1, "suffix:°") var up_angle: float = 12.0
## Deck angle while [member incline_down] is on, degrees (tilts below level).
@export_range(0.0, 45.0, 0.1, "suffix:°") var down_angle: float = 12.0
## Ramp rate toward the target incline, degrees per second.
@export_range(1.0, 90.0, 0.5, "suffix:°/s") var tilt_speed: float = 15.0

## PLC flags (BOOL read tags) mirroring the two inspector toggles.
@export var incline_tag_group_name: String
@export_custom(0, "tag_group_enum") var incline_tag_groups: String:
	set(value):
		incline_tag_group_name = value
		incline_tag_groups = value
## BOOL read tag driving [member incline_up].
@export var incline_up_tag_name: String = ""
## BOOL read tag driving [member incline_down].
@export var incline_down_tag_name: String = ""

var _incline_up_tag := OIPCommsTag.new()
var _incline_down_tag := OIPCommsTag.new()


func _init() -> void:
	super._init()
	leg_model_scene = preload("res://parts/VSULeg.tscn")


## Ramp the inherited `incline` (segment 0 tilt) toward the flags' target angle.
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	var target: float = 0.0
	if incline_up:
		target = up_angle
	elif incline_down:
		target = -down_angle
	if absf(incline - target) < 0.001:
		return
	incline = move_toward(incline, target, tilt_speed * delta)


#region Communications -------------------------------------------------------------
func _enter_tree() -> void:
	super._enter_tree()
	incline_tag_group_name = OIPCommsSetup.default_tag_group(incline_tag_group_name)


func _on_simulation_started() -> void:
	super._on_simulation_started()
	if enable_comms:
		_incline_up_tag.register(incline_tag_group_name, incline_up_tag_name, OIPComms.TAG_TYPE_BOOL)
		_incline_down_tag.register(incline_tag_group_name, incline_down_tag_name, OIPComms.TAG_TYPE_BOOL)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	super._tag_group_initialized(tag_group_name_param)
	_incline_up_tag.on_group_initialized(tag_group_name_param)
	_incline_down_tag.on_group_initialized(tag_group_name_param)


func _tag_group_polled(tag_group_name_param: String) -> void:
	super._tag_group_polled(tag_group_name_param)
	if not enable_comms:
		return
	if _incline_up_tag.is_ready() and _incline_up_tag.matches_group(tag_group_name_param):
		incline_up = _incline_up_tag.read_bit()
	if _incline_down_tag.is_ready() and _incline_down_tag.matches_group(tag_group_name_param):
		incline_down = _incline_down_tag.read_bit()


func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	if OIPCommsSetup.validate_tag_property(property, "incline_tag_group_name", "incline_tag_groups", "incline_up_tag_name"):
		return
	OIPCommsSetup.validate_tag_property(property, "incline_tag_group_name", "incline_tag_groups", "incline_down_tag_name")
#endregion


#region Preview --------------------------------------------------------------------
func _get_custom_preview_node() -> Node3D:
	var preview_scene := load("res://parts/VSU.tscn") as PackedScene
	var preview_node := preview_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) as Node3D
	preview_node.set_meta("is_preview", true)
	_disable_collisions_recursive(preview_node)
	return preview_node
#endregion
