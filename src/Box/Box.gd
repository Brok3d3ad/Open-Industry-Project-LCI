@tool
class_name Box
extends ResizableNode3D

## Initial velocity applied to this box when simulation starts.
@export var initial_linear_velocity: Vector3 = Vector3.ZERO
## Mass of the box in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var mass: float = 10.0:
	set(value):
		mass = value
		if _rigid_body_3d:
			_rigid_body_3d.mass = value
## The color of the box material.
@export var color: Color = Color.WHITE:
	set(value):
		color = value
		if _mesh_instance_3d:
			_mesh_instance_3d.set_surface_override_material(0, _get_shared_material(color))

static var _material_cache: Dictionary = {}

func _get_shared_material(c: Color) -> StandardMaterial3D:
	if not _material_cache.has(c):
		var base: StandardMaterial3D = _mesh_instance_3d.mesh.surface_get_material(0)
		var mat: StandardMaterial3D = base.duplicate()
		mat.albedo_color = c
		_material_cache[c] = mat
	return _material_cache[c]

var _initial_transform: Transform3D
var _paused: bool = false
var _enable_initial_transform: bool = false
var instanced: bool = false

@onready var _rigid_body_3d: RigidBody3D = $RigidBody3D
@onready var _mesh_instance_3d: MeshInstance3D = $RigidBody3D/MeshInstance3D


func _init() -> void:
	super._init()
	size_default = Vector3(0.6, 0.4, 0.4)


func _enter_tree() -> void:
	super._enter_tree()
	Simulation.started.connect(_on_simulation_started)
	Simulation.stopped.connect(_on_simulation_ended)
	Simulation.pause_toggled.connect(_on_simulation_set_paused)


func _ready() -> void:
	_on_size_changed()
	if color != Color.WHITE:
		set("color", color)
	_rigid_body_3d.mass = mass
	# Continuous CD (Jolt: LinearCast motion quality) — a package only a few cm
	# tall crosses a thin collision shell (e.g. the curved belt's trimesh) in one
	# 120 Hz step once it falls fast enough, and the discrete solver never sees
	# the contact. The cast only engages when motion is large relative to body
	# size, so slow/settled boxes pay nothing.
	_rigid_body_3d.continuous_cd = true
	# Let settled boxes sleep so Jolt drops them from the solver (huge win for piled/accumulated
	# packages). A sleep-veto (below) keeps boxes on a MOVING belt awake so they never freeze mid-line.
	_rigid_body_3d.can_sleep = true
	if not _rigid_body_3d.sleeping_state_changed.is_connected(_on_sleeping_changed):
		_rigid_body_3d.sleeping_state_changed.connect(_on_sleeping_changed)
	_rigid_body_3d.freeze = not Simulation.is_running()
	if Simulation.is_running():
		instanced = true
		_rigid_body_3d.linear_velocity = initial_linear_velocity


func _exit_tree() -> void:
	Simulation.started.disconnect(_on_simulation_started)
	Simulation.stopped.disconnect(_on_simulation_ended)
	Simulation.pause_toggled.disconnect(_on_simulation_set_paused)
	super._exit_tree()
	if instanced:
		queue_free()


## Physics ticks between periodic stuck-box support checks (~4x/s at 120 Hz). Must stay
## comfortably under the physics server's time-before-sleep (~0.5 s) so the latch below
## reaches a settling box before it actually falls asleep.
const _SUPPORT_CHECK_INTERVAL: int = 30
var _support_check_tick: int = 0
## True while we are holding `can_sleep` off because the surface underneath is driving.
var _sleep_latched_off: bool = false


func _physics_process(delta: float) -> void:
	if _paused or not Simulation.is_running():
		_release_sleep_latch()
		return
	if _rigid_body_3d.freeze:
		_release_sleep_latch()
		return
	# Deterministic anti-freeze. Waking a sleeping box one-shot is not enough: through the
	# creeping start of an accel ramp the box is *genuinely* slower than the sleep
	# threshold, so the physics server puts it straight back to sleep, and drive_body
	# (which bails on `sleeping`) never gets a tick in which to accelerate it. So while the
	# surface underneath is driving, take sleeping off the table entirely rather than
	# fighting it every 30 frames. Restored the moment the box is over something stopped,
	# so chutes, floors and idle piles still settle out of the solver.
	_support_check_tick += 1
	if _support_check_tick >= _SUPPORT_CHECK_INTERVAL:
		_support_check_tick = 0
		var driven: bool = _is_on_moving_surface()
		if driven != _sleep_latched_off:
			_sleep_latched_off = driven
			_rigid_body_3d.can_sleep = not driven
		if driven and _rigid_body_3d.sleeping:
			_rigid_body_3d.sleeping = false
	ConveyorTransport.drive_body(_rigid_body_3d, size, delta)


func _release_sleep_latch() -> void:
	if not _sleep_latched_off:
		return
	_sleep_latched_off = false
	_rigid_body_3d.can_sleep = true


## Only boxes on a STOPPED surface (chute / floor / an idle box pile) should sleep. If we just fell
## asleep while resting on a MOVING belt (its surface carries a constant_linear_velocity), wake back
## up so the belt keeps driving us — a briefly-stalled box must never freeze mid-line. This costs one
## raycast per sleep transition, not per frame.
func _on_sleeping_changed() -> void:
	if not Simulation.is_running() or not _rigid_body_3d.sleeping:
		return
	if _is_on_moving_surface():
		# Deferred: flipping sleep state from inside the physics server's own
		# sleep-transition callback is occasionally swallowed, leaving the box
		# frozen mid-belt.
		_rigid_body_3d.set_deferred(&"sleeping", false)


func _is_on_moving_surface() -> bool:
	var world := _rigid_body_3d.get_world_3d()
	if world == null:
		return false
	var space := world.direct_space_state
	if space == null:
		return false
	var from := _rigid_body_3d.global_position
	# Reach past the support face in any resting orientation (a tipped box's
	# support sits up to half its LONGEST dimension below the center).
	var reach: float = size.length() * 0.5 + 0.15
	var to := from + Vector3(0.0, -reach, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [_rigid_body_3d.get_rid()]
	var hit := space.intersect_ray(q)
	var sb := hit.get("collider") as StaticBody3D
	if sb != null:
		# A conveyor that is commanded to run counts as moving even while its accel/decel
		# ramp still has the surface below the velocity thresholds below — otherwise a box
		# sleeps through the slow start of the ramp and the belt walks out from under it.
		if sb.is_in_group(ConveyorTransport.DRIVING_GROUP):
			return true
		# Curved belts drive via constant_angular_velocity; straight ones via linear.
		return sb.constant_linear_velocity.length() > 0.05 \
				or sb.constant_angular_velocity.length() > 0.05
	# Resting on another box: follow a moving carrier instead of sleeping on it.
	var rb := hit.get("collider") as RigidBody3D
	return rb != null and rb.linear_velocity.length() > 0.05


func _get_constrained_size(new_size: Vector3) -> Vector3:
	return new_size


func selected() -> void:
	if _paused or not Simulation.is_running():
		return

	if _rigid_body_3d.freeze:
		_rigid_body_3d.top_level = false
		if _rigid_body_3d.transform != Transform3D.IDENTITY:
			_rigid_body_3d.transform = Transform3D.IDENTITY
	else:
		_rigid_body_3d.top_level = true
		if transform != _rigid_body_3d.transform:
			transform = _rigid_body_3d.transform


func use() -> void:
	if EditorInterface.is_transforming():
		EditorInterface.keep_transform_freeze()
		_rigid_body_3d.freeze = true
		return
	_rigid_body_3d.freeze = not _rigid_body_3d.freeze


func _inspector_transform_committed() -> void:
	if _rigid_body_3d.freeze or not Simulation.is_running():
		return
	var target := global_transform
	PhysicsServer3D.body_set_state(_rigid_body_3d.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target)
	_rigid_body_3d.global_transform = target
	_rigid_body_3d.linear_velocity = Vector3.ZERO
	_rigid_body_3d.angular_velocity = Vector3.ZERO
	_rigid_body_3d.reset_physics_interpolation()


func _on_size_changed() -> void:
	if not is_instance_valid(_mesh_instance_3d) or not is_instance_valid(_rigid_body_3d):
		return

	var mesh_instance := _mesh_instance_3d
	var collision_shape := _rigid_body_3d.get_node_or_null("CollisionShape3D") as CollisionShape3D

	if mesh_instance:
		mesh_instance.scale = size/2

	if collision_shape:
		var box_shape := collision_shape.shape as BoxShape3D
		if box_shape:
			box_shape.size = size


func _on_simulation_started() -> void:
	if _enable_initial_transform:
		return

	_initial_transform = global_transform
	_rigid_body_3d.linear_velocity = initial_linear_velocity
	_rigid_body_3d.top_level = true
	_rigid_body_3d.freeze = false
	_enable_initial_transform = true


func _on_simulation_ended() -> void:
	if instanced:
		queue_free()
	else:
		_rigid_body_3d.top_level = false
		_rigid_body_3d.transform = Transform3D.IDENTITY
		_rigid_body_3d.linear_velocity = Vector3.ZERO
		_rigid_body_3d.angular_velocity = Vector3.ZERO
		# Work around for #83
		if _enable_initial_transform:
			global_transform = _initial_transform
			_enable_initial_transform = false


func _on_simulation_set_paused(paused: bool) -> void:
	_paused = paused
	_rigid_body_3d.top_level = true
	_rigid_body_3d.freeze = paused
	transform = _rigid_body_3d.transform
	_rigid_body_3d.top_level = not paused
