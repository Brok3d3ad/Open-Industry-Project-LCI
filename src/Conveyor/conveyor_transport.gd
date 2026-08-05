@tool
class_name ConveyorTransport
extends RefCounted

## Length-weighted conveyor drive.
##
## A rigid box straddling two belts concentrates its contact load at its leading
## and trailing edges, which are equidistant from its COM, so the normal load
## splits ~50/50 between the belts the entire time it straddles. The slower belt
## then pins the box at its speed (static friction) until the trailing edge
## clears the seam. This samples the flow (see [method surface_flow_at]) under the
## footprint and drives each sample point toward its local belt flow.
##
## Forces are applied per-sample at their footprint positions, so the net force
## drives the COM toward the length-weighted flow AND the net torque yaws the box
## to follow direction changes (perpendicular transfers, curves, skewed belts).
## Everything is capped (not a velocity override) so accumulation still resolves
## through the solver. A body with no conveyor surface under it is left to physics.

## Conveyor collision bodies join this group so the footprint rays can find them.
const SURFACE_GROUP := &"conveyor_surface"
## Surfaces whose conveyor is commanded to run join this group, independent of how fast
## they happen to be moving right now. Boxes consult it instead of the instantaneous
## surface velocity when deciding whether sleeping is safe: an accel/decel ramp can leave
## a genuinely-driving belt creeping below any sane wake threshold for seconds, and a box
## that sleeps there is not woken again by the surface velocity changing under it.
const DRIVING_GROUP := &"conveyor_driving"
## Force cap, expressed as acceleration (m/s^2). Bounds accumulation line pressure.
const DRIVE_MAX_ACCEL := 25.0
## Footprint sample count along the travel (local X) axis.
const SAMPLES_ALONG := 5
const RAY_UP := 0.05
const RAY_DOWN := 0.15

## Runtime toggle for A/B testing or disabling the assist.
static var enabled := true
## Slew strength for non-parallel transfers: 0 = translate only (no rotation),
## 1 = full per-sample torque. Gentle by default so right-angle transfers don't spin out.
static var angular_gain := 0.5
## Print a per-box drive trace (throttled). Set true to observe a few boxes;
## leave off in general — printing dominates cost at scale.
static var debug := false
## Throttle window per box, in milliseconds.
static var debug_interval_ms := 150

static var _next_log: Dictionary = {}
static var _query: PhysicsRayQueryParameters3D


## Surface flow at a world point, as the velocity of that point on the surface
## treated as a rigid body: the advertised linear flow plus the tangential
## contribution of any advertised spin about the body's own origin.
##
## Straight belts publish flow through [code]constant_linear_velocity[/code] and
## leave the angular term zero, so this is identity for them. Curved decks and
## rollers instead publish [code]constant_angular_velocity[/code] and have no
## linear term at all — sampling only the linear component would read them as
## stationary and drive packages toward a standstill, which is why they had to
## stay out of the blending group before this existed.
static func surface_flow_at(body: StaticBody3D, world_point: Vector3) -> Vector3:
	var spin: Vector3 = body.constant_angular_velocity
	if spin.is_zero_approx():
		return body.constant_linear_velocity
	return body.constant_linear_velocity + spin.cross(world_point - body.global_position)


## Add/remove a conveyor surface from the blending group (per-conveyor opt-in).
static func set_surface_blending(body: StaticBody3D, on: bool) -> void:
	if body == null:
		return
	if on:
		body.add_to_group(SURFACE_GROUP)
	elif body.is_in_group(SURFACE_GROUP):
		body.remove_from_group(SURFACE_GROUP)


## Add/remove a conveyor surface from the commanded-to-run group (see DRIVING_GROUP).
static func set_surface_driving(body: StaticBody3D, on: bool) -> void:
	if body == null:
		return
	if on:
		body.add_to_group(DRIVING_GROUP)
	elif body.is_in_group(DRIVING_GROUP):
		body.remove_from_group(DRIVING_GROUP)


static func drive_body(body: RigidBody3D, footprint: Vector3, delta: float) -> void:
	if not enabled or body == null or body.freeze or body.sleeping or delta <= 0.0:
		return
	# The assist only ever drives surfaces that opted into the blending group (velocity_blending=true).
	# When none exist, drive_body is a no-op — bail BEFORE the per-box footprint raycasts so idle scenes
	# (and every settled box) don't pay 5 raycasts/tick for nothing. get_first_node_in_group is
	# self-correcting as bodies are freed.
	var tree := body.get_tree()
	if tree == null or tree.get_first_node_in_group(SURFACE_GROUP) == null:
		return
	var world := body.get_world_3d()
	if world == null:
		return
	var space := world.direct_space_state
	if space == null:
		return

	var xform := body.global_transform
	var up := xform.basis.y.normalized()
	var half := footprint * 0.5

	# Reuse one query across all rays/boxes (single-threaded physics callback).
	var q := _query
	if q == null:
		q = PhysicsRayQueryParameters3D.new()
		_query = q
	q.exclude = [body.get_rid()]

	var pts := PackedVector3Array()
	var flows := PackedVector3Array()
	var smin := INF
	var smax := -INF

	for i in SAMPLES_ALONG:
		var fx := -half.x + footprint.x * (float(i) / float(SAMPLES_ALONG - 1))
		var world_pt := xform * Vector3(fx, -half.y, 0.0)
		q.from = world_pt + up * RAY_UP
		q.to = world_pt - up * RAY_DOWN
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var col := hit.get("collider") as StaticBody3D
		if col != null and col.is_in_group(SURFACE_GROUP):
			pts.append(world_pt)
			var flow := surface_flow_at(col, world_pt)
			flows.append(flow)
			if debug:
				var s := Vector2(flow.x, flow.z).length()
				smin = minf(smin, s)
				smax = maxf(smax, s)

	var hits := pts.size()
	if hits == 0:
		return

	var com := body.global_position
	var lin := body.linear_velocity
	var ang := body.angular_velocity
	var per_n := body.mass / float(hits)
	var per_cap := per_n * DRIVE_MAX_ACCEL
	var inv_dt := 1.0 / delta

	var mean_flow := Vector3.ZERO
	for i in hits:
		mean_flow += flows[i]
	mean_flow /= float(hits)

	# Linear channel: drive the COM toward the length-weighted mean flow. Identical
	# to the central-force model, so the parallel-transfer ramp is unchanged.
	var lacc := Vector3(mean_flow.x - lin.x, 0.0, mean_flow.z - lin.z) * inv_dt
	if lacc.length() > DRIVE_MAX_ACCEL:
		lacc = lacc.normalized() * DRIVE_MAX_ACCEL
	body.apply_central_force(lacc * body.mass)

	# Angular channel: yaw from how the flow *varies* across the footprint (zero for
	# parallel belts, non-zero for perpendicular/curved/skewed), plus spin damping.
	# Applied as a pure torque, so it never perturbs the linear ramp.
	var yaw := 0.0
	for i in hits:
		var r := pts[i] - com
		var dev := flows[i] - mean_flow - ang.cross(r)
		dev -= up * dev.dot(up)
		var f := dev * (per_n * inv_dt)
		if f.length() > per_cap:
			f = f.normalized() * per_cap
		yaw += r.cross(f).dot(up)
	body.apply_torque(up * (yaw * angular_gain))

	if debug:
		_trace(body, hits, smin, smax, mean_flow, lin, yaw * angular_gain)


static func _trace(body: RigidBody3D, hits: int, smin: float, smax: float,
		mean_flow: Vector3, cur: Vector3, yaw: float) -> void:
	var now := Time.get_ticks_msec()
	var id := body.get_instance_id()
	if now < int(_next_log.get(id, 0)):
		return
	_next_log[id] = now + debug_interval_ms

	var parent := body.get_parent()
	var who: String = str(parent.name) if parent != null else str(body.name)
	var tgt_spd := Vector2(mean_flow.x, mean_flow.z).length()
	var cur_spd := Vector2(cur.x, cur.z).length()
	var straddling: bool = (smax - smin) > 0.05
	var tag := "  <-- SEAM, blending" if straddling else ""
	print("[ConvDrive] %s  on %d/%d  belt %.2f-%.2f m/s  target %.2f  box %.2f  yaw %+.2f%s" % [
			who, hits, SAMPLES_ALONG, smin, smax, tgt_spd, cur_spd, yaw, tag])
