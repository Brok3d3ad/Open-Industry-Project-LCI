@tool
class_name OIPCommsTag
extends RefCounted

## Per-tag wrapper around the OIPComms native module.
##
## OIPComms is provided by a GDExtension (addons/oip_comms/bin). If that native
## module is absent (e.g. antivirus quarantined the DLL on a fresh download), the
## `OIPComms` global identifier would be undeclared and EVERY script touching it
## would fail to parse — cascading into an editor hang. To stay robust, this file
## NEVER references `OIPComms` directly: it resolves the singleton dynamically via
## Engine.get_singleton() and no-ops when it's missing (comms simply disabled).
## Parts pass these local TYPE_* ids instead of OIPComms.TAG_TYPE_*; register()
## maps them to the native enum at runtime, only when the module is present.
##
## DEFERRED REGISTRATION: a fully-configured scene (e.g. CDW5 ≈ 1700 tags) used to
## call the native register_tag() for every tag synchronously inside the single
## Simulation.started frame — a 1-2 s editor freeze. register() now QUEUES the tag
## and a tiny @tool pump node drains a bounded number per physics frame (the same
## mechanism that ticks the conveyors), so comms comes online within ~1 s with no
## single-frame stall. Reads/writes safely no-op until a tag's registration lands
## (self-healing on the next poll / state change). If there is no SceneTree to host
## the pump, register() falls back to immediate registration so comms still works.

## Mirror the native OIPComms.TAG_TYPE_* set EXACTLY (same names/widths), so parts
## keep their familiar tag widths and _native_type maps 1:1 with no loss of precision.
enum { TYPE_BOOL, TYPE_INT16, TYPE_INT32, TYPE_UINT8, TYPE_FLOAT32, TYPE_FLOAT64 }

## Process-wide counters incremented on every successful comms call.
static var read_count: int = 0
static var write_count: int = 0

## Deferred-registration queue + the pump node that drains it a few per frame.
static var _reg_queue: Array = []
static var _pump: Node = null
## Max native register_tag() calls per physics frame. 50/frame × 60 fps drains
## ~1700 tags in well under a second while keeping every frame cheap.
const _REG_PER_FRAME: int = 50

var tag_group_name: String
var tag_name: String
var _register_ok: bool = false
var _group_init: bool = false
var _pending: bool = false
var _pending_type: int = TYPE_BOOL


## A @tool node that drains the registration queue a few tags per PHYSICS frame. It
## lives in the editor's scene tree so it ticks during the in-editor simulation, the
## same way the @tool conveyor parts run their _physics_process.
class _RegPump extends Node:
	func _physics_process(_delta: float) -> void:
		OIPCommsTag._drain_reg_queue()


## The OIPComms native singleton, or null when the module/DLL isn't loaded.
static func _comms() -> Object:
	if Engine.has_singleton(&"OIPComms"):
		return Engine.get_singleton(&"OIPComms")
	return null


## Map a local TYPE_* id to the native OIPComms.TAG_TYPE_* value (module present).
static func _native_type(c: Object, local_type: int) -> int:
	match local_type:
		TYPE_INT16:
			return c.TAG_TYPE_INT16
		TYPE_INT32:
			return c.TAG_TYPE_INT32
		TYPE_UINT8:
			return c.TAG_TYPE_UINT8
		TYPE_FLOAT32:
			return c.TAG_TYPE_FLOAT32
		TYPE_FLOAT64:
			return c.TAG_TYPE_FLOAT64
		_:
			return c.TAG_TYPE_BOOL


## Make sure the drain pump exists and is parented to the scene tree. Returns false
## only when there is no SceneTree to host it (then register() goes synchronous).
static func _ensure_pump() -> bool:
	if _pump != null and is_instance_valid(_pump):
		return true
	var ml: MainLoop = Engine.get_main_loop()
	if not (ml is SceneTree):
		return false
	var tree: SceneTree = ml as SceneTree
	# Parent the pump INSIDE the simulated scene (where the @tool conveyors/sensors live and
	# tick), not the bare tree root — a node under the edited scene is guaranteed the same
	# _physics_process ticks the parts get during the in-editor sim. Falls back if needed.
	var host: Node = tree.edited_scene_root
	if host == null:
		host = tree.current_scene
	if host == null:
		host = tree.root
	if host == null:
		return false
	_pump = _RegPump.new()
	host.call_deferred("add_child", _pump)
	return true


## Drains up to _REG_PER_FRAME queued registrations; frees the pump when empty.
static func _drain_reg_queue() -> void:
	if _reg_queue.is_empty():
		if _pump != null and is_instance_valid(_pump):
			_pump.queue_free()
		_pump = null
		return
	var c: Object = _comms()
	if c == null:
		_reg_queue.clear()
		return
	var count: int = mini(_reg_queue.size(), _REG_PER_FRAME)
	for _i: int in count:
		var t: OIPCommsTag = _reg_queue.pop_front() as OIPCommsTag
		if t != null:
			t._do_native_register(c)


func register(group: String, tag: String, data_type: int = TYPE_BOOL) -> void:
	tag_group_name = group
	tag_name = tag
	_register_ok = false
	_group_init = false
	_pending = false
	_pending_type = data_type
	if tag.strip_edges().is_empty():
		return                                   # unconfigured tag — nothing to register
	var c: Object = _comms()
	if c == null:
		return
	if _ensure_pump():
		_pending = true                          # the pump will register it over the next frames
		_reg_queue.append(self)
	else:
		_do_native_register(c)                   # no SceneTree to host the pump — go synchronous


## The actual native register_tag call — invoked by the pump (or inline as a fallback).
func _do_native_register(c: Object) -> void:
	if not _pending and _register_ok:
		return
	_pending = false
	_register_ok = c.register_tag(tag_group_name, tag_name, _native_type(c, _pending_type))


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
	var c: Object = _comms()
	if c == null or not _register_ok:
		return false
	return c.read_bit(tag_group_name, tag_name)


func write_bit(value: bool) -> void:
	write_count += 1
	var c: Object = _comms()
	if c != null and _register_ok:
		c.write_bit(tag_group_name, tag_name, value)


func read_float32() -> float:
	read_count += 1
	var c: Object = _comms()
	if c == null or not _register_ok:
		return 0.0
	return c.read_float32(tag_group_name, tag_name)


func write_float32(value: float) -> void:
	write_count += 1
	var c: Object = _comms()
	if c != null and _register_ok:
		c.write_float32(tag_group_name, tag_name, value)


func read_float64() -> float:
	var c: Object = _comms()
	if c == null or not _register_ok:
		return 0.0
	return c.read_float64(tag_group_name, tag_name)


func write_float64(value: float) -> void:
	var c: Object = _comms()
	if c != null and _register_ok:
		c.write_float64(tag_group_name, tag_name, value)


func read_int16() -> int:
	read_count += 1
	var c: Object = _comms()
	if c == null or not _register_ok:
		return 0
	return c.read_int16(tag_group_name, tag_name)


func write_int16(value: int) -> void:
	write_count += 1
	var c: Object = _comms()
	if c != null and _register_ok:
		c.write_int16(tag_group_name, tag_name, value)


func read_int32() -> int:
	read_count += 1
	var c: Object = _comms()
	if c == null or not _register_ok:
		return 0
	return c.read_int32(tag_group_name, tag_name)


func write_int32(value: int) -> void:
	write_count += 1
	var c: Object = _comms()
	if c != null and _register_ok:
		c.write_int32(tag_group_name, tag_name, value)


func read_uint8() -> int:
	read_count += 1
	var c: Object = _comms()
	if c == null or not _register_ok:
		return 0
	return c.read_uint8(tag_group_name, tag_name)


func write_uint8(value: int) -> void:
	write_count += 1
	var c: Object = _comms()
	if c != null and _register_ok:
		c.write_uint8(tag_group_name, tag_name, value)
