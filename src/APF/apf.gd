@tool
class_name APF
extends Node3D

## Allen-Bradley PowerFlex VFD simulation. Acts as the drive: writes status
## tags to the PLC (matches `APF_I.*` from the PowerFlex map) and reads
## command tags from the PLC (matches `APF_O.*`). Pilot E-click on the unit
## rotates the disconnect handle 90° and flips `disconnect_closed`.

const STATUS_OK_COLOR: Color = Color(1, 1, 1, 1)
const STATUS_BAD_COLOR: Color = Color(1, 0, 0, 1)
const PILOT_OK_COLOR: Color = Color(0, 1, 0, 1)
const PILOT_BAD_COLOR: Color = Color(1, 0, 0, 1)
const HANDLE_OPEN_ANGLE: float = PI / 2.0
const HANDLE_TWEEN_DURATION: float = 0.15

# Local label only — never sent to PLC.
@export var name_text: String = "APF":
	set(value):
		name_text = value
		if _name_label:
			_name_label.text = name_text


@export_category("State Outputs")

## true when comms to the drive are faulted. Red label/lens when true.
@export var connection_faulted: bool = false:
	set(value):
		if _connection_faulted_tag.is_ready() and value != connection_faulted:
			_connection_faulted_tag.write_bit(value)
		connection_faulted = value
		_update_status_visuals()

## true when the operator has the drive in keypad/hand mode. Red when true.
@export var keypad_hand_mode: bool = false:
	set(value):
		if _keypad_hand_mode_tag.is_ready() and value != keypad_hand_mode:
			_keypad_hand_mode_tag.write_bit(value)
		keypad_hand_mode = value
		_update_status_visuals()

## Disconnect switch closed (drive energised). Default true; pilot E-click
## flips it to false (handle rotates 90°). Red when false (NC fail-safe).
@export var disconnect_closed: bool = true:
	set(value):
		if _disconnect_closed_tag.is_ready() and value != disconnect_closed:
			_disconnect_closed_tag.write_bit(value)
		disconnect_closed = value
		_update_status_visuals()
		_animate_handle()

## true when the drive has tripped on a fault. Red when true.
@export var fault: bool = false:
	set(value):
		if _fault_tag.is_ready() and value != fault:
			_fault_tag.write_bit(value)
		fault = value
		_update_status_visuals()

## true when the motor is running. Red when false (drive stopped).
@export var running: bool = true:
	set(value):
		if _running_tag.is_ready() and value != running:
			_running_tag.write_bit(value)
		running = value
		_update_status_visuals()

## Reported output current (REAL).
@export var output_current: float = 0.0:
	set(value):
		if _output_current_tag.is_ready() and value != output_current:
			_output_current_tag.write_float32(value)
		output_current = value

## Reported output voltage (REAL).
@export var output_voltage: float = 0.0:
	set(value):
		if _output_voltage_tag.is_ready() and value != output_voltage:
			_output_voltage_tag.write_float32(value)
		output_voltage = value

## Reported motor velocity (REAL).
@export var velocity: float = 0.0:
	set(value):
		if _velocity_tag.is_ready() and value != velocity:
			_velocity_tag.write_float32(value)
		velocity = value

## Generated trip fault code (DINT). Cleared to 0 on `clear_fault` rising edge.
@export var trip_fault_code: int = 0:
	set(value):
		if _trip_fault_code_tag.is_ready() and value != trip_fault_code:
			_trip_fault_code_tag.write_int32(value)
		trip_fault_code = value


@export_category("Command Inputs")

## PLC stop command (BOOL). Read-only — driven by PLC.
@export var stop: bool = false
## PLC start command (BOOL).
@export var start: bool = false
## PLC direction bit 0 (BOOL).
@export var direction_cmd_0: bool = false
## PLC direction bit 1 (BOOL).
@export var direction_cmd_1: bool = false
## PLC commanded velocity (REAL).
@export var commanded_velocity: float = 0.0
## PLC clear-fault command (BOOL). Rising edge clears `trip_fault_code`.
@export var clear_fault: bool = false
## PLC dynamic accel time (REAL).
@export var dynamic_accel_time: float = 0.0
## PLC dynamic decel time (REAL).
@export var dynamic_decel_time: float = 0.0


@export_category("Communications")

## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group used by every APF tag.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value

# Write tags (we send these values to the PLC).
## ConnectionFaulted tag.[br]Datatype: [code]BOOL[/code]
@export var connection_faulted_tag_name: String = ""
## KeypadHandMode tag.[br]Datatype: [code]BOOL[/code]
@export var keypad_hand_mode_tag_name: String = ""
## DisconnectClosed tag.[br]Datatype: [code]BOOL[/code]
@export var disconnect_closed_tag_name: String = ""
## Fault tag.[br]Datatype: [code]BOOL[/code]
@export var fault_tag_name: String = ""
## Running tag.[br]Datatype: [code]BOOL[/code]
@export var running_tag_name: String = ""
## OutputCurrent tag.[br]Datatype: [code]REAL[/code]
@export var output_current_tag_name: String = ""
## OutputVoltage tag.[br]Datatype: [code]REAL[/code]
@export var output_voltage_tag_name: String = ""
## Velocity tag.[br]Datatype: [code]REAL[/code]
@export var velocity_tag_name: String = ""
## TripFaultCode tag.[br]Datatype: [code]DINT[/code]
@export var trip_fault_code_tag_name: String = ""

# Read tags (PLC drives these values).
## Stop tag.[br]Datatype: [code]BOOL[/code]
@export var stop_tag_name: String = ""
## Start tag.[br]Datatype: [code]BOOL[/code]
@export var start_tag_name: String = ""
## DirectionCmd_0 tag.[br]Datatype: [code]BOOL[/code]
@export var direction_cmd_0_tag_name: String = ""
## DirectionCmd_1 tag.[br]Datatype: [code]BOOL[/code]
@export var direction_cmd_1_tag_name: String = ""
## CommandedVelocity tag.[br]Datatype: [code]REAL[/code]
@export var commanded_velocity_tag_name: String = ""
## ClearFault tag.[br]Datatype: [code]BOOL[/code] — rising edge clears `trip_fault_code`.
@export var clear_fault_tag_name: String = ""
## DynamicAccelTime tag.[br]Datatype: [code]REAL[/code]
@export var dynamic_accel_time_tag_name: String = ""
## DynamicDecelTime tag.[br]Datatype: [code]REAL[/code]
@export var dynamic_decel_time_tag_name: String = ""


# Status condition for each pilot lens / status label, in slot order.
# Index → property mapping is stable: matches the inspector ordering.
const STATUS_COUNT: int = 5

@onready var _switch_handle: Node3D = $APF/APF_Root/SwitchHandle
@onready var _name_label: Label3D = get_node_or_null("APF/APF_Root/ControlPanel/NameLabel") as Label3D
@onready var _status_labels: Array[Label3D] = [
	get_node_or_null("APF/APF_Root/PilotBezel_0/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_1/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_2/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_3/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_4/StatusLabel") as Label3D,
]
@onready var _pilot_lenses: Array[MeshInstance3D] = [
	get_node_or_null("APF/APF_Root/PilotLens_0") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_1") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_2") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_3") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_4") as MeshInstance3D,
]

var _connection_faulted_tag := OIPCommsTag.new()
var _keypad_hand_mode_tag := OIPCommsTag.new()
var _disconnect_closed_tag := OIPCommsTag.new()
var _fault_tag := OIPCommsTag.new()
var _running_tag := OIPCommsTag.new()
var _output_current_tag := OIPCommsTag.new()
var _output_voltage_tag := OIPCommsTag.new()
var _velocity_tag := OIPCommsTag.new()
var _trip_fault_code_tag := OIPCommsTag.new()
var _stop_tag := OIPCommsTag.new()
var _start_tag := OIPCommsTag.new()
var _direction_cmd_0_tag := OIPCommsTag.new()
var _direction_cmd_1_tag := OIPCommsTag.new()
var _commanded_velocity_tag := OIPCommsTag.new()
var _clear_fault_tag := OIPCommsTag.new()
var _dynamic_accel_time_tag := OIPCommsTag.new()
var _dynamic_decel_time_tag := OIPCommsTag.new()

var _last_clear_fault: bool = false
var _pilot_materials_made_unique: Array[bool] = [false, false, false, false, false]


func _validate_property(property: Dictionary) -> void:
	# Sensed / driven values — read-only in inspector.
	var read_only_props: PackedStringArray = [
		"connection_faulted", "keypad_hand_mode", "disconnect_closed",
		"fault", "running",
		"output_current", "output_voltage", "velocity", "trip_fault_code",
		"stop", "start", "direction_cmd_0", "direction_cmd_1",
		"commanded_velocity", "clear_fault",
		"dynamic_accel_time", "dynamic_decel_time",
	]
	if property.name in read_only_props:
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
		return
	# All tag-name fields share one tag group; gate visibility on enable_comms.
	var tag_fields: PackedStringArray = [
		"connection_faulted_tag_name", "keypad_hand_mode_tag_name",
		"disconnect_closed_tag_name", "fault_tag_name", "running_tag_name",
		"output_current_tag_name", "output_voltage_tag_name",
		"velocity_tag_name", "trip_fault_code_tag_name",
		"stop_tag_name", "start_tag_name",
		"direction_cmd_0_tag_name", "direction_cmd_1_tag_name",
		"commanded_velocity_tag_name", "clear_fault_tag_name",
		"dynamic_accel_time_tag_name", "dynamic_decel_time_tag_name",
	]
	for field: String in tag_fields:
		if OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", field):
			return


func _enter_tree() -> void:
	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	EditorInterface.simulation_started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _exit_tree() -> void:
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _ready() -> void:
	if _name_label:
		_name_label.text = name_text
	_apply_handle_position()
	_update_status_visuals()


## E-click in pilot mode (and editor C-shortcut) toggles disconnect.
func use() -> void:
	disconnect_closed = not disconnect_closed


func _animate_handle() -> void:
	if not _switch_handle:
		return
	var target_y: float = 0.0 if disconnect_closed else HANDLE_OPEN_ANGLE
	var tween := create_tween()
	tween.tween_property(_switch_handle, "rotation:y", target_y, HANDLE_TWEEN_DURATION)


func _apply_handle_position() -> void:
	if not _switch_handle:
		return
	_switch_handle.rotation.y = 0.0 if disconnect_closed else HANDLE_OPEN_ANGLE


## Update the colour of every status label and pilot lens based on the
## current boolean state. Called whenever any contributing flag changes.
func _update_status_visuals() -> void:
	var bad_states: Array[bool] = [
		connection_faulted,
		keypad_hand_mode,
		not disconnect_closed,
		fault,
		not running,
	]
	for i in range(STATUS_COUNT):
		var bad: bool = bad_states[i]
		if i < _status_labels.size() and _status_labels[i]:
			_status_labels[i].modulate = STATUS_BAD_COLOR if bad else STATUS_OK_COLOR
		if i < _pilot_lenses.size() and _pilot_lenses[i]:
			_set_lens_color(i, bad)


func _set_lens_color(idx: int, bad: bool) -> void:
	var lens := _pilot_lenses[idx]
	if not lens:
		return
	_ensure_lens_material_unique(idx)
	var mat := lens.get_surface_override_material(0) as StandardMaterial3D
	if not mat:
		return
	var color: Color = PILOT_BAD_COLOR if bad else PILOT_OK_COLOR
	mat.albedo_color = color
	mat.emission = color
	mat.emission_energy_multiplier = 1.0


func _ensure_lens_material_unique(idx: int) -> void:
	if _pilot_materials_made_unique[idx]:
		return
	var lens := _pilot_lenses[idx]
	if not lens:
		return
	var current_override := lens.get_surface_override_material(0)
	if current_override:
		var unique_mat := current_override.duplicate() as Material
		lens.set_surface_override_material(0, unique_mat)
	else:
		var base_mat := lens.mesh.surface_get_material(0) as StandardMaterial3D
		if base_mat:
			var unique_mat := base_mat.duplicate() as Material
			unique_mat.resource_local_to_scene = true
			lens.set_surface_override_material(0, unique_mat)
		else:
			var fresh := StandardMaterial3D.new()
			fresh.emission_enabled = true
			fresh.resource_local_to_scene = true
			lens.set_surface_override_material(0, fresh)
	_pilot_materials_made_unique[idx] = true


func _on_simulation_started() -> void:
	if not enable_comms:
		return
	_connection_faulted_tag.register(tag_group_name, connection_faulted_tag_name)
	_keypad_hand_mode_tag.register(tag_group_name, keypad_hand_mode_tag_name)
	_disconnect_closed_tag.register(tag_group_name, disconnect_closed_tag_name)
	_fault_tag.register(tag_group_name, fault_tag_name)
	_running_tag.register(tag_group_name, running_tag_name)
	_output_current_tag.register(tag_group_name, output_current_tag_name)
	_output_voltage_tag.register(tag_group_name, output_voltage_tag_name)
	_velocity_tag.register(tag_group_name, velocity_tag_name)
	_trip_fault_code_tag.register(tag_group_name, trip_fault_code_tag_name)
	_stop_tag.register(tag_group_name, stop_tag_name)
	_start_tag.register(tag_group_name, start_tag_name)
	_direction_cmd_0_tag.register(tag_group_name, direction_cmd_0_tag_name)
	_direction_cmd_1_tag.register(tag_group_name, direction_cmd_1_tag_name)
	_commanded_velocity_tag.register(tag_group_name, commanded_velocity_tag_name)
	_clear_fault_tag.register(tag_group_name, clear_fault_tag_name)
	_dynamic_accel_time_tag.register(tag_group_name, dynamic_accel_time_tag_name)
	_dynamic_decel_time_tag.register(tag_group_name, dynamic_decel_time_tag_name)


func _tag_group_initialized(group: String) -> void:
	if _connection_faulted_tag.on_group_initialized(group):
		_connection_faulted_tag.write_bit(connection_faulted)
	if _keypad_hand_mode_tag.on_group_initialized(group):
		_keypad_hand_mode_tag.write_bit(keypad_hand_mode)
	if _disconnect_closed_tag.on_group_initialized(group):
		_disconnect_closed_tag.write_bit(disconnect_closed)
	if _fault_tag.on_group_initialized(group):
		_fault_tag.write_bit(fault)
	if _running_tag.on_group_initialized(group):
		_running_tag.write_bit(running)
	if _output_current_tag.on_group_initialized(group):
		_output_current_tag.write_float32(output_current)
	if _output_voltage_tag.on_group_initialized(group):
		_output_voltage_tag.write_float32(output_voltage)
	if _velocity_tag.on_group_initialized(group):
		_velocity_tag.write_float32(velocity)
	if _trip_fault_code_tag.on_group_initialized(group):
		_trip_fault_code_tag.write_int32(trip_fault_code)
	# Read tags must still call on_group_initialized so is_ready() flips true.
	_stop_tag.on_group_initialized(group)
	_start_tag.on_group_initialized(group)
	_direction_cmd_0_tag.on_group_initialized(group)
	_direction_cmd_1_tag.on_group_initialized(group)
	_commanded_velocity_tag.on_group_initialized(group)
	_clear_fault_tag.on_group_initialized(group)
	_dynamic_accel_time_tag.on_group_initialized(group)
	_dynamic_decel_time_tag.on_group_initialized(group)


func _tag_group_polled(group: String) -> void:
	if not enable_comms:
		return
	if _stop_tag.matches_group(group):
		stop = _stop_tag.read_bit()
	if _start_tag.matches_group(group):
		start = _start_tag.read_bit()
	if _direction_cmd_0_tag.matches_group(group):
		direction_cmd_0 = _direction_cmd_0_tag.read_bit()
	if _direction_cmd_1_tag.matches_group(group):
		direction_cmd_1 = _direction_cmd_1_tag.read_bit()
	if _commanded_velocity_tag.matches_group(group):
		commanded_velocity = _commanded_velocity_tag.read_float32()
	if _clear_fault_tag.matches_group(group):
		var new_clear: bool = _clear_fault_tag.read_bit()
		# Rising edge → clear the generated fault code.
		if new_clear and not _last_clear_fault:
			trip_fault_code = 0
		_last_clear_fault = new_clear
		clear_fault = new_clear
	if _dynamic_accel_time_tag.matches_group(group):
		dynamic_accel_time = _dynamic_accel_time_tag.read_float32()
	if _dynamic_decel_time_tag.matches_group(group):
		dynamic_decel_time = _dynamic_decel_time_tag.read_float32()
