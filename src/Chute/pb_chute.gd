@tool
class_name PBChute
extends Node3D

## Powered-roller chute (chute_type_1): the roller bed drives boxes forward like a
## conveyor. NO snapping — just the powered rollers.
##
## The hidden "Chute" StaticBody3D gets a surface velocity
## ([code]constant_linear_velocity[/code]) along the bed flow axis (the body's local +Z,
## intake -> discharge) whenever the chute is running, so resting boxes are carried
## toward the discharge.
##
## Two PLC signals (Communications), like a conveyor:
##  - run tag (BOOL, READ): TRUE powers the rollers.
##  - stop tag (BOOL, READ): TRUE stops them (stop wins over run).

const _BODY_PATH: String = "chute_type_1/Chute/StaticBody3D"

## Whether the rollers are currently powered.
@export var running: bool = false:
	set(value):
		running = value
		_apply_velocity()
## Roller surface speed in metres per second.
@export_range(0.0, 10.0, 0.05, "suffix:m/s") var speed: float = 1.0:
	set(value):
		speed = value
		_apply_velocity()
## Surface friction so the powered bed grips boxes (and holds them when stopped).
@export_range(0.0, 1.0, 0.01) var roller_friction: float = 0.6:
	set(value):
		roller_friction = value
		_apply_friction()

var _body: StaticBody3D = null


func _ready() -> void:
	_resolve_body()
	_apply_friction()
	_apply_velocity()


func _physics_process(_delta: float) -> void:
	_apply_velocity()


func _resolve_body() -> void:
	_body = get_node_or_null(NodePath(_BODY_PATH)) as StaticBody3D


func _apply_friction() -> void:
	if _body == null or not is_instance_valid(_body):
		_resolve_body()
	if _body == null:
		return
	var mat: PhysicsMaterial = _body.physics_material_override
	if mat == null:
		mat = PhysicsMaterial.new()
		_body.physics_material_override = mat
	mat.friction = roller_friction


func _apply_velocity() -> void:
	if _body == null or not is_instance_valid(_body):
		_resolve_body()
	if _body == null:
		return
	if not running or is_zero_approx(speed):
		_body.constant_linear_velocity = Vector3.ZERO
		return
	# Body local +Z is the bed flow axis (intake -> discharge).
	var dir: Vector3 = _body.global_transform.basis.z.normalized()
	_body.constant_linear_velocity = dir * speed


#region PLC
@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var run_tag_group_name: String
## The tag group for the run command.
@export_custom(0, "tag_group_enum") var run_tag_groups: String:
	set(value):
		run_tag_group_name = value
		run_tag_groups = value
## Command tag (READ): TRUE powers the rollers.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var run_tag_name: String = ""
@export var stop_tag_group_name: String
## The tag group for the stop command.
@export_custom(0, "tag_group_enum") var stop_tag_groups: String:
	set(value):
		stop_tag_group_name = value
		stop_tag_groups = value
## Command tag (READ): TRUE stops the rollers (overrides run).[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var stop_tag_name: String = ""

var _run_tag: OIPCommsTag = OIPCommsTag.new()
var _stop_tag: OIPCommsTag = OIPCommsTag.new()


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "run_tag_group_name", "run_tag_groups", "run_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "stop_tag_group_name", "stop_tag_groups", "stop_tag_name"):
		return


func _enter_tree() -> void:
	run_tag_group_name = OIPCommsSetup.default_tag_group(run_tag_group_name)
	stop_tag_group_name = OIPCommsSetup.default_tag_group(stop_tag_group_name)
	if not Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _exit_tree() -> void:
	if Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _on_simulation_started() -> void:
	if enable_comms:
		_run_tag.register(run_tag_group_name, run_tag_name, OIPComms.TAG_TYPE_BOOL)
		_stop_tag.register(stop_tag_group_name, stop_tag_name, OIPComms.TAG_TYPE_BOOL)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	_run_tag.on_group_initialized(tag_group_name_param)
	_stop_tag.on_group_initialized(tag_group_name_param)


func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms:
		return
	var want_run: bool = running
	if _run_tag.matches_group(tag_group_name_param):
		if _run_tag.read_bit():
			want_run = true
	if _stop_tag.matches_group(tag_group_name_param):
		if _stop_tag.read_bit():
			want_run = false
	if want_run != running:
		running = want_run
#endregion # PLC
