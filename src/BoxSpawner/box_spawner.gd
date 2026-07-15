@tool
class_name BoxSpawner
extends ResizableNode3D

## The box scene to spawn (must be a Box-derived PackedScene).
@export var scene: PackedScene
## When enabled, stops spawning new boxes.
@export var disable: bool = false:
	set(value):
		if value == disable:
			return
		disable = value
		if is_inside_tree():
			_change_texture()
			if not disable:
				_reset_spawn_cycle()

@export_group("Box")
## The color applied to spawned boxes.
@export var box_color: Color = Color.WHITE:
	set(value):
		box_color = value
## Mass applied to spawned boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var mass: float = 10.0
## Initial velocity applied to spawned boxes.
@export var initial_linear_velocity: Vector3 = Vector3.ZERO

@export_group("Box Size")
@export_subgroup("Conveyable")
## Enable random sizing for conveyable boxes within the min/max range below.
@export var random_size: bool = true
## Minimum conveyable box size — X=length, Y=height, Z=width (metres).
@export var random_size_min: Vector3 = Vector3(0.152, 0.005, 0.101)
## Maximum conveyable box size — X=length, Y=height, Z=width (metres).
@export var random_size_max: Vector3 = Vector3(1.2, 0.61, 0.76)

@export_subgroup("Non-Conveyable", "non_conveyable_")
## Probability that a spawned box is oversized / non-conveyable (uses the range below).
@export_range(0.0, 1.0, 0.01) var non_conveyable_spawn_chance: float = 0.13
## Minimum non-conveyable box size — X=length, Y=height, Z=width (metres).
@export var non_conveyable_random_size_min: Vector3 = Vector3(1.201, 0.611, 0.761)
## Maximum non-conveyable box size — X=length, Y=height, Z=width (metres).
@export var non_conveyable_random_size_max: Vector3 = Vector3(2.54, 1.067, 1.067)

@export_group("Box Mass")
@export_subgroup("Conveyable")
## Enable random mass for conveyable boxes within the min/max range below.
@export var random_mass: bool = true
## Minimum conveyable box mass, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var random_mass_min: float = 0.02
## Maximum conveyable box mass, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var random_mass_max: float = 22.6

@export_subgroup("Non-Conveyable", "non_conveyable_")
## Minimum non-conveyable box mass, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var non_conveyable_random_mass_min: float = 22.7
## Maximum non-conveyable box mass, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var non_conveyable_random_mass_max: float = 45.0

@export_group("Spawn Rate")
## Number of boxes spawned per minute (0-1000).
@export var boxes_per_minute: int = 45:
	set(value):
		value = clamp(value, 0, 1000)
		boxes_per_minute = value

## When true, boxes spawn at a fixed rate. When false, spawn times vary randomly.
@export var fixed_rate: bool = false
## Required conveyor reference — spawning pauses when its speed is zero. Must be assigned;
## leaving it empty warns in the editor and logs an error when the simulation starts.
@export var conveyor: Node3D = null:
	set(value):
		conveyor = value
		if not value:
			_conveyor_stopped = false
		update_configuration_warnings()

@export_group("Sorter Mode", "sorter_")
## PLC-handshake induction. Replaces the timer: the spawner raises the request-unload
## tag, and spawns a box only when the PLC answers on the ok-unload tag within
## [member sorter_ok_timeout] seconds. Needs comms enabled and both tags set.
@export var sorter_mode: bool = false:
	set(value):
		if value == sorter_mode:
			return
		sorter_mode = value
		update_configuration_warnings()
## Seconds to wait for ok-to-unload after raising the request (on timeout the request
## drops and a fresh handshake starts). Doubles as the time to discharge: after the
## grant, the box spawns once this many seconds have passed.
@export_range(0.1, 60.0, 0.1, "or_greater", "suffix:s") var sorter_ok_timeout: float = 5.0
## Maximum granted boxes awaiting discharge at once. Grants queue the box and the next
## request goes out immediately; requests pause while the queue is full.
@export_range(1, 10) var sorter_max_pending: int = 10
## Print a timestamped Output line for every sorter handshake event — each tag write,
## every ok-to-unload change received from the PLC, grants, timeouts and discharges —
## to tell apart PLC-side and spawner-side misbehaviour.
@export var sorter_debug: bool = false

@export_group("Barcode Label")
## Print a random 1D barcode (e.g. [code]SPx3Dvkhcv_001_v[/code]) on a RANDOM face of every
## spawned box. The ScanTunnel reports the id as the parcel passes — unless the labelled face
## is the one resting on the belt (the tunnel reads 5 sides, not the bottom). Clears on stop.
@export var barcode_labels: bool = true
## Fraction of individual LABELS that are DAMAGED / unreadable (torn, smudged). A damaged label
## carries no code; if both of a parcel's labels are damaged it NO-READs. Default 1%.
@export_range(0.0, 0.2, 0.005) var damaged_label_rate: float = 0.01
## Every parcel carries two labels; this is the fraction where the two hold DIFFERENT codes
## instead of the same one. Seeing both, the tunnel can't tell which is real — a multi-read
## (reports '9's). Default 1%.
@export_range(0.0, 1.0, 0.01) var multi_barcode_chance: float = 0.01
## Fraction of parcels that get NO label at all. The tunnel finds nothing to read and NO-READs
## them (reports '?'s). Default 1%.
@export_range(0.0, 1.0, 0.01) var no_barcode_chance: float = 0.01

@export_category("Communications")
## Enable communication with external PLC/control systems (used by sorter mode).
@export var enable_comms: bool = false
@export var tag_group_name: String
@export_custom(0, "tag_group_enum") var tag_groups: String:
	set(value):
		tag_group_name = value
		tag_groups = value
## Tag the spawner [b]writes[/b]: goes high to request unloading (spawning) a box; drops after the box spawns, on timeout, or when the simulation stops.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var request_unload_tag_name: String = ""
## Tag the PLC [b]writes[/b]: set high while a request is pending to grant it — the box spawns and the request drops. Lower it again to arm the next handshake.[br]Datatype: [code]BOOL[/code][br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]co0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var ok_unload_tag_name: String = ""
## Tag the spawner [b]writes[/b]: length (X size) of the next box in whole millimeters, published together with the unload request. Optional — leave empty to skip.[br]Datatype: [code]INT[/code] (16-bit integer)[br][br]Format varies by protocol:[br][b]EIP:[/b] CIP tag names[br][b]Modbus:[/b] prefix+number (e.g. [code]hr0[/code])[br][b]OPC UA:[/b] full NodeId (e.g. [code]ns=2;s=MyVariable[/code] or [code]ns=2;i=12345[/code]).
@export var box_length_tag_name: String = ""

# Sorter-mode handshake: raise request + publish next box length -> wait for ok
# (timeout restarts, same box re-offered) -> on grant, queue the box for discharge
# (it spawns after the ok-timeout period) and immediately hand-shake the next box.
enum SorterState { REQUEST_PENDING, WAITING_OK, WAIT_OK_LOW }

## Minimum time the request line is held low between handshakes. Without it the
## drop + re-raise can land between two comms polls, so the PLC never sees the
## falling edge and one long grant releases box after box.
const _REQUEST_LOW_HOLD: float = 0.1

var _scan_interval: float = 0.0
var _conveyor_stopped: bool = false
var _next_spawn_time: float = 0.0
var _spawn_counter: int = 0
var _first_spawn_done: bool = false
var _barcode_seq: int = 0
var _pending_spawn_size: Vector3 = Vector3.ZERO
var _has_pending_spawn_size: bool = false
var _pending_non_conveyable: bool = false
var _nc_bag: Array[bool] = []
var _nc_bag_bpm: int = 0
var _nc_bag_chance: float = -1.0
var _request_tag := OIPCommsTag.new()
var _ok_tag := OIPCommsTag.new()
var _length_tag := OIPCommsTag.new()
var _sorter_state: SorterState = SorterState.REQUEST_PENDING
var _sorter_wait: float = 0.0
var _ok_high: bool = false
# Remaining low-hold time before the request line may go high again.
var _request_cooldown: float = 0.0
# The box currently offered on the request/length tags (kept across timeouts).
var _offer_size: Vector3 = Vector3.ZERO
var _offer_non_conveyable: bool = false
var _offer_valid: bool = false
# Granted boxes waiting out their discharge period: {size, non_conveyable, age}.
var _discharge_queue: Array[Dictionary] = []

@onready var _preview_mesh: MeshInstance3D = $MeshInstance3D
@onready var disabled_box_texture: MeshInstance3D = $MeshInstance3D2
@onready var _preview_collision: CollisionShape3D = $Area3D/CollisionShape3D


func _init() -> void:
	super._init()
	size_default = Vector3(0.6, 0.4, 0.4)


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", "request_unload_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", "ok_unload_tag_name"):
		return
	OIPCommsSetup.validate_tag_property(property, "tag_group_name", "tag_groups", "box_length_tag_name")


func _enter_tree() -> void:
	super._enter_tree()
	tag_group_name = OIPCommsSetup.default_tag_group(tag_group_name)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)
	_reset_spawn_cycle()


func _exit_tree() -> void:
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)
	super._exit_tree()


func _ready() -> void:
	Simulation.started.connect(_on_simulation_started)
	Simulation.stopped.connect(_on_simulation_ended)
	_on_size_changed()
	_change_texture()


func _on_size_changed() -> void:
	if is_instance_valid(_preview_mesh):
		_preview_mesh.scale = size * 0.5
	if is_instance_valid(disabled_box_texture):
		disabled_box_texture.scale = size * 0.501
	if is_instance_valid(_preview_collision):
		var box_shape := _preview_collision.shape as BoxShape3D
		if box_shape:
			box_shape.size = size


func _physics_process(delta: float) -> void:
	if conveyor and Simulation.is_running() and &"speed" in conveyor:
		_conveyor_stopped = is_zero_approx(conveyor.speed)

	if disable or _conveyor_stopped or not Simulation.is_running():
		return

	if sorter_mode:
		_step_discharge_queue(delta)
		_step_sorter_handshake(delta)
		return

	if not _first_spawn_done:
		if _spawn_box():
			_first_spawn_done = true
			_on_spawn_succeeded()
		return

	if boxes_per_minute <= 0:
		return

	_scan_interval += delta

	if fixed_rate:
		var time_between: float = 60.0 / float(boxes_per_minute)
		if _scan_interval >= time_between:
			if _spawn_box():
				_on_spawn_succeeded()
	else:
		if _scan_interval >= _next_spawn_time:
			if _spawn_box():
				_on_spawn_succeeded()


func _sorter_log(msg: String) -> void:
	if sorter_debug:
		print("[%.3f] BoxSpawner '%s': %s" % [Time.get_ticks_msec() / 1000.0, name, msg])


## One tick of the sorter-mode handshake. States: reserve the next box and raise the
## request tag while publishing the box length, count up to [member sorter_ok_timeout]
## waiting for the PLC's ok (timeout drops the request and restarts — the same box is
## re-offered). A grant queues the box for discharge and immediately moves on to the
## next request (once the PLC lowers ok), so several boxes can be in flight; requests
## pause while [member sorter_max_pending] boxes await discharge.
func _step_sorter_handshake(delta: float) -> void:
	if not enable_comms:
		return
	_request_cooldown = maxf(0.0, _request_cooldown - delta)
	match _sorter_state:
		SorterState.REQUEST_PENDING:
			if _request_cooldown > 0.0:
				return
			if _discharge_queue.size() >= sorter_max_pending:
				return
			if _request_tag.is_ready():
				if not _offer_valid:
					var non_con: bool = _draw_nc_from_bag()
					_offer_size = _spawn_size_for(non_con)
					_offer_non_conveyable = non_con
					_offer_valid = true
				if _length_tag.is_ready():
					_length_tag.write_int16(roundi(_offer_size.x * 1000.0))
				_request_tag.write_bit(true)
				_sorter_log("WRITE request=HIGH, length=%d mm (queue %d/%d)"
						% [roundi(_offer_size.x * 1000.0), _discharge_queue.size(), sorter_max_pending])
				_sorter_wait = 0.0
				_sorter_state = SorterState.WAITING_OK
		SorterState.WAITING_OK:
			if _ok_high:
				_discharge_queue.append({
					"size": _offer_size,
					"non_conveyable": _offer_non_conveyable,
					"age": 0.0,
				})
				_offer_valid = false
				if _request_tag.is_ready():
					_request_tag.write_bit(false)
				_request_cooldown = _REQUEST_LOW_HOLD
				_sorter_log(("GRANT after %.3f s -> box (%d mm) queued for discharge in %.1f s"
						+ " (queue %d/%d), WRITE request=LOW, waiting for ok=LOW")
						% [_sorter_wait, roundi(_offer_size.x * 1000.0), sorter_ok_timeout,
						_discharge_queue.size(), sorter_max_pending])
				if _discharge_queue.size() >= sorter_max_pending:
					_sorter_log("queue full — requests paused until a box discharges")
				_sorter_state = SorterState.WAIT_OK_LOW
				return
			_sorter_wait += delta
			if _sorter_wait >= sorter_ok_timeout:
				if _request_tag.is_ready():
					_request_tag.write_bit(false)
				_request_cooldown = _REQUEST_LOW_HOLD
				_sorter_log("TIMEOUT: no ok within %.1f s -> WRITE request=LOW, retrying same box"
						% sorter_ok_timeout)
				_sorter_state = SorterState.REQUEST_PENDING
		SorterState.WAIT_OK_LOW:
			if not _ok_high:
				_sorter_log("ok=LOW seen — handshake complete, next request in %.2f s"
						% maxf(_request_cooldown, 0.0))
				_sorter_state = SorterState.REQUEST_PENDING


## Age every granted box; when the oldest has waited out the discharge period
## (= [member sorter_ok_timeout]), spawn it — retrying while the spawn area is blocked.
func _step_discharge_queue(delta: float) -> void:
	if _discharge_queue.is_empty():
		return
	for entry: Dictionary in _discharge_queue:
		entry["age"] = float(entry["age"]) + delta
	var head: Dictionary = _discharge_queue[0]
	if float(head["age"]) < sorter_ok_timeout:
		return
	if _spawn_sorter_box(head["size"], head["non_conveyable"]):
		_discharge_queue.pop_front()
		_on_spawn_succeeded()
		_sorter_log("SPAWNED box (%d mm) %.3f s after grant (queue %d/%d)"
				% [roundi((head["size"] as Vector3).x * 1000.0), float(head["age"]),
				_discharge_queue.size(), sorter_max_pending])
	elif not head.get("blocked_logged", false):
		head["blocked_logged"] = true
		_sorter_log("discharge due but spawn area is BLOCKED — retrying every tick")


## Spawn a specific already-granted box, bypassing the timer-mode size reservation.
func _spawn_sorter_box(box_size: Vector3, non_conveyable: bool) -> bool:
	if not scene:
		return false
	var box := scene.instantiate() as Box
	if not box:
		return false
	box.size = box_size
	box.set_meta("_reserved_spawn_size", box_size)
	box.set_meta("_reserved_non_conveyable", non_conveyable)
	box.set_meta("_used_pending_spawn_size", false)
	var spawn_transform := Transform3D(_get_spawn_basis(), global_position)
	var check_transform := spawn_transform
	check_transform.origin.y -= 0.5
	var check_size := Vector3(box.size.x, 1.0, box.size.z)
	var spawned: bool = _add_box_to_scene(box, spawn_transform, check_transform, check_size)
	if not spawned:
		# A blocked spawn re-queued the size into the timer-mode pending slot;
		# sorter mode keeps the box in its own discharge queue instead.
		_clear_pending_spawn_size()
	return spawned


func _spawn_box() -> bool:
	var box := _instantiate_box()
	if not box:
		return false

	var spawn_transform := Transform3D(_get_spawn_basis(), global_position)
	var check_transform := spawn_transform
	check_transform.origin.y -= 0.5
	var check_size := Vector3(box.size.x, 1.0, box.size.z)
	return _add_box_to_scene(box, spawn_transform, check_transform, check_size)


func _instantiate_box() -> Box:
	if not scene:
		return null

	var box := scene.instantiate() as Box
	if not box:
		return null

	var spawn_request := _reserve_spawn_request()
	box.size = spawn_request["size"]
	box.set_meta("_reserved_spawn_size", spawn_request["size"])
	box.set_meta("_reserved_non_conveyable", spawn_request["non_conveyable"])
	box.set_meta("_used_pending_spawn_size", spawn_request["used_pending"])
	return box


func _spawn_size_for(non_conveyable: bool) -> Vector3:
	if non_conveyable:
		return _get_random_size(non_conveyable_random_size_min, non_conveyable_random_size_max)
	if random_size:
		return _get_random_size(random_size_min, random_size_max)
	return size


# Pseudo-random NC quota: per BPM-sized window, exactly round(chance * BPM)
# spawns are NC, randomly distributed. Refills when the bag is empty or when
# BPM / chance changed since the bag was built.
func _draw_nc_from_bag() -> bool:
	if _nc_bag.is_empty() \
			or _nc_bag_bpm != boxes_per_minute \
			or not is_equal_approx(_nc_bag_chance, non_conveyable_spawn_chance):
		_refill_nc_bag()
	if _nc_bag.is_empty():
		return false
	return bool(_nc_bag.pop_back())


func _refill_nc_bag() -> void:
	_nc_bag.clear()
	_nc_bag_bpm = boxes_per_minute
	_nc_bag_chance = non_conveyable_spawn_chance
	if boxes_per_minute <= 0 or non_conveyable_spawn_chance <= 0.0:
		return
	var nc_count: int = int(roundf(non_conveyable_spawn_chance * float(boxes_per_minute)))
	nc_count = clampi(nc_count, 0, boxes_per_minute)
	for i in boxes_per_minute:
		_nc_bag.append(i < nc_count)
	_nc_bag.shuffle()


func _get_random_size(min_size: Vector3, max_size: Vector3) -> Vector3:
	var lower := min_size.min(max_size)
	var upper := min_size.max(max_size)
	return Vector3(
		randf_range(lower.x, upper.x),
		randf_range(lower.y, upper.y),
		randf_range(lower.z, upper.z)
	)


func _get_spawn_basis() -> Basis:
	return global_transform.basis.orthonormalized()


func _reserve_spawn_request() -> Dictionary:
	if _has_pending_spawn_size:
		_has_pending_spawn_size = false
		return {
			"size": _pending_spawn_size,
			"non_conveyable": _pending_non_conveyable,
			"used_pending": true,
		}
	var non_con: bool = _draw_nc_from_bag()
	return {
		"size": _spawn_size_for(non_con),
		"non_conveyable": non_con,
		"used_pending": false,
	}


func _add_box_to_scene(box: Box, spawn_transform: Transform3D, check_transform: Transform3D, check_size: Vector3) -> bool:
	if not _can_spawn_box(check_size, check_transform):
		_requeue_failed_spawn_size(box)
		box.queue_free()
		return false

	if box.get_meta("_used_pending_spawn_size", false):
		_clear_pending_spawn_size()
	if random_mass:
		if box.get_meta("_reserved_non_conveyable", false):
			box.mass = randf_range(non_conveyable_random_mass_min, non_conveyable_random_mass_max)
		else:
			box.mass = randf_range(random_mass_min, random_mass_max)
	else:
		box.mass = mass
	box.initial_linear_velocity = initial_linear_velocity
	# Non-conveyables spawn red so they're visually distinct down the line.
	box.color = Color.RED if box.get_meta("_reserved_non_conveyable", false) else box_color
	box.instanced = true

	if barcode_labels:
		_apply_barcode_label(box)

	add_child(box, true)
	box.global_transform = spawn_transform
	if get_tree().edited_scene_root:
		box.owner = get_tree().edited_scene_root

	var rb := box.get_node_or_null("RigidBody3D") as RigidBody3D
	if rb:
		rb.top_level = true
		rb.global_transform = spawn_transform
		rb.linear_velocity = initial_linear_velocity
		rb.set_meta("box_size", box.size)   # so the ScanTunnel can report measured L/W/H
	return true


func _requeue_failed_spawn_size(box: Box) -> void:
	var spawn_size: Variant = box.get_meta("_reserved_spawn_size", box.size)
	if spawn_size is Vector3:
		_pending_spawn_size = spawn_size
		_pending_non_conveyable = box.get_meta("_reserved_non_conveyable", false)
		_has_pending_spawn_size = true


func _clear_pending_spawn_size() -> void:
	_pending_spawn_size = Vector3.ZERO
	_pending_non_conveyable = false
	_has_pending_spawn_size = false


func _on_spawn_succeeded() -> void:
	_scan_interval = 0.0
	_spawn_counter += 1
	if not fixed_rate:
		_next_spawn_time = _get_random_spawn_interval()


func _can_spawn_box(box_size: Vector3, spawn_transform: Transform3D) -> bool:
	# Overlap prevention is always on — never spawn into a space another box occupies.
	var spawn_pos := spawn_transform.origin
	var inv_spawn_basis := spawn_transform.basis.orthonormalized().inverse()
	var half_check_size := box_size * 0.5
	for child in get_children():
		if not child is Box:
			continue
		var other_box := child as Box
		if not is_instance_valid(other_box):
			continue
		var other_rb := other_box.get_node_or_null("RigidBody3D") as Node3D
		var other_pos: Vector3 = other_rb.global_position if other_rb else other_box.global_position
		var other_half := other_box.size * 0.5

		# Compare in the spawner's local frame so the AABB test still uses the
		# correct per-axis extents when the spawner (or its conveyor) is rotated.
		var local_offset := inv_spawn_basis * (other_pos - spawn_pos)
		var dx := absf(local_offset.x)
		var dy := absf(local_offset.y)
		var dz := absf(local_offset.z)
		if dx < half_check_size.x + other_half.x \
				and dy < half_check_size.y + other_half.y \
				and dz < half_check_size.z + other_half.z:
			return false
	return true


func _reset_spawn_cycle() -> void:
	_scan_interval = 0.0
	_spawn_counter = 0
	_first_spawn_done = false
	_next_spawn_time = _get_random_spawn_interval()
	_nc_bag.clear()


func _get_random_spawn_interval() -> float:
	if boxes_per_minute <= 0:
		return INF
	return (60.0 / float(boxes_per_minute)) * randf_range(0.5, 1.5)


func _change_texture() -> void:
	if not is_inside_tree():
		return
	disabled_box_texture.visible = disable


func use() -> void:
	disable = not disable


## Stamps TWO barcodes on two random faces of the box (real parcels carry the same code on
## multiple sides for redundancy). Both share one code unless [member multi_barcode_chance]
## fires, which gives the two faces DIFFERENT codes (a multi-read). A rare parcel gets no label
## at all ([member no_barcode_chance]); each label may independently be damaged. Recorded as the
## [code]barcodes[/code] meta ([code]{code, face-normal}[/code] per label) for the ScanTunnel.
func _apply_barcode_label(box: Box) -> void:
	var rb := box.get_node_or_null("RigidBody3D")
	if rb == null:
		return
	if randf() < no_barcode_chance:
		rb.set_meta("barcodes", [])                  # no label at all -> no-read
		return
	# Two labels: the same code on both faces, unless this is a multi-read parcel.
	var code_a: String = _next_code()
	var code_b: String = code_a
	if randf() < multi_barcode_chance:
		code_b = _next_code()
	var assigned: Array[String] = [code_a, code_b]
	var faces: Array[Vector3] = [
		Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]
	faces.shuffle()
	var barcodes: Array = []
	for i: int in 2:
		var n: Vector3 = faces[i]
		var code: String = ""
		var tex: Texture2D
		if randf() < damaged_label_rate:
			tex = BarcodeLabel.make_damaged_barcode_texture()   # torn/smudged -> no valid id
		else:
			code = assigned[i]
			tex = BarcodeLabel.make_barcode_texture(code)
		_attach_label_to_face(rb, box, n, tex, code)
		barcodes.append({"code": code, "normal": n})
	rb.set_meta("barcodes", barcodes)


## Next sequential barcode id (wraps the per-run counter 1..999).
func _next_code() -> String:
	_barcode_seq += 1
	if _barcode_seq > 999:
		_barcode_seq = 1
	return String(BarcodeLabel.generate(_barcode_seq)["string"])


## Lays one barcode sticker (white backing + bars + human-readable id) flat on the box face
## whose outward normal is [param n].
func _attach_label_to_face(rb: Node, box: Box, n: Vector3, tex: Texture2D, text_str: String) -> void:
	var ext: Vector3 = box.size * 0.5
	var along: float = absf(n.x) * ext.x + absf(n.y) * ext.y + absf(n.z) * ext.z
	var plane_a: float
	var plane_b: float
	if absf(n.y) > 0.5:
		plane_a = box.size.x
		plane_b = box.size.z
	elif absf(n.x) > 0.5:
		plane_a = box.size.z
		plane_b = box.size.y
	else:
		plane_a = box.size.x
		plane_b = box.size.y
	var w: float = minf(plane_a, plane_b) * 0.82
	var aspect: float = float(tex.get_height()) / float(tex.get_width())  # bars strip h/w

	# Parent the label content onto the chosen face: local +Y = the face's outward normal.
	var tag := Node3D.new()
	tag.name = "BarcodeLabel"
	tag.transform = Transform3D(_face_basis(n), n * (along + 0.002))
	rb.add_child(tag)

	# white sticker backing (bars above, text below)
	var sticker := MeshInstance3D.new()
	sticker.name = "BarcodeBacking"
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, w * aspect * 2.6)
	sticker.mesh = pm
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.97, 0.97, 0.95)
	sticker.material_override = wm
	tag.add_child(sticker)

	# the 1D barcode
	var bars := MeshInstance3D.new()
	bars.name = "BarcodeBars"
	var cm := PlaneMesh.new()
	cm.size = Vector2(w * 0.92, w * 0.92 * aspect)
	bars.mesh = cm
	var lm := StandardMaterial3D.new()
	lm.albedo_texture = tex
	lm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	bars.material_override = lm
	bars.position = Vector3(0, 0.001, -w * aspect * 0.7)
	tag.add_child(bars)

	# human-readable id under the bars
	var text := Label3D.new()
	text.name = "BarcodeText"
	text.text = text_str
	text.font_size = 48
	text.pixel_size = w * 0.0011
	text.modulate = Color.BLACK
	text.rotation_degrees = Vector3(-90, 0, 0)
	text.position = Vector3(0, 0.002, w * aspect * 1.1)
	tag.add_child(text)


## Orthonormal basis whose local +Y axis points along [param normal] (the label's outward
## face direction); the X/Z axes span the face. Used to lay the sticker flat on any face.
static func _face_basis(normal: Vector3) -> Basis:
	var n: Vector3 = normal.normalized()
	var ref: Vector3 = Vector3.RIGHT if absf(n.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x: Vector3 = ref.cross(n).normalized()
	return Basis(x, n, x.cross(n).normalized())


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = PackedStringArray()
	if conveyor == null:
		warnings.append(
			"No conveyor assigned — assign one, or place this spawner above a conveyor so it"
			+ " auto-assigns at simulation start.")
	if sorter_mode and (request_unload_tag_name.is_empty() or ok_unload_tag_name.is_empty()):
		warnings.append(
			"Sorter mode needs comms enabled and both the request-unload and ok-unload tag"
			+ " names set — no boxes will spawn until the PLC handshake works.")
	return warnings


func _tag_group_initialized(tag_group_name_param: String) -> void:
	if _request_tag.on_group_initialized(tag_group_name_param):
		_request_tag.write_bit(false)
		if sorter_mode:
			_sorter_log("comms ready — WRITE request=LOW (initial)")
	_ok_tag.on_group_initialized(tag_group_name_param)
	if _length_tag.on_group_initialized(tag_group_name_param):
		_length_tag.write_int16(0)


func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms or not sorter_mode:
		return
	if _ok_tag.matches_group(tag_group_name_param) and _ok_tag.is_ready():
		var new_ok: bool = _ok_tag.read_bit()
		if new_ok != _ok_high:
			_sorter_log("RECV ok_to_unload=%s from PLC (state: %s)"
					% ["HIGH" if new_ok else "LOW", SorterState.keys()[_sorter_state]])
		_ok_high = new_ok


func _on_simulation_started() -> void:
	if conveyor == null:
		var found: Node3D = _find_conveyor_below()
		if found != null:
			# Auto-assigned; persists on the node — save the scene to keep it.
			conveyor = found
			print("BoxSpawner '%s' auto-assigned conveyor '%s' found beneath it." % [name, found.name])
	if conveyor == null:
		push_error("BoxSpawner '%s' has no conveyor assigned and none found beneath it." % name)
	elif &"speed" not in conveyor:
		push_warning("Conveyor reference in " + name + " does not have a speed property")
	_clear_pending_spawn_size()
	_barcode_seq = 0
	if barcode_labels:
		randomize()                      # fresh barcode sequence each run
	if enable_comms:
		_request_tag.register(tag_group_name, request_unload_tag_name)
		_ok_tag.register(tag_group_name, ok_unload_tag_name)
		_length_tag.register(tag_group_name, box_length_tag_name, OIPCommsTag.TYPE_INT16)
		if sorter_mode:
			_sorter_log(("sorter mode ON — group='%s' request='%s' ok='%s' length='%s',"
					+ " ok timeout/discharge %.1f s, max pending %d, low-hold %.2f s")
					% [tag_group_name, request_unload_tag_name, ok_unload_tag_name,
					box_length_tag_name, sorter_ok_timeout, sorter_max_pending, _REQUEST_LOW_HOLD])
	elif sorter_mode:
		push_warning("BoxSpawner '%s' is in sorter mode but comms are disabled — it will not spawn." % name)
	_sorter_state = SorterState.REQUEST_PENDING
	_sorter_wait = 0.0
	_ok_high = false
	_request_cooldown = 0.0
	_offer_valid = false
	_discharge_queue.clear()
	_reset_spawn_cycle()


## Finds a conveyor sitting directly under this spawner: a node exposing `speed` and `size`,
## below the spawn point, with the spawn point inside its belt footprint. Used to auto-assign
## the conveyor at sim start when the field was left empty.
func _find_conveyor_below() -> Node3D:
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().edited_scene_root
	if root == null:
		return null
	var origin: Vector3 = global_position
	var best: Node3D = null
	var best_y: float = -INF
	for node: Node in root.find_children("*", "Node3D", true, false):
		if node == self or (&"speed" not in node) or (&"size" not in node):
			continue
		var c: Node3D = node as Node3D
		if c.global_position.y >= origin.y - 0.01:
			continue                                  # must sit below the spawner
		var sz: Vector3 = c.get("size")
		var local: Vector3 = c.global_transform.affine_inverse() * origin
		# Belt convention: origin at the belt start, +X over [0, length], centred across ±width/2.
		if local.x >= -0.25 and local.x <= sz.x + 0.25 and absf(local.z) <= sz.z * 0.5 + 0.3:
			if c.global_position.y > best_y:          # the nearest conveyor below wins
				best_y = c.global_position.y
				best = c
	return best


func _on_simulation_ended() -> void:
	_clear_pending_spawn_size()
	_conveyor_stopped = false
	_barcode_seq = 0
	if _request_tag.is_ready():
		_request_tag.write_bit(false)
	if _length_tag.is_ready():
		_length_tag.write_int16(0)
	_sorter_state = SorterState.REQUEST_PENDING
	_sorter_wait = 0.0
	_ok_high = false
	_request_cooldown = 0.0
	_offer_valid = false
	_discharge_queue.clear()
