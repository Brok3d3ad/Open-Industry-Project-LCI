class_name OIPCommsTag
extends RefCounted

## Process-wide counters incremented on every successful comms call.
## Read by `statistics.gd` (or any other monitor) to compute rate-per-
## second without instrumenting individual parts. Cheap (one int add per
## call); resetting is the caller's responsibility.
static var read_count: int = 0
static var write_count: int = 0

var tag_group_name: String
var tag_name: String
var _register_ok: bool = false
var _group_init: bool = false


func register(group: String, tag: String, count: int = 1) -> void:
	tag_group_name = group
	tag_name = tag
	_register_ok = OIPComms.register_tag(tag_group_name, tag_name, count)


func on_group_initialized(group: String) -> bool:
	if group == tag_group_name:
		_group_init = true
		return _register_ok
	return false


func is_ready() -> bool:
	return _register_ok and _group_init


func matches_group(group: String) -> bool:
	return group == tag_group_name


func read_bit() -> bool:
	read_count += 1
	return OIPComms.read_bit(tag_group_name, tag_name)


func write_bit(value: bool) -> void:
	write_count += 1
	OIPComms.write_bit(tag_group_name, tag_name, value)


func read_float32() -> float:
	read_count += 1
	return OIPComms.read_float32(tag_group_name, tag_name)


func write_float32(value: float) -> void:
	write_count += 1
	OIPComms.write_float32(tag_group_name, tag_name, value)


func read_int16() -> int:
	read_count += 1
	return OIPComms.read_int16(tag_group_name, tag_name)


func write_int16(value: int) -> void:
	write_count += 1
	OIPComms.write_int16(tag_group_name, tag_name, value)


func read_int32() -> int:
	read_count += 1
	return OIPComms.read_int32(tag_group_name, tag_name)


func write_int32(value: int) -> void:
	write_count += 1
	OIPComms.write_int32(tag_group_name, tag_name, value)


func read_uint8() -> int:
	read_count += 1
	return OIPComms.read_uint8(tag_group_name, tag_name)


func write_uint8(value: int) -> void:
	write_count += 1
	OIPComms.write_uint8(tag_group_name, tag_name, value)
