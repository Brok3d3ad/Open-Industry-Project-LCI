@tool
class_name EPC
extends Node3D

## Emergency Pull Cord switch. Two safety channel BOOL outputs, fail-safe NC:
## both channels are HIGH (true) in the normal state and go LOW (false) when
## tripped. Press C (the OIP "Use" shortcut) on the EPC node to toggle the
## trip state — the red mushroom cap animates in/out and the channels follow.

const BUTTON_PRESSED_Y_OFFSET: float = -0.005
const BUTTON_TWEEN_DURATION: float = 0.08

## Text shown on the Label3D mounted above the tensioner neck.
@export var label_text: String = "EPC":
	set(value):
		label_text = value
		if _label:
			_label.text = label_text

## Trip state. true = activated (mushroom in, channels LOW). false = normal.
@export var tripped: bool = false:
	set(value):
		if tripped == value:
			return
		tripped = value
		_animate_button_position()
		_update_outputs()

## Channel 1 output (BOOL). HIGH when normal, LOW when tripped (fail-safe NC).
@export var channel_1: bool = true:
	set(value):
		if _channel_1_tag.is_ready() and value != channel_1:
			_channel_1_tag.write_bit(value)
		channel_1 = value

## Channel 2 output (BOOL). HIGH when normal, LOW when tripped (fail-safe NC).
@export var channel_2: bool = true:
	set(value):
		if _channel_2_tag.is_ready() and value != channel_2:
			_channel_2_tag.write_bit(value)
		channel_2 = value

@onready var _button_cap: Node3D = $EPC/EPC_Root/ButtonCap
@onready var _label: Label3D = $EPC/EPC_Root/TensionerNeck/Label

var _button_cap_initial_y: float = 0.0
var _channel_1_tag := OIPCommsTag.new()
var _channel_2_tag := OIPCommsTag.new()

@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var tag_group_name: String
## The tag group used by both safety channels.
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value

## The tag name for Channel 1.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId.
@export var channel_1_tag_name: String = ""
## The tag name for Channel 2.[br]Datatype: [code]BOOL[/code]
@export var channel_2_tag_name: String = ""


func _validate_property(property: Dictionary) -> void:
	if property.name == "channel_1" or property.name == "channel_2":
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
		return
	if OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", "channel_1_tag_name"):
		return
	OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", "channel_2_tag_name")


func _enter_tree() -> void:
	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	EditorInterface.simulation_started.connect(_on_simulation_started)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized)


func _exit_tree() -> void:
	EditorInterface.simulation_started.disconnect(_on_simulation_started)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized)


func _ready() -> void:
	if _button_cap:
		_button_cap_initial_y = _button_cap.position.y
		_apply_button_position()
	if _label:
		_label.text = label_text
	_update_outputs()


func use() -> void:
	tripped = not tripped


func _animate_button_position() -> void:
	if not _button_cap:
		return
	var target_y := _button_cap_initial_y + BUTTON_PRESSED_Y_OFFSET if tripped else _button_cap_initial_y
	var tween := create_tween()
	tween.tween_property(_button_cap, "position:y", target_y, BUTTON_TWEEN_DURATION)


func _apply_button_position() -> void:
	if not _button_cap:
		return
	_button_cap.position.y = _button_cap_initial_y + BUTTON_PRESSED_Y_OFFSET if tripped else _button_cap_initial_y


func _update_outputs() -> void:
	var safe := not tripped
	channel_1 = safe
	channel_2 = safe


func _on_simulation_started() -> void:
	if not enable_comms:
		return
	_channel_1_tag.register(tag_group_name, channel_1_tag_name)
	_channel_2_tag.register(tag_group_name, channel_2_tag_name)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	if _channel_1_tag.on_group_initialized(tag_group_name_param):
		_channel_1_tag.write_bit(channel_1)
	if _channel_2_tag.on_group_initialized(tag_group_name_param):
		_channel_2_tag.write_bit(channel_2)
