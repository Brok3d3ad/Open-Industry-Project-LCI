@tool
class_name AuxDisconnect
extends Node3D

## Auxiliary disconnect switch with a single safety BOOL output. Pilot E
## (or the editor "Use" shortcut C) calls [method use], which toggles the
## handle 90° on Z. The output tag is fail-safe NC: HIGH while closed
## (handle in resting position), LOW when tripped (handle rotated).

const HANDLE_CLOSED_ANGLE: float = 0.0
const HANDLE_OPEN_ANGLE: float = PI / 2.0
const HANDLE_TWEEN_DURATION: float = 0.15
const PILOT_OK_COLOR: Color = Color(0, 1, 0, 1)
const PILOT_TRIPPED_COLOR: Color = Color(1, 0, 0, 1)

## Trip state. false = closed/normal (output HIGH), true = open/tripped
## (output LOW). Setter animates the handle and updates the output.
@export var tripped: bool = false:
	set(value):
		if tripped == value:
			return
		tripped = value
		_animate_handle()
		_update_output()

## Disconnect-closed BOOL output. Mirror of [code]not tripped[/code].
## Read-only in the inspector; written through the comms tag.
@export var aux_disconnect_closed: bool = true:
	set(value):
		if _closed_tag.is_ready() and value != aux_disconnect_closed:
			_closed_tag.write_bit(value)
		aux_disconnect_closed = value

@onready var _handle: Node3D = find_child("Aux_HandleLever", true, false) as Node3D
@onready var _pilot_lens: MeshInstance3D = find_child("Aux_PilotLens", true, false) as MeshInstance3D

var _closed_tag := OIPCommsTag.new()
var _pilot_material_made_unique: bool = false


@export_category("Communications")

## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group used by the closed-feedback output.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value

## Closed-feedback tag. [br]Datatype: [code]BOOL[/code][br]
## Fail-safe NC: HIGH while closed, LOW when tripped.
@export var aux_disconnect_closed_tag_name: String = "AUX_Disconnect_Closed"


func _validate_property(property: Dictionary) -> void:
	if property.name == "aux_disconnect_closed":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
		return
	OIPCommsSetup.validate_tag_property(property, "tag_group_name",
			"tag_groups", "aux_disconnect_closed_tag_name")


func _enter_tree() -> void:
	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	EditorInterface.simulation_started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized)


func _exit_tree() -> void:
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized)


func _ready() -> void:
	_apply_handle_position()
	_update_output()
	_update_pilot_lens()


func use() -> void:
	tripped = not tripped


func _animate_handle() -> void:
	if not _handle:
		return
	var target_z: float = HANDLE_OPEN_ANGLE if tripped else HANDLE_CLOSED_ANGLE
	var tween := create_tween()
	tween.tween_property(_handle, "rotation:z", target_z, HANDLE_TWEEN_DURATION)


func _apply_handle_position() -> void:
	if not _handle:
		return
	_handle.rotation.z = HANDLE_OPEN_ANGLE if tripped else HANDLE_CLOSED_ANGLE


func _update_output() -> void:
	aux_disconnect_closed = not tripped
	_update_pilot_lens()


func _update_pilot_lens() -> void:
	if not _pilot_lens:
		return
	_ensure_pilot_material_unique()
	var mat := _pilot_lens.get_surface_override_material(0) as StandardMaterial3D
	if not mat:
		return
	var color: Color = PILOT_TRIPPED_COLOR if tripped else PILOT_OK_COLOR
	mat.albedo_color = color
	mat.emission = color
	mat.emission_energy_multiplier = 1.0


func _ensure_pilot_material_unique() -> void:
	if _pilot_material_made_unique or not _pilot_lens:
		return
	var current_override := _pilot_lens.get_surface_override_material(0)
	if current_override:
		if not current_override.resource_local_to_scene:
			var unique_mat := current_override.duplicate() as Material
			unique_mat.resource_local_to_scene = true
			_pilot_lens.set_surface_override_material(0, unique_mat)
	else:
		var base_mat := _pilot_lens.mesh.surface_get_material(0) as StandardMaterial3D
		if base_mat:
			var unique_mat := base_mat.duplicate() as Material
			unique_mat.resource_local_to_scene = true
			_pilot_lens.set_surface_override_material(0, unique_mat)
		else:
			var fresh := StandardMaterial3D.new()
			fresh.emission_enabled = true
			fresh.resource_local_to_scene = true
			_pilot_lens.set_surface_override_material(0, fresh)
	_pilot_material_made_unique = true


func _on_simulation_started() -> void:
	if not enable_comms:
		return
	_closed_tag.register(tag_group_name, aux_disconnect_closed_tag_name)


func _tag_group_initialized(group: String) -> void:
	if _closed_tag.on_group_initialized(group):
		_closed_tag.write_bit(aux_disconnect_closed)
