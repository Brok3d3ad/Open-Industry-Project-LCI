@tool
class_name NonConChute
extends ResizableNode3D

## Non-conveyable gravity chute, split into parts:
##   Chute_Visual (bed/frame), SideGuardL/SideGuardR (removable side guards),
##   Gate (movable gate section), Legs (stretchable support legs, origin at the
##   floor), Chute (hidden bed collision proxy) and WallL/WallR (hidden side-wall
##   collision, toggled together with the visual side guards).
##
## - Extends ResizableNode3D so the conveyor gizmo shows a drag handle: only the +Y
##   handle is active and it drives [member leg_extension] (X/Z are fixed by geometry).
## - `gate_closed`: CLOSED = the gate rests in its natural (down) pose and its box
##   collision blocks boxes; OPEN = the gate rotates up by [member gate_closed_angle].
##   Drive it with the PLC tags (Communications): gate_close tag (BOOL, read:
##   TRUE = close) + gate_state tag (BOOL, write: TRUE while closed), same pattern
##   as BeltConveyor's speed/running tags.
## - `left/right_side_guards_enabled` hide the guard visuals AND disable the matching
##   side-wall collision, like conveyor side guards.
## - get_snap_features() lets OIP ConveyorSnapping snap the chute to conveyors; the
##   snap point follows the bed (bed_y + leg_extension + snap_drop).

const _VIS_PATH: String = "chute_NON_CON/Chute_Visual"
const _GATE_PATH: String = "chute_NON_CON/Gate"
const _LEGS_PATH: String = "chute_NON_CON/Legs"
const _COL_PATH: String = "chute_NON_CON/Chute"
const _SGL_PATH: String = "chute_NON_CON/SideGuardL"
const _SGR_PATH: String = "chute_NON_CON/SideGuardR"
const _WALL_L_PATH: String = "chute_NON_CON/WallL"
const _WALL_R_PATH: String = "chute_NON_CON/WallR"
## Legs height at zero extension, in meters.
const LEGS_BASE_HEIGHT: float = 0.67
## Overall chute height at zero extension (union bbox height * import root_scale).
const BASE_HEIGHT: float = 1.0954
const FIXED_LENGTH: float = 4.032
const FIXED_WIDTH: float = 1.664
const MIN_EXTENSION: float = -0.3
const MAX_EXTENSION: float = 5.0
const GATE_BODY_NAME: String = "GateBody"

## Lengthen (or shorten, negative) the legs; the chute body rises/falls with them.
@export_range(-0.3, 5.0, 0.01, "suffix:m") var leg_extension: float = 0.0:
	set(value):
		leg_extension = clampf(value, MIN_EXTENSION, MAX_EXTENSION)
		_apply()
		if not _syncing:
			_syncing = true
			size = Vector3(FIXED_LENGTH, BASE_HEIGHT + leg_extension, FIXED_WIDTH)
			_syncing = false

@export_group("Side Guards")
## Show/hide the LEFT side guard (visual + its wall collision).
@export var left_side_guards_enabled: bool = true:
	set(value):
		left_side_guards_enabled = value
		_update_side_guards()
## Show/hide the RIGHT side guard (visual + its wall collision).
@export var right_side_guards_enabled: bool = true:
	set(value):
		right_side_guards_enabled = value
		_update_side_guards()

@export_group("Gate")
## Closed = gate in its natural (down) pose, collision blocks boxes.
## Open = gate rotated up by [member gate_closed_angle].
@export var gate_closed: bool = false:
	set(value):
		gate_closed = value
		_update_gate_body()
		_comms_write_state(value)
## Hinge rotation when OPEN, degrees (negative flips the swing direction).
@export_range(-90.0, 90.0, 0.5, "suffix:deg") var gate_closed_angle: float = 50.0:
	set(value):
		gate_closed_angle = value
		_apply_gate()
## Gate animation speed, degrees per second.
@export_range(5.0, 360.0, 1.0) var gate_speed: float = 60.0
## Extra manual vertical offset of ONLY the gate.
@export_range(-2.0, 5.0, 0.01, "suffix:m") var gate_offset: float = 0.0:
	set(value):
		gate_offset = value
		_apply_gate()
## Fine-tune of the auto-computed hinge point (gate-local space).
@export var gate_hinge_offset: Vector3 = Vector3.ZERO:
	set(value):
		gate_hinge_offset = value
		_apply_gate()

@export_group("Snapping")
## Half chute length along local X (snap ends).
@export var half_length: float = 2.016
## Half chute width along local Z.
@export var half_width: float = 0.832
## Bed height at zero leg extension (snap connection height).
@export var bed_y: float = 1.0
## How far BELOW the conveyor the bed lands on align, so boxes drop in cleanly
## instead of clipping the bed's leading edge.
@export_range(0.0, 0.5, 0.005, "suffix:m") var snap_drop: float = 0.07

## Chute width; lets the side-guard opening derivation use the real footprint.
var width: float:
	get:
		return FIXED_WIDTH

## Local-space AABB used by snapping/gizmo code (origin at the floor, not centered).
var local_bbox: AABB:
	get:
		return AABB(
				Vector3(-FIXED_LENGTH * 0.5, 0.0, -FIXED_WIDTH * 0.5),
				Vector3(FIXED_LENGTH, BASE_HEIGHT + leg_extension, FIXED_WIDTH))

var _syncing: bool = false
var _base_cached: bool = false
var _base_pos: Dictionary = {}
var _legs_base_scale: Vector3 = Vector3.ONE
var _gate_base_xform: Transform3D = Transform3D.IDENTITY
var _gate_pivot: Vector3 = Vector3.ZERO
var _gate_angle: float = 0.0
var _gate_shape: CollisionShape3D = null


func _init() -> void:
	size_default = Vector3(FIXED_LENGTH, BASE_HEIGHT, FIXED_WIDTH)
	size_min = Vector3(FIXED_LENGTH, BASE_HEIGHT + MIN_EXTENSION, FIXED_WIDTH)


func _enter_tree() -> void:
	super._enter_tree()
	_comms_enter()


func _ready() -> void:
	_apply()
	if not _syncing:
		_syncing = true
		size = Vector3(FIXED_LENGTH, BASE_HEIGHT + leg_extension, FIXED_WIDTH)
		_syncing = false
	_gate_angle = 0.0 if gate_closed else gate_closed_angle
	_ensure_gate_body()
	_apply_gate()
	_update_side_guards()
	ConveyorSnapping.notify_contacts_rebuild(self)


func _exit_tree() -> void:
	super._exit_tree()
	_comms_exit()
	ConveyorSnapping.notify_contacts_rebuild(self)


func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		ConveyorSnapping.notify_contacts_rebuild(self)


func _physics_process(delta: float) -> void:
	# Closed = natural pose (0 deg); open = raised by gate_closed_angle.
	var target: float = 0.0 if gate_closed else gate_closed_angle
	if not is_equal_approx(_gate_angle, target):
		_gate_angle = move_toward(_gate_angle, target, gate_speed * delta)
		_apply_gate()


#region ResizableNode3D integration (gizmo handle drives leg_extension)

func _on_size_changed() -> void:
	if _syncing:
		return
	_syncing = true
	leg_extension = size.y - BASE_HEIGHT
	_syncing = false


func _get_constrained_size(new_size: Vector3) -> Vector3:
	return Vector3(
			FIXED_LENGTH,
			clampf(new_size.y, BASE_HEIGHT + MIN_EXTENSION, BASE_HEIGHT + MAX_EXTENSION),
			FIXED_WIDTH)


func _get_resize_local_bounds(for_size: Vector3) -> AABB:
	return AABB(Vector3(-for_size.x * 0.5, 0.0, -for_size.z * 0.5), for_size)


func _get_active_resize_handle_ids() -> PackedInt32Array:
	return PackedInt32Array([2])


func _get_scale_warning_text() -> String:
	return "Use the top handle (or 'size' Y) to adjust the chute legs."

#endregion


func _node(path: String) -> Node3D:
	return get_node_or_null(NodePath(path)) as Node3D


func _cache_base() -> void:
	if _base_cached:
		return
	var vis: Node3D = _node(_VIS_PATH)
	var gate: Node3D = _node(_GATE_PATH)
	var legs: Node3D = _node(_LEGS_PATH)
	var col: Node3D = _node(_COL_PATH)
	if vis == null or gate == null or legs == null or col == null:
		return
	_base_pos.clear()
	for path: String in [_VIS_PATH, _COL_PATH, _LEGS_PATH, _SGL_PATH, _SGR_PATH, _WALL_L_PATH, _WALL_R_PATH]:
		var n: Node3D = _node(path)
		if n != null:
			_base_pos[path] = n.position
	_legs_base_scale = legs.scale
	_gate_base_xform = gate.transform
	var gate_mesh: MeshInstance3D = gate as MeshInstance3D
	if gate_mesh != null and gate_mesh.mesh != null:
		var ab: AABB = gate_mesh.get_aabb()
		_gate_pivot = Vector3(ab.get_center().x, ab.end.y, ab.get_center().z)
	_base_cached = true


func _apply() -> void:
	_cache_base()
	if not _base_cached:
		return
	var rise: Vector3 = Vector3(0.0, leg_extension, 0.0)
	for path: String in _base_pos.keys():
		var n: Node3D = _node(path)
		if n == null:
			continue
		if path == _LEGS_PATH:
			n.position = _base_pos[path]
			var k: float = (LEGS_BASE_HEIGHT + leg_extension) / LEGS_BASE_HEIGHT
			n.scale = Vector3(_legs_base_scale.x, _legs_base_scale.y * k, _legs_base_scale.z)
		else:
			n.position = (_base_pos[path] as Vector3) + rise
	_apply_gate()


func _apply_gate() -> void:
	_cache_base()
	if not _base_cached:
		return
	var gate: Node3D = _node(_GATE_PATH)
	if gate == null:
		return
	var pivot: Vector3 = _gate_pivot + gate_hinge_offset
	var rot: Transform3D = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(_gate_angle)), Vector3.ZERO)
	var hinge: Transform3D = Transform3D(Basis(), pivot) * rot * Transform3D(Basis(), -pivot)
	var lift: Vector3 = Vector3(0.0, leg_extension + gate_offset, 0.0)
	gate.transform = Transform3D(Basis(), lift) * _gate_base_xform * hinge


#region Side guards

func _update_side_guards() -> void:
	_set_guard_state(_SGL_PATH, _WALL_L_PATH, left_side_guards_enabled)
	_set_guard_state(_SGR_PATH, _WALL_R_PATH, right_side_guards_enabled)


func _set_guard_state(visual_path: String, wall_path: String, enabled: bool) -> void:
	var visual: Node3D = _node(visual_path)
	if visual != null:
		visual.visible = enabled
	var wall: Node3D = _node(wall_path)
	if wall == null:
		return
	wall.visible = false
	for c: Node in wall.get_children():
		if c is StaticBody3D:
			for cc: Node in c.get_children():
				var shape: CollisionShape3D = cc as CollisionShape3D
				if shape != null:
					shape.disabled = not enabled

#endregion


#region Gate collision

func _ensure_gate_body() -> void:
	var gate: Node3D = _node(_GATE_PATH)
	if gate == null:
		return
	var existing: StaticBody3D = gate.get_node_or_null(GATE_BODY_NAME) as StaticBody3D
	if existing != null:
		_gate_shape = existing.get_node_or_null("CollisionShape3D") as CollisionShape3D
		_update_gate_body()
		return
	var gate_mesh: MeshInstance3D = gate as MeshInstance3D
	if gate_mesh == null or gate_mesh.mesh == null:
		return
	var ab: AABB = gate_mesh.get_aabb()
	var body: StaticBody3D = StaticBody3D.new()
	body.name = GATE_BODY_NAME
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var box: BoxShape3D = BoxShape3D.new()
	box.size = ab.size
	shape.shape = box
	shape.position = ab.get_center()
	body.add_child(shape)
	gate.add_child(body)
	_gate_shape = shape
	_update_gate_body()


func _update_gate_body() -> void:
	if _gate_shape == null or not is_instance_valid(_gate_shape):
		return
	# Collision only blocks while the gate is closed; open gate lets boxes through.
	_gate_shape.disabled = not gate_closed

#endregion


#region PLC
@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var gate_close_tag_group_name: String
## The tag group for the gate close command.
@export_custom(0, "tag_group_enum") var gate_close_tag_groups: String:
	set(value):
		gate_close_tag_group_name = value
		gate_close_tag_groups = value
## Command tag (READ): TRUE closes the gate, FALSE opens it.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var gate_close_tag_name: String = ""
@export var gate_state_tag_group_name: String
## The tag group for the gate state feedback.
@export_custom(0, "tag_group_enum") var gate_state_tag_groups: String:
	set(value):
		gate_state_tag_group_name = value
		gate_state_tag_groups = value
## Status tag (WRITE): TRUE while the gate is closed.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var gate_state_tag_name: String = ""

var _gate_close_tag: OIPCommsTag = OIPCommsTag.new()
var _gate_state_tag: OIPCommsTag = OIPCommsTag.new()


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "gate_close_tag_group_name", "gate_close_tag_groups", "gate_close_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "gate_state_tag_group_name", "gate_state_tag_groups", "gate_state_tag_name"):
		return


func _comms_enter() -> void:
	gate_close_tag_group_name = OIPCommsSetup.default_tag_group(gate_close_tag_group_name)
	gate_state_tag_group_name = OIPCommsSetup.default_tag_group(gate_state_tag_group_name)
	if not Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _comms_exit() -> void:
	if Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _comms_write_state(closed_now: bool) -> void:
	if _gate_state_tag.is_ready():
		_gate_state_tag.write_bit(closed_now)


func _on_simulation_started() -> void:
	if enable_comms:
		_gate_close_tag.register(gate_close_tag_group_name, gate_close_tag_name, OIPComms.TAG_TYPE_BOOL)
		_gate_state_tag.register(gate_state_tag_group_name, gate_state_tag_name, OIPComms.TAG_TYPE_BOOL)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	_gate_close_tag.on_group_initialized(tag_group_name_param)
	if _gate_state_tag.on_group_initialized(tag_group_name_param):
		_gate_state_tag.write_bit(gate_closed)


func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms:
		return
	if _gate_close_tag.matches_group(tag_group_name_param):
		var cmd: bool = _gate_close_tag.read_bit()
		if cmd != gate_closed:
			gate_closed = cmd
#endregion # PLC


func get_snap_features() -> Array:
	# Features sit snap_drop ABOVE the bed so the align lands the bed that much
	# below the conveyor's contact line.
	var by: float = bed_y + leg_extension + snap_drop
	return [
		{"shape": 0, "kind": &"straight_end_front", "local_pos": Vector3(half_length, by, 0.0),
			"local_outward": Vector3(1, 0, 0), "end_name": &"front"},
		{"shape": 0, "kind": &"straight_end_back", "local_pos": Vector3(-half_length, by, 0.0),
			"local_outward": Vector3(-1, 0, 0), "end_name": &"back"},
		{"shape": 1, "kind": &"straight_sideguard_left",
			"seg_start": Vector3(-half_length, by, -half_width), "seg_end": Vector3(half_length, by, -half_width),
			"seg_outward_local": Vector3(0, 0, -1)},
		{"shape": 1, "kind": &"straight_sideguard_right",
			"seg_start": Vector3(-half_length, by, half_width), "seg_end": Vector3(half_length, by, half_width),
			"seg_outward_local": Vector3(0, 0, 1)},
	]
