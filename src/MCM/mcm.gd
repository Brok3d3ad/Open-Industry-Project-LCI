@tool
class_name Mcm
extends Node3D

## How far the pilot's interaction ray reaches for prompt detection.
const PILOT_AIM_RANGE: float = 3.0

const _ESTOP_GLOW_COLOR := Color(1.0, 0.05, 0.05, 1.0)
const _ESTOP_GLOW_ENERGY: float = 4.0
## Default glow intensity for lit pushbutton caps driven by `*_LT_O` tags.
const _PB_GLOW_ENERGY: float = 4.0
## Fallback glow color for a lit pushbutton when its base material has no
## usable albedo (rare — most caps have a colored StandardMaterial3D).
const _PB_GLOW_FALLBACK_COLOR := Color(1.0, 0.85, 0.2, 1.0)

## Names of `_Btn`-suffixed nodes that are actually indicator lamps, not
## pressable controls — skipped during target discovery. Includes the
## panel status lamps wired up via `_STATUS_LAMPS`.
const _NON_INTERACTIVE_BTN_NAMES: Array[String] = [
	"PON_Btn", "ES_Btn",
	"UPS_PL_0_Btn", "UPS_PL_1_Btn", "UPS_PL_2_Btn",
	"NAT_1_Btn",
	"FireRelay_PL_FIRE_Btn", "FireRelay_PL_ON_Btn",
]

## Status-input lamps. One row per indicator on the panel — the lamp
## node's name (the `*_Btn` mesh) and the @export bool that drives it.
## Labels are baked into the scene file (`parts/MCM.tscn`) as `StatusLabel`
## Label3D children of each lamp, matching APF's `StatusLabel` pattern.
const _STATUS_LAMPS: Array[Dictionary] = [
	{"lamp": "UPS_PL_0_Btn",          "prop": "ups_fault"},
	{"lamp": "UPS_PL_1_Btn",          "prop": "on_ups"},
	{"lamp": "UPS_PL_2_Btn",          "prop": "ups_low"},
	{"lamp": "NAT_1_Btn",             "prop": "nat_switch_fault"},
	{"lamp": "FireRelay_PL_FIRE_Btn", "prop": "fire_relay"},
	{"lamp": "FireRelay_PL_ON_Btn",   "prop": "fire_relay"},
]

## Solid colors for the OK / BAD lamp states.
const _STATUS_LAMP_OK_COLOR := Color(0.0, 1.0, 0.15, 1.0)
const _STATUS_LAMP_BAD_COLOR := Color(1.0, 0.05, 0.05, 1.0)
const _STATUS_LAMP_ENERGY: float = 3.0

## World-space offset applied to the interaction prompt's position so the
## label floats above the aimed target instead of overlapping it.
const _LABEL_HOVER_OFFSET: Vector3 = Vector3(0.0, 0.08, 0.0)

## When true, the cabinet door swings open; when false, it returns closed.
@export var open: bool = false:
	set(value):
		open = value
		if not is_inside_tree():
			return
		_animate_to(_target_transform())

## Seconds for the door to travel between closed and open.
@export_range(0.05, 5.0, 0.05, "suffix:s") var open_duration: float = 0.6

## Offset (in Door_Pivot local space) a button travels when pressed.
## Negative Z points into the panel face for this GLB's orientation.
@export var button_press_offset: Vector3 = Vector3(0.0, 0.0, -0.003)

## Tween length for the down/up halves of a button press, in seconds.
@export_range(0.01, 0.5, 0.01, "suffix:s") var button_press_duration: float = 0.05

## How long a momentary button stays held down before releasing, in seconds.
@export_range(0.05, 1.0, 0.05, "suffix:s") var button_hold_duration: float = 0.15

## Perpendicular distance (world meters) from the pilot's view ray to a
## target's centre below which that target is considered "aimed at".
## Tune up if controls feel finicky to target, down if neighbours grab focus.
@export_range(0.005, 1.0, 0.005, "suffix:m") var aim_pick_radius: float = 0.24

@export_category("Status Inputs")

## Toggleable bools wired straight to the `_I` status tags so you can
## simulate UPS / NAT / fire events without external stimulus.
## Each property's value reflects "is this condition active?" — the wire
## polarity (NO vs NC) is handled where the tag is written.
##
## NC inputs (`ups_fault`, `fire_relay`): contact closed at rest, so the tag
## reads TRUE while healthy and drops to FALSE when the condition activates.
@export var ups_fault: bool = false:
	set(value):
		if _ups_fault_tag.is_ready() and value != ups_fault:
			_ups_fault_tag.write_bit(not value)
		ups_fault = value
		_drive_status_lamp("ups_fault", value)
@export var on_ups: bool = false:
	set(value):
		if _on_ups_tag.is_ready() and value != on_ups:
			_on_ups_tag.write_bit(value)
		on_ups = value
		_drive_status_lamp("on_ups", value)
@export var ups_low: bool = false:
	set(value):
		if _ups_low_tag.is_ready() and value != ups_low:
			_ups_low_tag.write_bit(value)
		ups_low = value
		_drive_status_lamp("ups_low", value)
@export var nat_switch_fault: bool = false:
	set(value):
		if _nat_switch_fault_tag.is_ready() and value != nat_switch_fault:
			_nat_switch_fault_tag.write_bit(value)
		nat_switch_fault = value
		_drive_status_lamp("nat_switch_fault", value)
@export var fire_relay: bool = false:
	set(value):
		if _fire_relay_tag.is_ready() and value != fire_relay:
			_fire_relay_tag.write_bit(not value)
		fire_relay = value
		_drive_status_lamp("fire_relay", value)

## True while the latched E-Stop mushroom is engaged. Read-only — driven
## by the cap's press state stored in `_targets`. Exposed so external
## safety chains (APF, etc.) can poll the MCM as a trip source.
var estop_engaged: bool:
	get:
		return _estop_pressed_now()

## Aggregate safety-trip signal. True when ANY of the configured panel
## inputs that should drop drive STO is active: fire alarm (`fire_relay`)
## or the latched E-Stop mushroom. APF's `mcm_paths` polls this.
var safety_tripped: bool:
	get:
		return fire_relay or estop_engaged

@export_category("Communications")

## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group used by every MCM tag.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value

# Pushbutton inputs (panel → PLC). Default names follow the AOI signature
# the user provided; rename per instance to re-target a different device.
@export var start_pb_tag_name: String = "MCM09_Start_PB_I"
@export var stop_pb_tag_name: String = "MCM09_Stop_PB_I"
@export var motor_fault_reset_pb_tag_name: String = "MCM09_Motor_Fault_Reset_PB_I"
@export var jam_restart_pb_tag_name: String = "MCM09_Jam_Restart_PB_I"
@export var low_air_pressure_reset_pb_tag_name: String = "MCM09_Low_Air_Pressure_Reset_PB_I"
@export var power_branch_fault_reset_pb_tag_name: String = "MCM09_Power_Branch_Fault_Reset_PB_I"
@export var communication_fault_reset_pb_tag_name: String = "MCM09_Communication_Fault_Reset_PB_I"

# E-Stop dual channels (NC safety: TRUE while not pressed, FALSE while engaged).
@export var estop_ch1_tag_name: String = "MCM09_EStop_PB_CH1_I"
@export var estop_ch2_tag_name: String = "MCM09_EStop_PB_CH2_I"

# Status inputs (panel → PLC).
@export var ups_fault_tag_name: String = "MCM09_UPS_Fault_I"
@export var on_ups_tag_name: String = "MCM09_On_UPS_I"
@export var ups_low_tag_name: String = "MCM09_UPS_Low_I"
@export var nat_switch_fault_tag_name: String = "MCM09_NAT_Switch_Fault_I"
@export var fire_relay_tag_name: String = "MCM09_Fire_Relay_I"

# Lamp commands (PLC → panel). Drive button cap glow via _tag_group_polled.
@export var start_lt_tag_name: String = "MCM09_Start_PB_LT_O"
@export var motor_fault_reset_lt_tag_name: String = "MCM09_Motor_Fault_Reset_PB_LT_O"
@export var jam_restart_lt_tag_name: String = "MCM09_Jam_Restart_PB_LT_O"
@export var low_air_pressure_reset_lt_tag_name: String = "MCM09_Low_Air_Pressure_Reset_PB_LT_O"
@export var power_branch_fault_reset_lt_tag_name: String = "MCM09_Power_Branch_Fault_Reset_PB_LT_O"
@export var communication_fault_reset_lt_tag_name: String = "MCM09_Communication_Fault_Reset_PB_LT_O"
@export var estop_actuated_lt_tag_name: String = "MCM09_EStop_Actuated_LT_O"

const _CLOSED_POSITION := Vector3(-0.001, 0.0, -0.003)
const _OPEN_POSITION := Vector3(-0.457, -0.002, 0.272)
const _OPEN_ROT_Y_DEG := -120.0

var _tween: Tween
var _anim_start: Transform3D
var _anim_end: Transform3D
var _pilot_aiming: bool = false
var _aimed_target_idx: int = -1  # index into `_targets`; -1 = none
var _prev_e: bool = false
## Counter used to throttle the pilot-aim distance scan to ~30 Hz. The
## E-key edge detection in `_poll_input` stays at the full physics rate
## so a press is never missed; only the aim *update* lags by up to 33 ms.
var _aim_tick: int = 0
# Each entry:
#   kind: "button" | "door"
#   pick_nodes: Array[Node3D]    — used for aim distance + prompt position
#   For button kind, additionally:
#     raw_name (node name as discovered, e.g. "S_Btn"),
#     name (display label), latching, pressed, tweens (Array[Tween]),
#     move_nodes (Array[{node, rest_pos}]),
#     glow_meshes (Array[MeshInstance3D]),
#     glow_unique (bool), glow_color (Color), glow_energy (float),
#     pb_tag (OIPCommsTag or null) — momentary input written on press,
#     estop_ch1_tag / estop_ch2_tag (OIPCommsTag or null) — dual-channel
#       safety writes for the latching E-Stop entry.
var _targets: Array[Dictionary] = []

# 21 OIPCommsTag instances — one per AOI signal. All share `tag_group_name`.
var _start_pb_tag := OIPCommsTag.new()
var _stop_pb_tag := OIPCommsTag.new()
var _motor_fault_reset_pb_tag := OIPCommsTag.new()
var _jam_restart_pb_tag := OIPCommsTag.new()
var _low_air_pressure_reset_pb_tag := OIPCommsTag.new()
var _power_branch_fault_reset_pb_tag := OIPCommsTag.new()
var _communication_fault_reset_pb_tag := OIPCommsTag.new()
var _estop_ch1_tag := OIPCommsTag.new()
var _estop_ch2_tag := OIPCommsTag.new()
var _ups_fault_tag := OIPCommsTag.new()
var _on_ups_tag := OIPCommsTag.new()
var _ups_low_tag := OIPCommsTag.new()
var _nat_switch_fault_tag := OIPCommsTag.new()
var _fire_relay_tag := OIPCommsTag.new()
var _start_lt_tag := OIPCommsTag.new()
var _motor_fault_reset_lt_tag := OIPCommsTag.new()
var _jam_restart_lt_tag := OIPCommsTag.new()
var _low_air_pressure_reset_lt_tag := OIPCommsTag.new()
var _power_branch_fault_reset_lt_tag := OIPCommsTag.new()
var _communication_fault_reset_lt_tag := OIPCommsTag.new()
var _estop_actuated_lt_tag := OIPCommsTag.new()

# ES_Btn indicator (the lamp next to the EStop_Cap mushroom). Driven by
# `_estop_actuated_lt_tag` — separate from `_targets` because it isn't pressable.
var _es_indicator_meshes: Array[MeshInstance3D] = []
var _es_indicator_unique: bool = false

## Per-status-lamp render state. Keyed by lamp node name (matches the
## `lamp` field of `_STATUS_LAMPS`). Each entry:
##   meshes: Array[MeshInstance3D]  — the glow surfaces under the lamp
##   unique: bool                   — whether materials have been duplicated
##   active: bool                   — current driven state (with inversion already applied)
##   tween:  Tween                  — running pulse tween (or null)
var _status_lamp_states: Dictionary = {}

@onready var _door_pivot: Node3D = $MCM/Door_Pivot
@onready var _interaction_prompt: Label3D = get_node_or_null("InteractionPrompt") as Label3D


func _enter_tree() -> void:
	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	EditorInterface.simulation_started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _exit_tree() -> void:
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _ready() -> void:
	_door_pivot.transform = _target_transform()
	if _interaction_prompt:
		_interaction_prompt.visible = false
		_interaction_prompt.top_level = true
	_discover_targets()
	_wire_button_tags()
	_resolve_es_indicator()
	_resolve_status_lamps()
	# Sync each lamp to its current @export bool. Catches scene-load
	# values that the setters may have applied before `_status_lamp_states`
	# was populated.
	_drive_status_lamp("ups_fault", ups_fault)
	_drive_status_lamp("on_ups", on_ups)
	_drive_status_lamp("ups_low", ups_low)
	_drive_status_lamp("nat_switch_fault", nat_switch_fault)
	_drive_status_lamp("fire_relay", fire_relay)


func _validate_property(property: Dictionary) -> void:
	# Every comms-related tag-name field is gated on the global comms toggle
	# plus the per-instance `enable_comms`. Listed once here so the inspector
	# stays clean when the user isn't wiring this MCM to a PLC.
	var tag_fields: PackedStringArray = [
		"start_pb_tag_name",
		"stop_pb_tag_name",
		"motor_fault_reset_pb_tag_name",
		"jam_restart_pb_tag_name",
		"low_air_pressure_reset_pb_tag_name",
		"power_branch_fault_reset_pb_tag_name",
		"communication_fault_reset_pb_tag_name",
		"estop_ch1_tag_name",
		"estop_ch2_tag_name",
		"ups_fault_tag_name",
		"on_ups_tag_name",
		"ups_low_tag_name",
		"nat_switch_fault_tag_name",
		"fire_relay_tag_name",
		"start_lt_tag_name",
		"motor_fault_reset_lt_tag_name",
		"jam_restart_lt_tag_name",
		"low_air_pressure_reset_lt_tag_name",
		"power_branch_fault_reset_lt_tag_name",
		"communication_fault_reset_lt_tag_name",
		"estop_actuated_lt_tag_name",
	]
	for field: String in tag_fields:
		if OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", field):
			return


## Build the list of pilot-aim targets:
##   - Every `_Btn` node in `Door_Pivot` (skipping indicators) and the
##     `EStop_Cap` mushroom — pressable controls.
##   - The `Cab_Latch` + `Cab_LatchKey` pair — the door open/close target.
func _discover_targets() -> void:
	_targets.clear()
	if not _door_pivot:
		return
	# Buttons (sorted alphabetically for stable order).
	var btn_nodes: Array[Node3D] = []
	for child in _door_pivot.get_children():
		if not child is Node3D:
			continue
		var n: Node3D = child
		if n.name in _NON_INTERACTIVE_BTN_NAMES:
			continue
		if n.name.ends_with("_Btn") or n.name == "EStop_Cap":
			btn_nodes.append(n)
	btn_nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool: return a.name < b.name)
	for node_3d: Node3D in btn_nodes:
		var raw_name: String = node_3d.name
		var label: String
		var latching: bool = false
		var move_nodes: Array[Dictionary] = [
			{"node": node_3d, "rest_pos": node_3d.position},
		]
		var glow_meshes: Array[MeshInstance3D] = _collect_glow_meshes(node_3d)
		var glow_color: Color
		var glow_energy: float = _PB_GLOW_ENERGY
		if raw_name == "EStop_Cap":
			label = "EStop"
			latching = true
			var ring: Node3D = _door_pivot.get_node_or_null("EStop_Ring") as Node3D
			if ring:
				move_nodes.append({"node": ring, "rest_pos": ring.position})
			glow_color = _ESTOP_GLOW_COLOR
			glow_energy = _ESTOP_GLOW_ENERGY
		else:
			label = raw_name.left(raw_name.length() - 4)  # strip "_Btn"
			glow_color = _detect_glow_color(glow_meshes, _PB_GLOW_FALLBACK_COLOR)
		_targets.append({
			"kind": "button",
			"pick_nodes": [node_3d] as Array[Node3D],
			"raw_name": raw_name,
			"name": label,
			"latching": latching,
			"pressed": false,
			"move_nodes": move_nodes,
			"glow_meshes": glow_meshes,
			"glow_unique": false,
			"glow_color": glow_color,
			"glow_energy": glow_energy,
			"tweens": [] as Array[Tween],
			"pb_tag": null,
			"estop_ch1_tag": null,
			"estop_ch2_tag": null,
		})
	# Door target — only fires when looking at the latch hardware.
	var latch_picks: Array[Node3D] = []
	var latch: Node3D = _door_pivot.get_node_or_null("Cab_Latch") as Node3D
	if latch:
		latch_picks.append(latch)
	var latch_key: Node3D = _door_pivot.get_node_or_null("Cab_LatchKey") as Node3D
	if latch_key:
		latch_picks.append(latch_key)
	if not latch_picks.is_empty():
		_targets.append({
			"kind": "door",
			"pick_nodes": latch_picks,
		})


## Attach the right `OIPCommsTag` instances to each button entry. Built at
## runtime because const dictionaries can't reference instance vars.
## `nc=true` flags momentary inputs wired normally-closed — the tag rests
## TRUE and drops to FALSE while pressed.
func _wire_button_tags() -> void:
	var pb_tag_by_name: Dictionary = {
		"S_Btn": _start_pb_tag,
		"STPB_Btn": _stop_pb_tag,
		"MF_Btn": _motor_fault_reset_pb_tag,
		"JR_Btn": _jam_restart_pb_tag,
		"LAP_Btn": _low_air_pressure_reset_pb_tag,
		"PBFR_Btn": _power_branch_fault_reset_pb_tag,
		"CFR_Btn": _communication_fault_reset_pb_tag,
	}
	for entry: Dictionary in _targets:
		if String(entry.get("kind", "")) != "button":
			continue
		var node_name: String = String(entry.get("raw_name", ""))
		if node_name == "EStop_Cap":
			entry["estop_ch1_tag"] = _estop_ch1_tag
			entry["estop_ch2_tag"] = _estop_ch2_tag
		elif pb_tag_by_name.has(node_name):
			entry["pb_tag"] = pb_tag_by_name[node_name]
			entry["nc"] = node_name == "STPB_Btn"


## Walk the MCM subtree, find each `_STATUS_LAMPS` entry's lamp node
## (status lamps live under `Subpanel_Pivot`, NOT `Door_Pivot`), and
## record its glow meshes. Lamps that aren't found in the GLB are
## silently skipped so missing nodes don't break the rest of the panel.
func _resolve_status_lamps() -> void:
	_status_lamp_states.clear()
	for spec: Dictionary in _STATUS_LAMPS:
		var lamp_name: String = String(spec["lamp"])
		var lamp_node: Node3D = find_child(lamp_name, true, false) as Node3D
		if lamp_node == null:
			continue
		_status_lamp_states[lamp_name] = {
			"meshes": _collect_glow_meshes(lamp_node),
			"unique": false,
			"active": false,
			"initialized": false,
		}


## Update the lamp(s) wired to `prop_name`. Each lamp shows solid GREEN
## while the property is FALSE (OK state) and solid RED while TRUE (BAD).
## Iterates `_STATUS_LAMPS` so one property can drive multiple lamps.
func _drive_status_lamp(prop_name: String, value: bool) -> void:
	if _status_lamp_states.is_empty():
		# Not yet discovered (setter fired during scene load before _ready).
		return
	for spec: Dictionary in _STATUS_LAMPS:
		if String(spec["prop"]) != prop_name:
			continue
		var lamp_name: String = String(spec["lamp"])
		if not _status_lamp_states.has(lamp_name):
			continue
		_set_status_lamp_color(lamp_name, value)


## Apply solid GREEN (signal=false, OK) or solid RED (signal=true, BAD)
## emission to a single lamp. Skips when nothing changed AND the lamp has
## already been initialised (the very first call still pushes the chosen
## color to override whatever the GLB material shipped with).
func _set_status_lamp_color(lamp_name: String, bad: bool) -> void:
	var state: Dictionary = _status_lamp_states[lamp_name]
	if bool(state["active"]) == bad and bool(state["initialized"]):
		return
	state["active"] = bad
	state["initialized"] = true
	var color: Color = _STATUS_LAMP_BAD_COLOR if bad else _STATUS_LAMP_OK_COLOR
	_apply_status_lamp_emission(state, color, _STATUS_LAMP_ENERGY)


func _apply_status_lamp_emission(state: Dictionary, color: Color, energy: float) -> void:
	var meshes: Array = state["meshes"]
	if meshes.is_empty():
		return
	if not bool(state["unique"]):
		for m: Variant in meshes:
			_make_material_unique(m as MeshInstance3D)
		state["unique"] = true
	for m: Variant in meshes:
		var mat := (m as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
		if not mat:
			continue
		# Override albedo too so the GLB's per-lamp tint (some caps ship
		# green/amber/red) doesn't bleed through and produce mismatched
		# colors across lamps when they're driven to the same state.
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = energy


func _resolve_es_indicator() -> void:
	if not _door_pivot:
		return
	var es: Node3D = _door_pivot.get_node_or_null("ES_Btn") as Node3D
	if es:
		_es_indicator_meshes = _collect_glow_meshes(es)


## Walk a button node looking for MeshInstance3Ds to glow. Most caps are
## meshes themselves; some are containers wrapping a single mesh child.
func _collect_glow_meshes(node: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child as MeshInstance3D)
	return out


## Read the first available StandardMaterial3D albedo color so each lit
## pushbutton glows in its native cap color (green Start, yellow MF, etc.).
func _detect_glow_color(meshes: Array[MeshInstance3D], fallback: Color) -> Color:
	for m: MeshInstance3D in meshes:
		if not m:
			continue
		var override: Material = m.get_surface_override_material(0)
		var mat: StandardMaterial3D = override as StandardMaterial3D
		if mat == null and m.mesh and m.mesh.get_surface_count() > 0:
			mat = m.mesh.surface_get_material(0) as StandardMaterial3D
		if mat:
			return mat.albedo_color
	return fallback


func _on_simulation_started() -> void:
	if not enable_comms:
		return
	_start_pb_tag.register(tag_group_name, start_pb_tag_name)
	_stop_pb_tag.register(tag_group_name, stop_pb_tag_name)
	_motor_fault_reset_pb_tag.register(tag_group_name, motor_fault_reset_pb_tag_name)
	_jam_restart_pb_tag.register(tag_group_name, jam_restart_pb_tag_name)
	_low_air_pressure_reset_pb_tag.register(tag_group_name, low_air_pressure_reset_pb_tag_name)
	_power_branch_fault_reset_pb_tag.register(tag_group_name, power_branch_fault_reset_pb_tag_name)
	_communication_fault_reset_pb_tag.register(tag_group_name, communication_fault_reset_pb_tag_name)
	_estop_ch1_tag.register(tag_group_name, estop_ch1_tag_name)
	_estop_ch2_tag.register(tag_group_name, estop_ch2_tag_name)
	_ups_fault_tag.register(tag_group_name, ups_fault_tag_name)
	_on_ups_tag.register(tag_group_name, on_ups_tag_name)
	_ups_low_tag.register(tag_group_name, ups_low_tag_name)
	_nat_switch_fault_tag.register(tag_group_name, nat_switch_fault_tag_name)
	_fire_relay_tag.register(tag_group_name, fire_relay_tag_name)
	_start_lt_tag.register(tag_group_name, start_lt_tag_name)
	_motor_fault_reset_lt_tag.register(tag_group_name, motor_fault_reset_lt_tag_name)
	_jam_restart_lt_tag.register(tag_group_name, jam_restart_lt_tag_name)
	_low_air_pressure_reset_lt_tag.register(tag_group_name, low_air_pressure_reset_lt_tag_name)
	_power_branch_fault_reset_lt_tag.register(tag_group_name, power_branch_fault_reset_lt_tag_name)
	_communication_fault_reset_lt_tag.register(tag_group_name, communication_fault_reset_lt_tag_name)
	_estop_actuated_lt_tag.register(tag_group_name, estop_actuated_lt_tag_name)


func _tag_group_initialized(group: String) -> void:
	# Pushbutton inputs initialize to their "not pressed" rest level —
	# FALSE for NO buttons, TRUE for NC (Stop).
	if _start_pb_tag.on_group_initialized(group):
		_start_pb_tag.write_bit(false)
	if _stop_pb_tag.on_group_initialized(group):
		_stop_pb_tag.write_bit(true)
	if _motor_fault_reset_pb_tag.on_group_initialized(group):
		_motor_fault_reset_pb_tag.write_bit(false)
	if _jam_restart_pb_tag.on_group_initialized(group):
		_jam_restart_pb_tag.write_bit(false)
	if _low_air_pressure_reset_pb_tag.on_group_initialized(group):
		_low_air_pressure_reset_pb_tag.write_bit(false)
	if _power_branch_fault_reset_pb_tag.on_group_initialized(group):
		_power_branch_fault_reset_pb_tag.write_bit(false)
	if _communication_fault_reset_pb_tag.on_group_initialized(group):
		_communication_fault_reset_pb_tag.write_bit(false)
	# E-Stop NC channels: TRUE while not engaged. Reflect current latch state
	# in case the sim was launched with the cap already pressed.
	var es_pressed: bool = _estop_pressed_now()
	if _estop_ch1_tag.on_group_initialized(group):
		_estop_ch1_tag.write_bit(not es_pressed)
	if _estop_ch2_tag.on_group_initialized(group):
		_estop_ch2_tag.write_bit(not es_pressed)
	# Status inputs sync their current @export bool to the PLC. NC inputs
	# (`ups_fault`, `fire_relay`) write the inverted value — tag stays TRUE
	# while healthy.
	if _ups_fault_tag.on_group_initialized(group):
		_ups_fault_tag.write_bit(not ups_fault)
	if _on_ups_tag.on_group_initialized(group):
		_on_ups_tag.write_bit(on_ups)
	if _ups_low_tag.on_group_initialized(group):
		_ups_low_tag.write_bit(ups_low)
	if _nat_switch_fault_tag.on_group_initialized(group):
		_nat_switch_fault_tag.write_bit(nat_switch_fault)
	if _fire_relay_tag.on_group_initialized(group):
		_fire_relay_tag.write_bit(not fire_relay)
	# Lamp tags: just latch the ready flag — values arrive each poll.
	_start_lt_tag.on_group_initialized(group)
	_motor_fault_reset_lt_tag.on_group_initialized(group)
	_jam_restart_lt_tag.on_group_initialized(group)
	_low_air_pressure_reset_lt_tag.on_group_initialized(group)
	_power_branch_fault_reset_lt_tag.on_group_initialized(group)
	_communication_fault_reset_lt_tag.on_group_initialized(group)
	_estop_actuated_lt_tag.on_group_initialized(group)


func _tag_group_polled(group: String) -> void:
	if not enable_comms:
		return
	if _start_lt_tag.matches_group(group):
		_apply_lamp_glow("S_Btn", _start_lt_tag.read_bit())
	if _motor_fault_reset_lt_tag.matches_group(group):
		_apply_lamp_glow("MF_Btn", _motor_fault_reset_lt_tag.read_bit())
	if _jam_restart_lt_tag.matches_group(group):
		_apply_lamp_glow("JR_Btn", _jam_restart_lt_tag.read_bit())
	if _low_air_pressure_reset_lt_tag.matches_group(group):
		_apply_lamp_glow("LAP_Btn", _low_air_pressure_reset_lt_tag.read_bit())
	if _power_branch_fault_reset_lt_tag.matches_group(group):
		_apply_lamp_glow("PBFR_Btn", _power_branch_fault_reset_lt_tag.read_bit())
	if _communication_fault_reset_lt_tag.matches_group(group):
		_apply_lamp_glow("CFR_Btn", _communication_fault_reset_lt_tag.read_bit())
	if _estop_actuated_lt_tag.matches_group(group):
		_set_es_indicator_glow(_estop_actuated_lt_tag.read_bit())


func _apply_lamp_glow(raw_name: String, on: bool) -> void:
	for entry: Dictionary in _targets:
		if String(entry.get("raw_name", "")) == raw_name:
			_set_button_glow(entry, on)
			return


func _estop_pressed_now() -> bool:
	for entry: Dictionary in _targets:
		if String(entry.get("raw_name", "")) == "EStop_Cap":
			return bool(entry.get("pressed", false))
	return false


func _physics_process(_delta: float) -> void:
	# Pilot-aim ray cast must run here — physics runs on a separate thread
	# (`3d/run_on_separate_thread=true` in project.godot) and the space
	# state is null from `_process`. Throttle the aim update to every 4th
	# tick (~30 Hz); E-key edge detection still runs every tick on the
	# last-known aim state so presses aren't dropped.
	if _aim_tick % 4 == 0:
		_update_pilot_aim()
	_aim_tick += 1
	if _pilot_aiming and _aimed_target_idx >= 0:
		_poll_input()


func _update_pilot_aim() -> void:
	# Direct per-target distance test — no cabinet-wide raycast gate.
	# `_find_aimed_target` already bounds picks to `PILOT_AIM_RANGE` along
	# the ray, so we don't need a separate collider-hit check (which broke
	# whenever the user aimed above the StaticBody box or at the open door).
	var camera: Camera3D = get_viewport().get_camera_3d()
	var target_idx: int = -1
	if camera:
		var origin: Vector3 = camera.global_position
		var dir: Vector3 = -camera.global_transform.basis.z
		target_idx = _find_aimed_target(origin, dir)
	var aiming: bool = target_idx >= 0
	if aiming != _pilot_aiming or target_idx != _aimed_target_idx:
		_pilot_aiming = aiming
		_aimed_target_idx = target_idx
		_prev_e = false
		_update_interaction_prompt()


## Pick the target whose closest pick node is nearest to the camera's view
## ray, within `aim_pick_radius` perpendicular distance and `PILOT_AIM_RANGE`
## along the ray. Returns -1 if no target qualifies (i.e., aiming at the
## cabinet body away from any control or the latch).
func _find_aimed_target(origin: Vector3, dir: Vector3) -> int:
	var best: int = -1
	var best_dist: float = aim_pick_radius
	for i in _targets.size():
		var t: Dictionary = _targets[i]
		var pick_nodes: Array = t["pick_nodes"]
		for pn: Variant in pick_nodes:
			var node_3d: Node3D = pn as Node3D
			if not node_3d:
				continue
			var pos: Vector3 = node_3d.global_position
			var to_pos: Vector3 = pos - origin
			var along: float = to_pos.dot(dir)
			if along < 0.0 or along > PILOT_AIM_RANGE:
				continue
			var perp: float = (origin + dir * along).distance_to(pos)
			if perp < best_dist:
				best_dist = perp
				best = i
	return best


func _update_interaction_prompt() -> void:
	if not _interaction_prompt:
		return
	if not _pilot_aiming or _aimed_target_idx < 0:
		_interaction_prompt.visible = false
		return
	var t: Dictionary = _targets[_aimed_target_idx]
	var primary: Node3D = (t["pick_nodes"] as Array)[0] as Node3D
	_interaction_prompt.global_position = primary.global_position + _LABEL_HOVER_OFFSET
	_interaction_prompt.visible = true
	if String(t["kind"]) == "door":
		_interaction_prompt.text = "[E] %s" % ("Close Door" if open else "Open Door")
	else:
		var btn_label: String = t["name"]
		if bool(t["latching"]):
			var verb: String = "Disengage" if bool(t["pressed"]) else "Engage"
			_interaction_prompt.text = "[E] %s %s" % [verb, btn_label]
		else:
			_interaction_prompt.text = "[E] Press %s" % btn_label


## Edge-triggered E acts on whatever the pilot is aimed at: the door (if
## the latch hardware is in focus) or a specific button.
func _poll_input() -> void:
	var e_now: bool = Input.is_physical_key_pressed(KEY_E)
	if e_now and not _prev_e:
		var t: Dictionary = _targets[_aimed_target_idx]
		if String(t["kind"]) == "door":
			open = not open
			_update_interaction_prompt()
		else:
			_press_button(t)
	_prev_e = e_now


func _press_button(b: Dictionary) -> void:
	_kill_button_tweens(b)
	var move_nodes: Array = b["move_nodes"]
	var new_tweens: Array[Tween] = []
	if bool(b["latching"]):
		b["pressed"] = not bool(b["pressed"])
		var pressed: bool = bool(b["pressed"])
		for mn: Dictionary in move_nodes:
			var node_3d: Node3D = mn["node"]
			var rest: Vector3 = mn["rest_pos"]
			var target: Vector3 = (rest + button_press_offset) if pressed else rest
			var t: Tween = create_tween()
			t.tween_property(node_3d, "position", target, button_press_duration)
			new_tweens.append(t)
		_set_button_glow(b, pressed)
		# E-Stop dual-channel write: NC polarity (channels go FALSE on engage).
		var ch1: OIPCommsTag = b.get("estop_ch1_tag") as OIPCommsTag
		var ch2: OIPCommsTag = b.get("estop_ch2_tag") as OIPCommsTag
		if ch1 and ch1.is_ready():
			ch1.write_bit(not pressed)
		if ch2 and ch2.is_ready():
			ch2.write_bit(not pressed)
	else:
		b["pressed"] = true
		# Drive the momentary PB_I tag to its "pressed" level for the
		# duration of the press; `_on_momentary_complete` restores the rest
		# level when the tween ends. NC buttons (Stop) invert both edges.
		var pb_tag: OIPCommsTag = b.get("pb_tag") as OIPCommsTag
		var nc: bool = bool(b.get("nc", false))
		if pb_tag and pb_tag.is_ready():
			pb_tag.write_bit(not nc)
		for i in move_nodes.size():
			var mn: Dictionary = move_nodes[i]
			var node_3d: Node3D = mn["node"]
			var rest: Vector3 = mn["rest_pos"]
			var t: Tween = create_tween()
			t.tween_property(node_3d, "position", rest + button_press_offset, button_press_duration)
			t.tween_interval(button_hold_duration)
			t.tween_property(node_3d, "position", rest, button_press_duration)
			if i == 0:
				t.tween_callback(_on_momentary_complete.bind(b))
			new_tweens.append(t)
	b["tweens"] = new_tweens
	_update_interaction_prompt()


func _kill_button_tweens(b: Dictionary) -> void:
	var prior: Array = b.get("tweens", [] as Array[Tween])
	for t: Variant in prior:
		var tween: Tween = t as Tween
		if tween and tween.is_valid():
			tween.kill()


func _on_momentary_complete(b: Dictionary) -> void:
	b["pressed"] = false
	var pb_tag: OIPCommsTag = b.get("pb_tag") as OIPCommsTag
	var nc: bool = bool(b.get("nc", false))
	if pb_tag and pb_tag.is_ready():
		pb_tag.write_bit(nc)
	if _pilot_aiming:
		_update_interaction_prompt()


## Toggle emission glow on this button's glow meshes. Materials are made
## local-to-scene on first touch so one MCM lighting up doesn't bleed onto
## every other instance. Color/energy come from the entry — EStop_Cap glows
## red, lit pushbuttons glow in the cap's own albedo color.
func _set_button_glow(b: Dictionary, on: bool) -> void:
	var meshes: Array = b.get("glow_meshes", [] as Array[MeshInstance3D])
	if meshes.is_empty():
		return
	if not bool(b.get("glow_unique", false)):
		for m: Variant in meshes:
			_make_material_unique(m as MeshInstance3D)
		b["glow_unique"] = true
	var color: Color = b.get("glow_color", _ESTOP_GLOW_COLOR)
	var energy: float = float(b.get("glow_energy", _ESTOP_GLOW_ENERGY))
	for m: Variant in meshes:
		var mat := (m as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
		if not mat:
			continue
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = energy if on else 0.0


func _set_es_indicator_glow(on: bool) -> void:
	if _es_indicator_meshes.is_empty():
		return
	if not _es_indicator_unique:
		for m: MeshInstance3D in _es_indicator_meshes:
			_make_material_unique(m)
		_es_indicator_unique = true
	for m: MeshInstance3D in _es_indicator_meshes:
		var mat := m.get_surface_override_material(0) as StandardMaterial3D
		if not mat:
			continue
		mat.emission_enabled = true
		mat.emission = _ESTOP_GLOW_COLOR
		mat.emission_energy_multiplier = _ESTOP_GLOW_ENERGY if on else 0.0


func _make_material_unique(mesh: MeshInstance3D) -> void:
	var current := mesh.get_surface_override_material(0)
	if current:
		if not current.resource_local_to_scene:
			var unique := current.duplicate() as Material
			unique.resource_local_to_scene = true
			mesh.set_surface_override_material(0, unique)
		return
	var base_mesh := mesh.mesh
	var base_mat: Material = null
	if base_mesh and base_mesh.get_surface_count() > 0:
		base_mat = base_mesh.surface_get_material(0)
	if base_mat:
		var unique := base_mat.duplicate() as Material
		unique.resource_local_to_scene = true
		mesh.set_surface_override_material(0, unique)
	else:
		var fresh := StandardMaterial3D.new()
		fresh.resource_local_to_scene = true
		mesh.set_surface_override_material(0, fresh)


func _target_transform() -> Transform3D:
	if open:
		return Transform3D(Basis(Vector3.UP, deg_to_rad(_OPEN_ROT_Y_DEG)), _OPEN_POSITION)
	return Transform3D(Basis.IDENTITY, _CLOSED_POSITION)


func _animate_to(target: Transform3D) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_anim_start = _door_pivot.transform
	_anim_end = target
	_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_method(_apply_door_step, 0.0, 1.0, open_duration)


func _apply_door_step(t: float) -> void:
	_door_pivot.transform = _anim_start.interpolate_with(_anim_end, t)
