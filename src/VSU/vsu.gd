@tool
class_name VSU
extends BeltConveyor

## Belt conveyor variant with no legs and a flag-driven incline.
##
## The deck is the stock `BeltConveyor` — same look, resize handles, snapping and
## speed/running comms. Differences: it has NO support legs (the whole Legs section
## is forced off and hidden), and the deck is TWO-POSITION — always commanded to
## either UP (+[member up_angle]) or DOWN (-[member down_angle]), never level.
## [member incline_up] / [member incline_down] are the commands: toggle them in the
## inspector, or let the PLC drive them through the BOOL read tags below (Enable
## Comms + running simulation). Up wins while both are set; with both off the deck
## holds its last commanded position. A fresh unit starts UP. The deck ramps
## toward the target angle at [member tilt_speed].
##
## The tilt is applied as a RIGID ROTATION of the node about its tail pivot — not
## via the `incline` segment property. Writing `incline` regenerates the belt mesh,
## collision shapes, rails and guards, which at animation rate collapses the frame
## rate; rotating the node keeps all geometry cached.

## Command: send the deck UP to [member up_angle]. Wins over [member incline_down]
## when both are set; turning it off leaves the deck up until DOWN is commanded.
@export var incline_up: bool = false
## Command: send the deck DOWN to -[member down_angle].
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

## Deck tilt currently applied to the node's basis, degrees. Persisted so a scene
## saved mid-tilt (or left raised by the PLC) resumes from the right baseline.
@export_storage var _tilt_deg: float = 0.0

## Latched position command — the deck only ever targets UP or DOWN.
@export_storage var _target_up: bool = true

## The VSU carries no legs; the inherited leg properties are hidden too.
const _HIDDEN_LEG_PROPS: PackedStringArray = [
	"legs_enabled", "floor_plane", "leg_model_scene",
	"tail_end_leg_enabled", "tail_end_attachment_offset", "tail_end_leg_clearance",
	"head_end_leg_enabled", "head_end_attachment_offset", "head_end_leg_clearance",
	"middle_legs_enabled", "middle_legs_spacing",
	"exclusion_start", "exclusion_end",
]

var _incline_up_tag := OIPCommsTag.new()
var _incline_down_tag := OIPCommsTag.new()


func _init() -> void:
	super._init()
	legs_enabled = false


## Ramp the deck toward the flags' target angle by rotating the node about its
## tail pivot (local Z). Never touches `incline` — see the class doc.
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if incline_up:
		_target_up = true
	elif incline_down:
		_target_up = false
	var target: float = up_angle if _target_up else -down_angle
	if absf(_tilt_deg - target) < 0.0005:
		return
	var next: float = move_toward(_tilt_deg, target, tilt_speed * delta)
	# Orthonormalize so FP drift never trips the ResizableNode3D scale slam.
	var tilted: Basis = (transform.basis * Basis(Vector3(0, 0, 1), deg_to_rad(next - _tilt_deg))).orthonormalized()
	transform = Transform3D(tilted, transform.origin)
	_tilt_deg = next


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
	if property.name in _HIDDEN_LEG_PROPS:
		property.usage = PROPERTY_USAGE_NO_EDITOR
		return
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
