@tool
class_name Diverter
extends Node3D

## Button to trigger a divert action in the editor.
@export_tool_button("Divert") var divert_action: Callable = divert
## Time in seconds for the diverter to complete its motion.
@export_custom(PROPERTY_HINT_NONE, "suffix:s") var divert_time: float = 0.25
## Distance the diverter arm travels during activation.
@export_custom(PROPERTY_HINT_NONE, "suffix:m") var divert_distance: float = 0.75

var size: Vector3 = Vector3(0.722, 1.2, 2.127)

## True from the moment `divert()` accepts a request until the animator's
## `divert_finished` signal fires. Used as a lockout so neither the comms
## tag nor a manual trigger can start a second cycle mid-animation.
var _diverting: bool = false
## Most recent value seen on the comms tag — used for rising-edge detection
## in `_tag_group_polled`. Primed on group init so a tag that is already
## TRUE at sim start doesn't synthesise a false→true transition.
var _last_tag_value: bool = false
var _tag := OIPCommsTag.new()
@onready var _diverter_animator: DiverterAnimator = $DiverterAnimator

@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group for reading divert commands from external systems.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value
## The tag name for the divert trigger in the selected tag group.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var tag_name: String = ""

func _validate_property(property: Dictionary) -> void:
	OIPCommsSetup.validate_tag_property(property)

func _enter_tree() -> void:
	if has_meta("is_preview"):
		return
	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	EditorInterface.simulation_started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)

func _exit_tree() -> void:
	if has_meta("is_preview"):
		return
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)

func _ready() -> void:
	if has_meta("is_preview"):
		return
	_diverter_animator.divert_finished.connect(_on_divert_finished)

func get_snap_features() -> Array:
	return [
		{
			"shape": ConveyorSnapFeatures.Shape.POINT,
			"kind": &"diverter_push_side",
			"local_pos": Vector3(0, 0, -size.z / 2.0),
			"local_outward": Vector3(0, 0, -1),
			"y_offset": ConveyorSnapFeatures.DIVERTER_Y_OFFSET,
			"outward_offset": ConveyorSnapFeatures.DIVERTER_SIDE_OFFSET,
			"end_name": &"push_side",
		},
	]


func _get_custom_preview_node() -> Node3D:
	var preview_scene := load("res://parts/Diverter.tscn") as PackedScene
	var preview_node := preview_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) as Node3D
	preview_node.set_meta("is_preview", true)
	_disable_collisions_recursive(preview_node)
	return preview_node


func _disable_collisions_recursive(node: Node) -> void:
	if node is CollisionShape3D:
		node.disabled = true
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	for child in node.get_children():
		_disable_collisions_recursive(child)

func use() -> void:
	divert()

## Start a divert cycle if one isn't already running. Manual triggers
## (editor button, pilot E key) and the comms tag all funnel through here
## so the lockout applies uniformly.
func divert() -> void:
	if _diverting:
		return
	_diverting = true
	_diverter_animator.fire(divert_time, divert_distance)

func _on_divert_finished() -> void:
	_diverting = false

func _on_simulation_started() -> void:
	if enable_comms:
		_tag.register(tag_group_name, tag_name)

func _tag_group_initialized(tag_group_name_param: String) -> void:
	if _tag.on_group_initialized(tag_group_name_param):
		# Prime the edge detector so a tag latched HIGH at startup is
		# remembered as the resting state, not treated as a fresh trigger.
		_last_tag_value = _tag.read_bit()

func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms or not _tag.matches_group(tag_group_name_param):
		return
	# Lockout: while the pusher is mid-cycle, ignore the tag entirely —
	# don't read it, don't update `_last_tag_value`. Any transitions that
	# happen during this window are dropped on purpose.
	if _diverting:
		return
	var current: bool = _tag.read_bit()
	if current and not _last_tag_value:
		divert()
	_last_tag_value = current
