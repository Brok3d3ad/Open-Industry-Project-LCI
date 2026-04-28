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
const HANDLE_CLOSED_ANGLE: float = 0.0
const HANDLE_OPEN_ANGLE: float = PI / 2.0
const HANDLE_TWEEN_DURATION: float = 0.15
const TRIP_FAULT_CODE_RANGE: Vector2i = Vector2i(1000, 9999)
## Standard conversion: 1 foot per minute = 0.00508 m/s.
const FPM_TO_MS: float = 0.00508
## `commanded_velocity` is normalised against this full-scale value when
## computing the conveyor target — at 30 the drive runs at `design_fpm`.
const COMMANDED_VELOCITY_FULL_SCALE: float = 30.0
## Velocity-scale value (0..30) that keypad jog (R held) commands. Belt
## speed in FPM is `KEYPAD_JOG_VELOCITY / 30 × design_fpm`, so jog is
## always half the design speed regardless of how `design_fpm` is set.
const KEYPAD_JOG_VELOCITY: float = 15.0
## How far the pilot's interaction ray reaches for prompt detection.
const PILOT_AIM_RANGE: float = 3.0

# Local labels — never sent to PLC.
@export var name_text: String = "APF":
	set(value):
		name_text = value
		if _name_label:
			_name_label.text = name_text

## Design FPM rating of the drive — the belt speed at full
## `commanded_velocity`. Local property (not a tag). The visible FPM
## label tracks the live ramped belt speed.
@export var design_fpm: int = 30


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
## In keypad mode the drive is **always stopped** unless jog (R) is held.
## PLC start/stop/direction/commanded_velocity are ignored entirely; T
## flips the jog direction (forward / reverse). Exiting (Q again) clears
## the sub-state; the PLC must issue a fresh start to resume remote.
@export var keypad_hand_mode: bool = false:
	set(value):
		var was_on: bool = keypad_hand_mode
		if _keypad_hand_mode_tag.is_ready() and value != keypad_hand_mode:
			_keypad_hand_mode_tag.write_bit(value)
		keypad_hand_mode = value
		if keypad_hand_mode != was_on:
			_keypad_reverse = false
			_keypad_jogging = false
		# Re-evaluate `running` against the new mode (gate path changes).
		running = true
		_update_status_visuals()
		_update_interaction_prompt()

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

## true when the motor is running. Red when false (drive stopped). The
## gate depends on the active mode:
## - Remote (default): requires `start && !stop && commanded_velocity > 0`.
## - Keypad (`keypad_hand_mode`): requires `_keypad_jogging` only — the
##   drive is stopped unless R is held. T just flips jog direction.
##   PLC start/stop/commanded are ignored.
## Either way, no fault (`fault`, `connection_faulted`,
## `not disconnect_closed`) is required.
##
## Velocity tracking: in remote mode `velocity` mirrors
## `commanded_velocity` while running; in keypad mode it's
## `KEYPAD_JOG_VELOCITY` while jogging, 0 otherwise.
@export var running: bool = false:
	set(value):
		var operational: bool
		if keypad_hand_mode:
			operational = _keypad_jogging
		else:
			operational = start and not stop and commanded_velocity > 0.0
		var gated: bool = (value
				and operational
				and not fault and disconnect_closed and not connection_faulted
				and safe_torque_enabled)
		if _running_tag.is_ready() and gated != running:
			_running_tag.write_bit(gated)
		running = gated
		velocity = _compute_reported_velocity() if running else 0.0
		_update_status_visuals()


## Reported `velocity` for the running PLC tag. In remote mode it mirrors
## the PLC's command; in keypad mode jog reports `KEYPAD_JOG_VELOCITY`.
func _compute_reported_velocity() -> float:
	if not keypad_hand_mode:
		return commanded_velocity
	if _keypad_jogging:
		return KEYPAD_JOG_VELOCITY
	return 0.0

## Safe Torque Off feedback (BOOL). High = torque enabled (safe to run).
## Driven by the assigned `epc_paths`: while ANY EPC is tripped this
## goes low and forces `running = false`. Without any EPC assigned it
## stays high so the gate doesn't block remote operation.
@export var safe_torque_enabled: bool = true:
	set(value):
		if _safe_torque_enabled_tag.is_ready() and value != safe_torque_enabled:
			_safe_torque_enabled_tag.write_bit(value)
		safe_torque_enabled = value
		if not safe_torque_enabled:
			running = false
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

## Reported motor velocity (REAL). Driven by the `running` setter:
## mirrors `commanded_velocity` while running, snaps to 0 when stopped.
## Also recomputes `output_current = velocity * 2` (per spec).
@export var velocity: float = 0.0:
	set(value):
		if _velocity_tag.is_ready() and value != velocity:
			_velocity_tag.write_float32(value)
		velocity = value
		output_current = velocity * 2.0

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

## How long `connection_faulted` stays true after a connection fault fires
## (auto-timer or `connection_fault_on_demand`) before auto-clearing.
@export_range(0.1, 600.0, 0.1, "suffix:s") var connection_fault_duration_seconds: float = 2.0

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


@export_category("Safety")

## Optional EPCs (Emergency Pull Cords) coupled to this drive. While
## **any** assigned EPC is tripped, `safe_torque_enabled` reads `false`
## and the running gate denies — the drive cannot run. Leave the list
## empty to disable the gate. Add as many EPCs as the safety chain
## requires; `tripped == true` on any one drops STO.
@export var epc_paths: Array[NodePath]:
	set(value):
		epc_paths = value
		_resolve_epcs()

## Optional auxiliary disconnects coupled to this drive. While **any**
## assigned aux is tripped, `connection_faulted` is forced HIGH (treated
## as a comms loss). On the rising edge of any aux trip a fresh random
## `trip_fault_code` is generated and `fault` is set. Closing all auxes
## clears `connection_faulted` (the latched fault must still be cleared
## via the PLC `clear_fault` rising edge).
@export var aux_disconnect_paths: Array[NodePath]:
	set(value):
		aux_disconnect_paths = value
		_resolve_aux_disconnects()


@export_category("Conveyor Coupling")

## The conveyor (BeltConveyor / RollerConveyor / assembly) this drive
## controls. Leave empty to run the APF as a stand-alone drive sim.
## Belt speed = (commanded_velocity / 30) × design_fpm × FPM_TO_MS,
## signed per direction bits, ramped over
## `dynamic_accel_time` / `dynamic_decel_time`.
@export var conveyor_path: NodePath:
	set(value):
		conveyor_path = value
		_resolve_conveyor()


@export_category("Command Inputs")

## PLC stop command (BOOL). Read-only — driven by PLC.
@export var stop: bool = false
## PLC start command (BOOL).
@export var start: bool = false
## PLC direction bit 0 (BOOL).
@export var direction_cmd_0: bool = false
## PLC direction bit 1 (BOOL).
@export var direction_cmd_1: bool = false
## PLC commanded velocity (REAL). Drives the conveyor speed setpoint:
## scaled against `COMMANDED_VELOCITY_FULL_SCALE` (30) and multiplied by
## `design_fpm` to get the target belt speed in FPM. The `FpmLabel`
## follows the live ramped speed, not this command directly.
@export var commanded_velocity: float = 0.0
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
## SafeTorqueEnabled tag.[br]Datatype: [code]BOOL[/code] — high when
## torque is enabled (no EPC trip), low when an assigned EPC is tripped.
@export var safe_torque_enabled_tag_name: String = ""
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
## ClearFault tag.[br]Datatype: [code]BOOL[/code] — rising edge clears `trip_fault_code` and `fault`.
@export var clear_fault_tag_name: String = ""
## DynamicAccelTime tag.[br]Datatype: [code]REAL[/code]
@export var dynamic_accel_time_tag_name: String = ""
## DynamicDecelTime tag.[br]Datatype: [code]REAL[/code]
@export var dynamic_decel_time_tag_name: String = ""


# Status condition for each pilot lens / status label, in slot order.
# Index → property mapping is stable: matches the inspector ordering.
# 0 ConnectionFaulted, 1 KeypadHandMode, 2 DisconnectClosed, 3 Fault,
# 4 Running, 5 SafeTorqueEnabled.
const STATUS_COUNT: int = 6

@onready var _switch_handle: Node3D = $APF/APF_Root/SwitchHandle
@onready var _name_label: Label3D = get_node_or_null("APF/APF_Root/ControlPanel/NameLabel") as Label3D
@onready var _fpm_label: Label3D = get_node_or_null("APF/APF_Root/ControlPanel/FpmLabel") as Label3D
@onready var _interaction_prompt: Label3D = get_node_or_null("InteractionPrompt") as Label3D
@onready var _status_labels: Array[Label3D] = [
	get_node_or_null("APF/APF_Root/PilotBezel_0/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_1/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_2/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_3/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_4/StatusLabel") as Label3D,
	get_node_or_null("APF/APF_Root/PilotBezel_5/StatusLabel") as Label3D,
]
@onready var _pilot_lenses: Array[MeshInstance3D] = [
	get_node_or_null("APF/APF_Root/PilotLens_0") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_1") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_2") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_3") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_4") as MeshInstance3D,
	get_node_or_null("APF/APF_Root/PilotLens_5") as MeshInstance3D,
]

var _connection_faulted_tag := OIPCommsTag.new()
var _keypad_hand_mode_tag := OIPCommsTag.new()
var _disconnect_closed_tag := OIPCommsTag.new()
var _fault_tag := OIPCommsTag.new()
var _running_tag := OIPCommsTag.new()
var _safe_torque_enabled_tag := OIPCommsTag.new()
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
var _pilot_materials_made_unique: Array[bool] = [false, false, false, false, false, false]
var _simulating: bool = false
var _trip_elapsed: float = 0.0
var _connection_elapsed: float = 0.0
var _conveyor: Node = null
var _epcs: Array[Node] = []
var _aux_disconnects: Array[Node] = []
var _aux_tripped_prev: bool = false
var _belt_speed: float = 0.0
var _ramp_rate: float = 0.0
var _last_ramp_target: float = 0.0
var _pilot_aiming: bool = false
var _keypad_reverse: bool = false
var _keypad_jogging: bool = false
var _prev_q: bool = false
var _prev_t: bool = false
var _prev_r: bool = false


func _validate_property(property: Dictionary) -> void:
	# Sensed / driven values — read-only in inspector.
	var read_only_props: PackedStringArray = [
		"connection_faulted", "keypad_hand_mode", "disconnect_closed",
		"fault", "running", "safe_torque_enabled",
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
		"safe_torque_enabled_tag_name",
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
	_simulating = false
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _ready() -> void:
	if _name_label:
		_name_label.text = name_text
	if _interaction_prompt:
		_interaction_prompt.visible = false
	_resolve_conveyor()
	_resolve_epcs()
	_resolve_aux_disconnects()
	_update_fpm_label()
	_apply_handle_position()
	_update_status_visuals()


func _process(delta: float) -> void:
	if not _simulating:
		if _pilot_aiming:
			_pilot_aiming = false
			_update_interaction_prompt()
		return
	_trip_elapsed += delta
	if _trip_elapsed >= auto_trip_interval_minutes * 60.0:
		_trip_elapsed = 0.0
		_trigger_random_trip()
	_connection_elapsed += delta
	if _connection_elapsed >= auto_connection_fault_interval_minutes * 60.0:
		_connection_elapsed = 0.0
		_trigger_connection_fault()


func _physics_process(delta: float) -> void:
	if not _simulating:
		return
	# Pilot-aim ray cast must run here — physics runs on a separate thread
	# (`3d/run_on_separate_thread=true` in project.godot) and the space
	# state is null from `_process`.
	_update_pilot_aim()
	if _pilot_aiming:
		_poll_keypad_inputs()
	_poll_safe_torque()
	_poll_aux_state()
	var target: float = _compute_target_belt_speed()
	if not is_equal_approx(_belt_speed, target):
		_advance_belt_speed(target, delta)
		_update_fpm_label()
	if _conveyor and "speed" in _conveyor:
		_conveyor.set("speed", _belt_speed)


## E-click in pilot mode (and editor C-shortcut) toggles disconnect.
func use() -> void:
	disconnect_closed = not disconnect_closed


## Set fault + a fresh random trip code. No-op if already faulted.
func _trigger_random_trip() -> void:
	if fault:
		return
	trip_fault_code = randi_range(TRIP_FAULT_CODE_RANGE.x, TRIP_FAULT_CODE_RANGE.y)
	fault = true


## Pulse `connection_faulted` true for `connection_fault_duration_seconds`,
## simulating a transient comms blip.
func _trigger_connection_fault() -> void:
	if connection_faulted:
		return
	connection_faulted = true
	await get_tree().create_timer(connection_fault_duration_seconds).timeout
	# `_simulating` may have flipped off (scene closed) during the await; check
	# we still exist before mutating state.
	if is_inside_tree():
		connection_faulted = false


## Resolve every NodePath in `epc_paths` to a live node. Filters out
## empties and unresolvable paths. Called on `epc_paths` change and in
## `_ready` (deferred for trees not yet built).
func _resolve_epcs() -> void:
	_epcs.clear()
	if not is_inside_tree():
		return
	for path: NodePath in epc_paths:
		if path.is_empty():
			continue
		var node: Node = get_node_or_null(path)
		if node:
			_epcs.append(node)


## Returns true if any assigned EPC reports `tripped == true`. Empty list
## (no EPCs assigned) → returns false (no constraint).
func _any_epc_tripped() -> bool:
	for epc: Node in _epcs:
		if not is_instance_valid(epc):
			continue
		if "tripped" in epc and bool(epc.get("tripped")):
			return true
	return false


## Poll the assigned EPC chain and update `safe_torque_enabled` if its
## state has changed. Called per physics tick.
func _poll_safe_torque() -> void:
	var new_sto: bool = not _any_epc_tripped()
	if new_sto != safe_torque_enabled:
		safe_torque_enabled = new_sto


## Resolve every NodePath in `aux_disconnect_paths` to a live node.
## Mirrors `_resolve_epcs`.
func _resolve_aux_disconnects() -> void:
	_aux_disconnects.clear()
	if not is_inside_tree():
		return
	for path: NodePath in aux_disconnect_paths:
		if path.is_empty():
			continue
		var node: Node = get_node_or_null(path)
		if node:
			_aux_disconnects.append(node)


## Returns true if any assigned auxiliary disconnect is tripped.
func _any_aux_tripped() -> bool:
	for aux: Node in _aux_disconnects:
		if not is_instance_valid(aux):
			continue
		if "tripped" in aux and bool(aux.get("tripped")):
			return true
	return false


## Poll the assigned aux-disconnect chain. While any aux is tripped,
## `connection_faulted` is forced HIGH; on the rising edge a fresh random
## trip code is generated. Closing all auxes drops `connection_faulted`
## back to false; the latched `fault` requires a PLC clear-fault edge.
func _poll_aux_state() -> void:
	var now: bool = _any_aux_tripped()
	if now == _aux_tripped_prev:
		return
	if now:
		# Rising edge: latch a trip code and force comms fault.
		_trigger_random_trip()
		if not connection_faulted:
			connection_faulted = true
	else:
		# Falling edge: release the comms-fault gate. `fault` stays latched.
		if connection_faulted:
			connection_faulted = false
	_aux_tripped_prev = now


func _resolve_conveyor() -> void:
	if conveyor_path.is_empty():
		_conveyor = null
		return
	if not is_inside_tree():
		# `_ready` runs the resolve once we're in the tree.
		return
	_conveyor = get_node_or_null(conveyor_path)


## Target belt speed in m/s based on running + direction bits + commanded
## velocity. In remote mode `commanded_velocity` is normalised against
## `COMMANDED_VELOCITY_FULL_SCALE` (30): at 30 the drive runs at
## `design_fpm` (FPM); below scales linearly down to 0; above scales up.
## Both direction bits true OR both false → 0 (no commanded direction).
##
## In keypad mode the PLC inputs are ignored. Speed is
## `KEYPAD_JOG_VELOCITY / 30 × design_fpm` while jog (R) is held;
## anything else returns 0 (drive stopped). Direction follows
## `_keypad_reverse` toggled by T.
func _compute_target_belt_speed() -> float:
	if not running:
		return 0.0
	var dir_fwd: bool
	var fpm: float
	if keypad_hand_mode:
		if not _keypad_jogging:
			return 0.0
		fpm = (KEYPAD_JOG_VELOCITY / COMMANDED_VELOCITY_FULL_SCALE) * float(design_fpm)
		dir_fwd = not _keypad_reverse
	else:
		var fwd: bool = direction_cmd_0 and not direction_cmd_1
		var rev: bool = direction_cmd_1 and not direction_cmd_0
		if not fwd and not rev:
			return 0.0
		dir_fwd = fwd
		var velocity_scale: float = abs(commanded_velocity) / COMMANDED_VELOCITY_FULL_SCALE
		fpm = velocity_scale * float(design_fpm)
	var mag: float = fpm * FPM_TO_MS
	return mag if dir_fwd else -mag


## Step `_belt_speed` toward `target` by one frame's worth of ramp. The
## ramp is **linear**: any current → target transition completes in
## exactly the chosen ramp_time seconds. We cache the rate when the
## target changes (`|diff_at_change| / ramp_time`) and reuse it across
## subsequent ticks so the slope stays constant during the ramp instead
## of decaying with the shrinking diff. Picks `dynamic_accel_time` when
## the speed magnitude is growing (moving away from 0), otherwise
## `dynamic_decel_time` (moving toward 0, including reversing through 0).
func _advance_belt_speed(target: float, delta: float) -> void:
	var diff: float = target - _belt_speed
	if not is_equal_approx(target, _last_ramp_target):
		var change_dir: float = signf(diff)
		var growing: bool = (is_zero_approx(_belt_speed)
				or signf(_belt_speed) == change_dir)
		var ramp_time: float = dynamic_accel_time if growing else dynamic_decel_time
		_ramp_rate = (abs(diff) / ramp_time) if ramp_time > 0.0 else 0.0
		_last_ramp_target = target
	if is_zero_approx(diff):
		return
	if _ramp_rate <= 0.0:
		# `ramp_time` was 0 → snap to target.
		_belt_speed = target
		return
	var step: float = signf(diff) * _ramp_rate * delta
	if abs(step) >= abs(diff):
		_belt_speed = target
	else:
		_belt_speed += step


func _update_fpm_label() -> void:
	if not _fpm_label:
		return
	var fpm: int = int(round(abs(_belt_speed) / FPM_TO_MS))
	_fpm_label.text = "FPM %d" % fpm


## Cast a ray forward from the active camera (the pilot's first-person
## view in simulation) and check whether the closest hit's parent chain
## reaches this APF. Updates `_pilot_aiming` and the prompt visibility.
func _update_pilot_aim() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var aiming: bool = false
	if camera:
		var origin: Vector3 = camera.global_position
		var to: Vector3 = origin - camera.global_transform.basis.z * PILOT_AIM_RANGE
		var space := get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(origin, to)
		var result := space.intersect_ray(query)
		if result and result.has("collider"):
			var node: Node = result.collider
			while node:
				if node == self:
					aiming = true
					break
				node = node.get_parent()
	if aiming != _pilot_aiming:
		_pilot_aiming = aiming
		_prev_q = false
		_prev_t = false
		_prev_r = false
		# Aiming away mid-jog must cancel the held action so the belt stops.
		if not _pilot_aiming and _keypad_jogging:
			_set_keypad_jogging(false)
		_update_interaction_prompt()


## Rebuild the multi-line interaction label shown when the pilot is
## aimed at this APF. Mirrors the `editor-pilot-mode` E-prompt style.
func _update_interaction_prompt() -> void:
	if not _interaction_prompt:
		return
	_interaction_prompt.visible = _pilot_aiming
	if not _pilot_aiming:
		return
	var lines: Array[String] = []
	lines.append("[E] %s" % ("Open Disconnect" if disconnect_closed else "Close Disconnect"))
	lines.append("[Q] %s" % ("Exit Keypad" if keypad_hand_mode else "Enter Keypad"))
	if keypad_hand_mode:
		var dir_label: String = "Reverse" if _keypad_reverse else "Forward"
		lines.append("[T] Direction: %s (toggle)" % dir_label)
		var jog_fpm: int = int(round(
				KEYPAD_JOG_VELOCITY / COMMANDED_VELOCITY_FULL_SCALE * float(design_fpm)))
		lines.append("[R] Hold to Jog (%d FPM)" % jog_fpm)
	_interaction_prompt.text = "\n".join(lines)


## Polled in `_physics_process` while aimed at the APF. Q (keypad mode)
## and T (direction) are edge-triggered. R is **held** — jog runs only
## while the key is physically down, so releasing immediately cancels.
func _poll_keypad_inputs() -> void:
	var q_now: bool = Input.is_physical_key_pressed(KEY_Q)
	var t_now: bool = Input.is_physical_key_pressed(KEY_T)
	var r_now: bool = Input.is_physical_key_pressed(KEY_R)
	if q_now and not _prev_q:
		_toggle_keypad_hand_mode()
	if keypad_hand_mode:
		if t_now and not _prev_t:
			_on_keypad_t()
		_set_keypad_jogging(r_now)
	_prev_q = q_now
	_prev_t = t_now
	_prev_r = r_now


## Held-jog primitive — driven from key polling and from the aim-out
## transition (so releasing aim cancels jog even before the next poll).
func _set_keypad_jogging(value: bool) -> void:
	if value == _keypad_jogging:
		return
	_keypad_jogging = value
	running = true
	_update_interaction_prompt()


func _toggle_keypad_hand_mode() -> void:
	keypad_hand_mode = not keypad_hand_mode
	# `keypad_hand_mode` setter handles state cleanup + running re-eval.


## T press in keypad mode: flip jog direction. Doesn't start the drive —
## drive only runs while R is held. If a jog is currently in progress
## the active belt motion will reverse on the next ramp tick.
func _on_keypad_t() -> void:
	_keypad_reverse = not _keypad_reverse
	if _keypad_jogging:
		# Already jogging — re-evaluate target so direction flips live.
		running = true
	_update_interaction_prompt()


func _animate_handle() -> void:
	if not _switch_handle:
		return
	var target_x: float = HANDLE_CLOSED_ANGLE if disconnect_closed else HANDLE_OPEN_ANGLE
	var tween := create_tween()
	tween.tween_property(_switch_handle, "rotation:x", target_x, HANDLE_TWEEN_DURATION)


func _apply_handle_position() -> void:
	if not _switch_handle:
		return
	_switch_handle.rotation.x = HANDLE_CLOSED_ANGLE if disconnect_closed else HANDLE_OPEN_ANGLE


## Update the colour of every status label and pilot lens based on the
## current boolean state. Called whenever any contributing flag changes.
func _update_status_visuals() -> void:
	var bad_states: Array[bool] = [
		connection_faulted,
		keypad_hand_mode,
		not disconnect_closed,
		fault,
		not running,
		not safe_torque_enabled,
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
	_safe_torque_enabled_tag.register(tag_group_name, safe_torque_enabled_tag_name)
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
	if _safe_torque_enabled_tag.on_group_initialized(group):
		_safe_torque_enabled_tag.write_bit(safe_torque_enabled)
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
		# `running` setter gates on `commanded_velocity > 0` and drives
		# `velocity` from the new value, so a refresh is the right hook.
		refresh_run = true
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
