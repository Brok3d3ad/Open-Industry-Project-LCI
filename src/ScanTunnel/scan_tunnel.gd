@tool
class_name ScanTunnel
extends Node3D

## Scan / inspection tunnel that straddles a conveyor and reads parcels' 1D barcodes as they
## pass. It is also a placement fixture: select a conveyor and press [b]Assign Selected
## Conveyor[/b] — the tunnel is assigned to it and snapped over the belt in one step.
##
## Scanning (simulation only): a tight read volume sits at the tunnel centre. The red scan
## beams light up only while a parcel is directly beneath the scanner; the tunnel measures the
## box and reads its id, dropping the result into the read-only [b]Last Scan[/b] fields (and
## the [signal barcode_scanned] signal). It reads 5 faces; a code on the face resting on the
## belt (pointing down) can't be seen, so it NO-READs — like a real multi-camera tunnel.

## Emitted once per parcel as it passes: the decoded id, or a [code]?[/code] run (same length
## as a real id) when the code is unreadable (damaged label, or facing the belt).
signal barcode_scanned(code: String)

## Class names treated as conveyors when picking one from the selection. Anything exposing
## [code]snap_surface_y[/code] is also accepted, so curved / spur / sorter variants work.
const _CONVEYOR_TYPES: Array[StringName] = [
	&"BeltConveyor", &"RollerConveyor",
	&"BeltSpurConveyor", &"RollerSpurConveyor",
	&"CurvedBeltConveyor", &"CurvedRollerConveyor",
	&"TurntableConveyor", &"VR",
]

const _DOWN_DOT: float = -0.5                    # face normal.y below this = unreadable (belt side)
# Read volume (world metres). The length is kept TIGHT so the beams light only while a parcel
# is directly under the scanner — not as it approaches, not after it has left.
const _GATE_LENGTH: float = 0.35                 # along the belt (the read line)
const _GATE_WIDTH: float = 2.0                   # across the belt
const _GATE_HEIGHT: float = 3.0                  # up from the feet
# The belt surface sits at this MODEL-LOCAL height inside the tunnel, so parcels ride through
# the scan zone. Times the part's scale, it sets how far the origin drops below the belt — so
# the snap lands right however high the conveyor is mounted.
const _BELT_LOCAL_Y: float = 1.0915

## The conveyor this tunnel sits over. Set it with [b]Assign Selected Conveyor[/b] or drag a
## conveyor node here.
@export var conveyor: Node3D:
	set(value):
		conveyor = value
		update_configuration_warnings()
		# Snap onto it the moment it's assigned — but not while the scene is still loading.
		if value != null and Engine.is_editor_hint() and _ready_done:
			call_deferred("_snap_to_conveyor")

# Internal: nudge along the belt from the conveyor's mid-length (not shown in the inspector).
var along_offset: float = 0.0

## Assign the selected conveyor AND snap the tunnel over it, in one step.
@export_tool_button("Assign Selected Conveyor")
var assign_action: Callable = _assign_and_snap

@export_group("Scanner")
## Chance the read-head glitches on a parcel and reports an EMPTY string even though a barcode
## was present (a scanner malfunction, distinct from a no-read). 0 = never.
@export_range(0.0, 1.0, 0.01) var malfunction_rate: float = 0.01
## Minimum clear gap required between consecutive parcels (default 0.508 m ≈ 20 in). Parcels
## arriving closer than this can't be separated, so the scanner reports an EMPTY string.
@export_range(0.0, 2.0, 0.001, "suffix:m") var minimal_gap: float = 0.508

@export_group("Last Scan")
## Last decoded id (output — updates as parcels pass; reselect the node to refresh).
@export var scanned_code: String = ""
## Measured LENGTH of the last parcel, along the belt (output, metres).
@export var scanned_length: float = 0.0
## Measured WIDTH of the last parcel, across the belt (output, metres).
@export var scanned_width: float = 0.0
## Measured HEIGHT of the last parcel (output, metres).
@export var scanned_height: float = 0.0

var _gate: Area3D = null
var _beams: Array[MeshInstance3D] = []
var _seen: Dictionary = {}            # parcels currently inside the read zone (by instance id)
var _ready_done: bool = false         # true after _ready, so load-time conveyor sets don't snap
var _prev_body: Node3D = null         # last parcel scanned, for the minimal-gap check
var _prev_half: float = 0.0           # its half-extent along the belt


func _ready() -> void:
	_ready_done = true
	if Simulation.is_running():
		_build_runtime()


func _enter_tree() -> void:
	if not Simulation.started.is_connected(_on_sim_started):
		Simulation.started.connect(_on_sim_started)
	if not Simulation.stopped.is_connected(_on_sim_stopped):
		Simulation.stopped.connect(_on_sim_stopped)
	length_tag_group_name = OIPCommsSetup.default_tag_group(length_tag_group_name)
	width_tag_group_name = OIPCommsSetup.default_tag_group(width_tag_group_name)
	height_tag_group_name = OIPCommsSetup.default_tag_group(height_tag_group_name)
	barcode_tag_group_name = OIPCommsSetup.default_tag_group(barcode_tag_group_name)
	fault_tag_group_name = OIPCommsSetup.default_tag_group(fault_tag_group_name)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized)


func _exit_tree() -> void:
	if Simulation.started.is_connected(_on_sim_started):
		Simulation.started.disconnect(_on_sim_started)
	if Simulation.stopped.is_connected(_on_sim_stopped):
		Simulation.stopped.disconnect(_on_sim_stopped)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized)
	_teardown_runtime()


func _get_configuration_warnings() -> PackedStringArray:
	if conveyor == null:
		return PackedStringArray([
			"No conveyor assigned — select a conveyor and press 'Assign Selected Conveyor'."])
	return PackedStringArray()


# ---------- placement (assign + snap in one button) ----------
func _assign_and_snap() -> void:
	if not Engine.is_editor_hint():
		return
	# Prefer a conveyor in the selection; otherwise snap onto the one already in the field.
	var picked: Node3D = _pick_conveyor_from_selection()
	if picked != null:
		conveyor = picked
	if conveyor == null or not is_instance_valid(conveyor):
		_toast("Select a conveyor, or drag one into the Conveyor field, then press Assign.",
			EditorToaster.SEVERITY_WARNING)
		return
	_snap_to_conveyor()
	_toast("Snapped onto %s" % conveyor.name)


## Move the tunnel onto the assigned conveyor (centre over the belt, aligned, feet on floor).
func _snap_to_conveyor() -> void:
	if not is_inside_tree():
		return
	if conveyor == null or not is_instance_valid(conveyor):
		return
	global_transform = _compute_snap_transform(conveyor)


func _pick_conveyor_from_selection() -> Node3D:
	var nodes: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for n: Node in nodes:
		if n != self and n is Node3D and _looks_like_conveyor(n):
			return n as Node3D
	var active: Node3D = EditorInterface.get_active_node_3d()
	if active != null and active != self and _looks_like_conveyor(active):
		return active
	for n: Node in nodes:
		if n != self and n is Node3D:
			return n as Node3D
	return null


func _looks_like_conveyor(node: Node) -> bool:
	if node == null:
		return false
	if node.has_method(&"snap_surface_y"):
		return true
	var s: Script = node.get_script() as Script
	var gname: StringName = s.get_global_name() if s != null else &""
	return gname in _CONVEYOR_TYPES


## Centre over the belt at the conveyor's mid-length, yaw-aligned to its travel direction,
## upright, dropped so the belt passes through the scan zone. Preserves the part's scale.
func _compute_snap_transform(target_conveyor: Node3D) -> Transform3D:
	var cxform: Transform3D = target_conveyor.global_transform
	# Conveyor convention: origin at the belt start, +X = travel, +Z = across the belt.
	var length: float = 0.0
	var sz: Variant = target_conveyor.get("size")
	if sz is Vector3:
		length = (sz as Vector3).x
	var along: float = length * 0.5 + along_offset
	var center_world: Vector3 = cxform * Vector3(along, 0.0, 0.0)

	var fwd: Vector3 = cxform.basis.x
	fwd.y = 0.0
	if fwd.length() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var up: Vector3 = Vector3.UP
	var across: Vector3 = fwd.cross(up).normalized()   # local +Z (across the belt)
	# Preserve scale — a bare orthonormal basis would strip the 2x model scale and halve height.
	var current_scale: Vector3 = global_transform.basis.get_scale()
	var aligned_basis: Basis = Basis(fwd, up, across) * Basis.from_scale(current_scale)

	# Drop the origin below the belt so the belt lands in the scan zone (any mount height).
	var snapped_origin: Vector3 = Vector3(
		center_world.x,
		center_world.y - _BELT_LOCAL_Y * current_scale.y,
		center_world.z)
	return Transform3D(aligned_basis, snapped_origin)


# ---------- scanning runtime (simulation only) ----------
func _on_sim_started() -> void:
	_build_runtime()
	if enable_comms:
		_length_tag.register(length_tag_group_name, length_tag_name, OIPCommsTag.TYPE_FLOAT32)
		_width_tag.register(width_tag_group_name, width_tag_name, OIPCommsTag.TYPE_FLOAT32)
		_height_tag.register(height_tag_group_name, height_tag_name, OIPCommsTag.TYPE_FLOAT32)
		_barcode_tag.register(barcode_tag_group_name, barcode_tag_name, OIPCommsTag.TYPE_INT32)
		_fault_tag.register(fault_tag_group_name, fault_tag_name, OIPCommsTag.TYPE_BOOL)


func _on_sim_stopped() -> void:
	_teardown_runtime()


func _physics_process(delta: float) -> void:
	if not Simulation.is_running():
		return
	if _fault_hold > 0.0:
		_fault_hold -= delta
		if _fault_hold <= 0.0:
			_write_bit(_fault_tag, false)    # connection fault auto-clears after the trip


func _build_runtime() -> void:
	if _gate != null and is_instance_valid(_gate):
		return
	_collect_beams()
	_apply_beam_proximity_fade()      # beams land on the box surface instead of clipping through
	_set_beams(false)                 # red cones dark until a parcel is beneath the scanner
	_reset_results()
	# top_level Area3D: world-space, unscaled — dodges the part's 2x scale distorting the
	# collision shape (the reason a child-scaled gate fails to register parcels).
	var yaw: Basis = Basis(
		global_transform.basis.x.normalized(),
		global_transform.basis.y.normalized(),
		global_transform.basis.z.normalized())
	_gate = Area3D.new()
	_gate.name = "ScanGate"
	_gate.top_level = true
	_gate.collision_mask = (1 << 1) | (1 << 3)   # physics layers 2 (Dynamic) + 4 (Box)
	_gate.monitoring = true
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(_GATE_LENGTH, _GATE_HEIGHT, _GATE_WIDTH)
	cs.shape = bs
	cs.position = Vector3(0.0, _GATE_HEIGHT * 0.5, 0.0)   # span from the feet upward
	_gate.add_child(cs)
	add_child(_gate)
	_gate.global_transform = Transform3D(yaw, global_transform.origin)
	_gate.body_entered.connect(_on_body_entered)
	_gate.body_exited.connect(_on_body_exited)


func _teardown_runtime() -> void:
	if _gate != null and is_instance_valid(_gate):
		_gate.queue_free()
	_gate = null
	_seen.clear()
	for m: MeshInstance3D in _beams:
		if is_instance_valid(m):
			m.set_surface_override_material(0, null)   # drop the proximity-fade override
	_set_beams(true)                  # restore the cones for editing


func _on_body_entered(body: Node3D) -> void:
	# Only parcels (RigidBody3D); the belt / structure StaticBodies can overlap the gate too.
	if not (body is RigidBody3D):
		return
	var id: int = body.get_instance_id()
	if _seen.has(id):
		return
	_seen[id] = true

	var dims: Vector3 = _measure_box(body)
	scanned_length = dims.x
	scanned_height = dims.y
	scanned_width = dims.z

	var gap_ok: bool = _check_gap(body)
	var malfunction: bool = randf() < malfunction_rate
	if gap_ok and not malfunction:
		_set_beams(true)              # beams light only when the scanner actually reads
	scanned_code = _read_code(body, gap_ok, malfunction)
	barcode_scanned.emit(scanned_code)
	if enable_comms:
		_write_float(_length_tag, scanned_length)
		_write_float(_width_tag, scanned_width)
		_write_float(_height_tag, scanned_height)
		_write_int(_barcode_tag, scanned_code.hash())   # 32-bit hash (tags carry no strings)
	notify_property_list_changed()    # nudge the inspector's Last Scan fields


func _on_body_exited(body: Node3D) -> void:
	if not (body is RigidBody3D):
		return
	_seen.erase(body.get_instance_id())
	if _seen.is_empty():
		_set_beams(false)             # last parcel left the read zone -> beams off


## Box dimensions: the spawner-stored size if present, else the first BoxShape3D under the
## body (scaled). Returns (length=x, height=y, width=z).
func _measure_box(body: Node3D) -> Vector3:
	if body.has_meta("box_size"):
		return body.get_meta("box_size")
	for c: Node in body.find_children("*", "CollisionShape3D", true, false):
		var shape: Shape3D = (c as CollisionShape3D).shape
		if shape is BoxShape3D:
			return (shape as BoxShape3D).size * body.global_transform.basis.get_scale()
	return Vector3.ZERO


## Decides the host string for a parcel:
## [br]• empty [code]""[/code]  — scanner malfunction (random read-head glitch),
## [br]• [code]?[/code] run     — no-read (no barcode, or all present labels unreadable/face-down),
## [br]• [code]9[/code] run     — multi-read (2+ barcodes visible at once),
## [br]• the id           — a single visible barcode.
## The tunnel reads 5 faces; a code on the face pointing down at the belt isn't visible.
func _read_code(body: Node3D, gap_ok: bool, malfunction: bool) -> String:
	if not gap_ok or malfunction:
		return ""                                    # too close, or read-head glitch -> empty
	var barcodes: Array = body.get_meta("barcodes", [])
	var codes: Dictionary = {}                       # set of DISTINCT visible codes
	for entry: Dictionary in barcodes:
		var code: String = String(entry.get("code", ""))
		var normal: Vector3 = entry.get("normal", Vector3.UP)
		if code != "" and _normal_readable(body, normal):
			codes[code] = true
	if codes.size() >= 2:
		return BarcodeLabel.multi_read_code()        # '9' run — 2+ DIFFERENT codes visible
	if codes.size() == 1:
		return String(codes.keys()[0])
	return BarcodeLabel.no_read_code()               # '?' run — unreadable or no barcode


## A face is visible to the tunnel unless its world normal points down at the belt.
func _normal_readable(body: Node3D, local_n: Vector3) -> bool:
	var world_n: Vector3 = (body.global_transform.basis.orthonormalized() * local_n).normalized()
	return world_n.y > _DOWN_DOT


## Clear belt-travel gap to the previously-scanned parcel. Returns false (and records this
## parcel as the new reference) when the gap between them is below [member minimal_gap].
func _check_gap(body: Node3D) -> bool:
	var travel: Vector3 = global_transform.basis.x
	travel.y = 0.0
	travel = travel.normalized() if travel.length() > 0.001 else Vector3.FORWARD
	var half_b: float = _extent_along(body, travel)
	var ok: bool = true
	if _prev_body != null and is_instance_valid(_prev_body):
		var center_gap: float = absf(
			_prev_body.global_position.dot(travel) - body.global_position.dot(travel))
		if center_gap - _prev_half - half_b < minimal_gap:
			ok = false
	_prev_body = body
	_prev_half = half_b
	return ok


## Half the parcel's extent projected onto [param axis] (an oriented-bounding-box half-width).
func _extent_along(body: Node3D, axis: Vector3) -> float:
	var size: Vector3 = _measure_box(body)
	var b: Basis = body.global_transform.basis.orthonormalized()
	return 0.5 * (absf(size.x * b.x.dot(axis)) + absf(size.y * b.y.dot(axis)) + absf(size.z * b.z.dot(axis)))


# ---------- beams ----------
# Only the red scan cones (camTop_..._beam, camS_*_beam, camEnd_*_beam) light up. The frame's
# structural cross-beams are named "xbeam_..." — they end on a coordinate, not "_beam", so
# matching the "_beam" suffix keeps them fixed/visible instead of toggling them with the cones.
func _collect_beams() -> void:
	_beams.clear()
	for n: Node in find_children("*", "MeshInstance3D", true, false):
		if String(n.name).to_lower().ends_with("_beam"):
			_beams.append(n as MeshInstance3D)


func _set_beams(on: bool) -> void:
	for m: MeshInstance3D in _beams:
		if is_instance_valid(m):
			m.visible = on


## Give each red beam a proximity-fade copy of its material so the transparent cone fades out
## where it meets a surface — it lands on the top of a passing box (and on the belt) instead of
## clipping straight through, and the fade tracks the box as it moves underneath.
func _apply_beam_proximity_fade() -> void:
	for m: MeshInstance3D in _beams:
		if not is_instance_valid(m):
			continue
		var base: Material = m.get_active_material(0)
		if base is StandardMaterial3D:
			var mat: StandardMaterial3D = (base as StandardMaterial3D).duplicate()
			mat.proximity_fade_enabled = true
			mat.proximity_fade_distance = 0.15
			m.set_surface_override_material(0, mat)


func _reset_results() -> void:
	scanned_code = ""
	scanned_length = 0.0
	scanned_width = 0.0
	scanned_height = 0.0
	_prev_body = null
	_prev_half = 0.0


func _toast(message: String, severity: int = EditorToaster.SEVERITY_INFO) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_toaster().push_toast(message, severity)


#region Communications
@export_category("Communications")
## Write scan results to a PLC / OPC UA server (needs comms enabled in the Comms dock).
@export var enable_comms: bool = false
@export var length_tag_group_name: String
## Tag group for the measured length.
@export_custom(0, "tag_group_enum") var length_tag_groups: String:
	set(value):
		length_tag_group_name = value
		length_tag_groups = value
## Data tag (WRITE): last parcel length, metres.[br]Datatype: [code]FLOAT32[/code]
@export var length_tag_name: String = ""
@export var width_tag_group_name: String
## Tag group for the measured width.
@export_custom(0, "tag_group_enum") var width_tag_groups: String:
	set(value):
		width_tag_group_name = value
		width_tag_groups = value
## Data tag (WRITE): last parcel width, metres.[br]Datatype: [code]FLOAT32[/code]
@export var width_tag_name: String = ""
@export var height_tag_group_name: String
## Tag group for the measured height.
@export_custom(0, "tag_group_enum") var height_tag_groups: String:
	set(value):
		height_tag_group_name = value
		height_tag_groups = value
## Data tag (WRITE): last parcel height, metres.[br]Datatype: [code]FLOAT32[/code]
@export var height_tag_name: String = ""
@export var barcode_tag_group_name: String
## Tag group for the decoded id.
@export_custom(0, "tag_group_enum") var barcode_tag_groups: String:
	set(value):
		barcode_tag_group_name = value
		barcode_tag_groups = value
## Data tag (WRITE): 32-bit hash of the decoded id (these tags can't carry strings).[br]Datatype: [code]INT32[/code]
@export var barcode_tag_name: String = ""
@export var fault_tag_group_name: String
## Tag group for the connection-fault status.
@export_custom(0, "tag_group_enum") var fault_tag_groups: String:
	set(value):
		fault_tag_group_name = value
		fault_tag_groups = value
## Status tag (WRITE): TRUE while a connection fault is tripped.[br]Datatype: [code]BOOL[/code]
@export var fault_tag_name: String = ""

## Trip a connection fault on demand — holds the fault tag TRUE for 5 s, then auto-clears.
@export_tool_button("Trip Connection Fault (5 s)")
var trip_action: Callable = _trip_fault

const _FAULT_TIME: float = 5.0
var _length_tag: OIPCommsTag = OIPCommsTag.new()
var _width_tag: OIPCommsTag = OIPCommsTag.new()
var _height_tag: OIPCommsTag = OIPCommsTag.new()
var _barcode_tag: OIPCommsTag = OIPCommsTag.new()
var _fault_tag: OIPCommsTag = OIPCommsTag.new()
var _fault_hold: float = 0.0


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "length_tag_group_name", "length_tag_groups", "length_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "width_tag_group_name", "width_tag_groups", "width_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "height_tag_group_name", "height_tag_groups", "height_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "barcode_tag_group_name", "barcode_tag_groups", "barcode_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "fault_tag_group_name", "fault_tag_groups", "fault_tag_name"):
		return


func _tag_group_initialized(group: String) -> void:
	_length_tag.on_group_initialized(group)
	_width_tag.on_group_initialized(group)
	_height_tag.on_group_initialized(group)
	_barcode_tag.on_group_initialized(group)
	_fault_tag.on_group_initialized(group)


## Trip a connection fault: hold the fault tag TRUE for 5 s (auto-clears in _physics_process).
func _trip_fault() -> void:
	if not Simulation.is_running():
		_toast("Start the simulation first to trip a fault.", EditorToaster.SEVERITY_WARNING)
		return
	_fault_hold = _FAULT_TIME
	_write_bit(_fault_tag, true)
	_toast("Connection fault tripped for %.0f s." % _FAULT_TIME)


func _write_float(tag: OIPCommsTag, value: float) -> void:
	if enable_comms and tag.is_ready():
		tag.write_float32(value)


func _write_int(tag: OIPCommsTag, value: int) -> void:
	if enable_comms and tag.is_ready():
		tag.write_int32(value)


func _write_bit(tag: OIPCommsTag, value: bool) -> void:
	if enable_comms and tag.is_ready():
		tag.write_bit(value)
#endregion
