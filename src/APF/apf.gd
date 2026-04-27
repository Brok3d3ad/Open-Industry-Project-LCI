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
const HANDLE_CLOSED_ANGLE: float = PI / 2.0
const HANDLE_OPEN_ANGLE: float = 0.0
const HANDLE_TWEEN_DURATION: float = 0.15
const CONNECTION_FAULT_DURATION: float = 2.0
const TRIP_FAULT_CODE_RANGE: Vector2i = Vector2i(1000, 9999)

# Local labels — never sent to PLC.
@export var name_text: String = "APF":
	set(value):
		name_text = value
		if _name_label:
			_name_label.text = name_text

## Design FPM displayed on the drive face (local label only, no tag).
@export var design_fpm: int = 30:
	set(value):
		design_fpm = value
		if _fpm_label:
			_fpm_label.text = "FPM %d" % design_fpm


@export_category("State Outputs")

## true when comms to the drive are faulted. Red label/lens when true.
## Forces `running = false` while true.
@export var connection_faulted: bool = false:
	set(value):
		if _connection_faulted_tag.is_ready() and value != connection_faulted:
			_connection_faulted_tag.write_bit(value)
		connection_faulted = value
		if connection_faulted:
			running = false
		_update_status_visuals()

## true when the operator has the drive in keypad/hand mode. Red when true.
@export var keypad_hand_mode: bool = false:
	set(value):
		if _keypad_hand_mode_tag.is_ready() and value != keypad_hand_mode:
			_keypad_hand_mode_tag.write_bit(value)
		keypad_hand_mode = value
		_update_status_visuals()

## Disconnect switch closed (drive energised). Default true; pilot E-click
## flips it to false (handle rotates 90° → 0°). Red when false (NC fail-safe).
## Forces `running = false` while open.
@export var disconnect_closed: bool = true:
	set(value):
		if _disconnect_closed_tag.is_ready() and value != disconnect_closed:
			_disconnect_closed_tag.write_bit(value)
		disconnect_closed = value
		if not disconnect_closed:
			running = false
		_update_status_visuals()
		_animate_handle()

## true when the drive has tripped on a fault. Red when true. Forces
## `running = false` while true; cleared by `clear_fault` rising edge.
@export var fault: bool = false:
	set(value):
		if _fault_tag.is_ready() and value != fault:
			_fault_tag.write_bit(value)
		fault = value
		if fault:
			running = false
		_update_status_visuals()

## true when the motor is running. Red when false (drive stopped). Setter
## gates: assignment to true is ignored unless ALL of the following hold —
## `start` (run bit from PLC) is high, `stop` is low, `velocity` is non-zero,
## and there is no fault (`fault`, `connection_faulted`, `not disconnect_closed`).
@export var running: bool = false:
	set(value):
		var gated: bool = (value
				and start and not stop
				and velocity > 0.0
				and not fault and disconnect_closed and not connection_faulted)
		if _running_tag.is_ready() and gated != running:
			_running_tag.write_bit(gated)
		running = gated
		_update_status_visuals()

## Reported output current (REAL). Auto-computed as 2 × velocity; setter still
## writes to PLC when assigned externally.
@export var output_current: float = 60.0:
	set(value):
		if _output_current_tag.is_ready() and value != output_current:
			_output_current_tag.write_float32(value)
		output_current = value

## Reported output voltage (REAL). Default 10; configurable in inspector.
@export var output_voltage: float = 10.0:
	set(value):
		if _output_voltage_tag.is_ready() and value != output_voltage:
			_output_voltage_tag.write_float32(value)
		output_voltage = value

## Reported motor velocity (REAL). Setting velocity also recomputes
## `output_current = velocity * 2` (per spec). When velocity falls to
## zero the running setter's gate forces `running = false`.
@export var velocity: float = 30.0:
	set(value):
		if _velocity_tag.is_ready() and value != velocity:
			_velocity_tag.write_float32(value)
		velocity = value
		output_current = velocity * 2.0
		# Re-run the gate against the new velocity. The setter denies if
		# velocity is 0; otherwise lets through whatever start/stop says.
		running = start and not stop

## Generated trip fault code (DINT). Cleared to 0 on `clear_fault` rising edge.
@export var trip_fault_code: int = 0:
	set(value):
		if _trip_fault_code_tag.is_ready() and value != trip_fault_code:
			_trip_fault_code_tag.write_int32(value)
		trip_fault_code = value


@export_category("Auto-Faults")

## Average minutes between auto-generated trips during simulation.
@export_range(0.1, 60.0, 0.1, "suffix:min") var auto_trip_interval_minutes: float = 5.0

## Average minutes between auto-generated connection faults during simulation.
@export_range(0.1, 60.0, 0.1, "suffix:min") var auto_connection_fault_interval_minutes: float = 5.0

## Click in the inspector to trigger a random trip immediately.
## Auto-resets to false on the next frame (acts as a momentary button).
## The actual trip is deferred so the inspector's commit cycle finishes
## before we cascade-mutate `fault`, `trip_fault_code`, `running`, etc.
@export var trip_on_demand: bool = false:
	set(value):
		var rising_edge: bool = value and not trip_on_demand
		trip_on_demand = value
		if rising_edge:
			call_deferred("_handle_trip_on_demand")

## Click in the inspector to fire a connection fault pulse immediately.
## Auto-resets to false; same deferred-cascade behaviour as `trip_on_demand`.
@export var connection_fault_on_demand: bool = false:
	set(value):
		var rising_edge: bool = value and not connection_fault_on_demand
		connection_fault_on_demand = value
		if rising_edge:
			call_deferred("_handle_connection_fault_on_demand")


func _handle_trip_on_demand() -> void:
	_trigger_random_trip()
	trip_on_demand = false


func _handle_connection_fault_on_demand() -> void:
	_trigger_connection_fault()
	connection_fault_on_demand = false


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
## PLC commanded FPM (DINT).
@export var commanded_fpm: int = 0
## PLC clear-fault command (BOOL). Rising edge clears `trip_fault_code` and `fault`.
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
## CommandedFPM tag.[br]Datatype: [code]DINT[/code]
@export var commanded_fpm_tag_name: String = ""
## ClearFault tag.[br]Datatype: [code]BOOL[/code] — rising edge clears `trip_fault_code` and `fault`.
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
@onready var _fpm_label: Label3D = get_node_or_null("APF/APF_Root/ControlPanel/FpmLabel") as Label3D
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
var _commanded_fpm_tag := OIPCommsTag.new()
var _clear_fault_tag := OIPCommsTag.new()
var _dynamic_accel_time_tag := OIPCommsTag.new()
var _dynamic_decel_time_tag := OIPCommsTag.new()

var _last_clear_fault: bool = false
var _pilot_materials_made_unique: Array[bool] = [false, false, false, false, false]
var _simulating: bool = false
var _trip_elapsed: float = 0.0
var _connection_elapsed: float = 0.0


func _validate_property(property: Dictionary) -> void:
	# Sensed / driven values — read-only in inspector.
	var read_only_props: PackedStringArray = [
		"connection_faulted", "keypad_hand_mode", "disconnect_closed",
		"fault", "running",
		"output_current", "output_voltage", "velocity", "trip_fault_code",
		"stop", "start", "direction_cmd_0", "direction_cmd_1",
		"commanded_velocity", "commanded_fpm", "clear_fault",
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
		"commanded_velocity_tag_name", "commanded_fpm_tag_name",
		"clear_fault_tag_name",
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
	_simulating = false
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _ready() -> void:
	if _name_label:
		_name_label.text = name_text
	if _fpm_label:
		_fpm_label.text = "FPM %d" % design_fpm
	_apply_handle_position()
	_update_status_visuals()


func _process(delta: float) -> void:
	if not _simulating:
		return
	_trip_elapsed += delta
	if _trip_elapsed >= auto_trip_interval_minutes * 60.0:
		_trip_elapsed = 0.0
		_trigger_random_trip()
	_connection_elapsed += delta
	if _connection_elapsed >= auto_connection_fault_interval_minutes * 60.0:
		_connection_elapsed = 0.0
		_trigger_connection_fault()


## E-click in pilot mode (and editor C-shortcut) toggles disconnect.
func use() -> void:
	disconnect_closed = not disconnect_closed


## Set fault + a fresh random trip code. No-op if already faulted.
func _trigger_random_trip() -> void:
	if fault:
		return
	trip_fault_code = randi_range(TRIP_FAULT_CODE_RANGE.x, TRIP_FAULT_CODE_RANGE.y)
	fault = true


## Pulse `connection_faulted` true for ~2s, simulating a transient comms blip.
func _trigger_connection_fault() -> void:
	if connection_faulted:
		return
	connection_faulted = true
	await get_tree().create_timer(CONNECTION_FAULT_DURATION).timeout
	# `_simulating` may have flipped off (scene closed) during the await; check
	# we still exist before mutating state.
	if is_inside_tree():
		connection_faulted = false


func _animate_handle() -> void:
	if not _switch_handle:
		return
	var target_y: float = HANDLE_CLOSED_ANGLE if disconnect_closed else HANDLE_OPEN_ANGLE
	var tween := create_tween()
	tween.tween_property(_switch_handle, "rotation:y", target_y, HANDLE_TWEEN_DURATION)


func _apply_handle_position() -> void:
	if not _switch_handle:
		return
	_switch_handle.rotation.y = HANDLE_CLOSED_ANGLE if disconnect_closed else HANDLE_OPEN_ANGLE


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
		# Override already in the .tscn. If it's local-to-scene we can mutate
		# it directly (each scene instance has its own copy) — duplicating
		# again risks Godot logging "Failed to write" because the resulting
		# resource isn't tracked in the scene state.
		if not current_override.resource_local_to_scene:
			var unique_mat := current_override.duplicate() as Material
			unique_mat.resource_local_to_scene = true
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
	_simulating = true
	_trip_elapsed = 0.0
	_connection_elapsed = 0.0
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
	_commanded_fpm_tag.register(tag_group_name, commanded_fpm_tag_name)
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
	_commanded_fpm_tag.on_group_initialized(group)
	_clear_fault_tag.on_group_initialized(group)
	_dynamic_accel_time_tag.on_group_initialized(group)
	_dynamic_decel_time_tag.on_group_initialized(group)


func _tag_group_polled(group: String) -> void:
	if not enable_comms:
		return
	var refresh_run := false
	if _stop_tag.matches_group(group):
		stop = _stop_tag.read_bit()
		refresh_run = true
	if _start_tag.matches_group(group):
		start = _start_tag.read_bit()
		refresh_run = true
	if _direction_cmd_0_tag.matches_group(group):
		direction_cmd_0 = _direction_cmd_0_tag.read_bit()
	if _direction_cmd_1_tag.matches_group(group):
		direction_cmd_1 = _direction_cmd_1_tag.read_bit()
	if _commanded_velocity_tag.matches_group(group):
		commanded_velocity = _commanded_velocity_tag.read_float32()
		# The drive simulation tracks the PLC's command — output velocity
		# mirrors `commanded_velocity` (which also recomputes output_current
		# and re-evaluates `running` via the velocity setter).
		velocity = commanded_velocity
	if _commanded_fpm_tag.matches_group(group):
		commanded_fpm = _commanded_fpm_tag.read_int32()
	if _clear_fault_tag.matches_group(group):
		var new_clear: bool = _clear_fault_tag.read_bit()
		# Rising edge → clear both the generated trip code and the fault flag.
		if new_clear and not _last_clear_fault:
			trip_fault_code = 0
			fault = false
		_last_clear_fault = new_clear
		clear_fault = new_clear
	if _dynamic_accel_time_tag.matches_group(group):
		dynamic_accel_time = _dynamic_accel_time_tag.read_float32()
	if _dynamic_decel_time_tag.matches_group(group):
		dynamic_decel_time = _dynamic_decel_time_tag.read_float32()
	if refresh_run:
		# Re-evaluate `running` against the freshly-polled run/stop bits.
		# The setter gate handles fault/disconnect/connection conditions.
		running = start and not stop
