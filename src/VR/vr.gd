@tool
class_name VR
extends BeltConveyor

## VarioRoute-style pivoting-roller sorter built on the `BeltConveyor` base.
##
## Inherits the belt conveyor's legs, side guards, frame rails, resize handles and
## snapping unchanged. It only SWAPS THE SURFACE: the flat belt mesh is hidden and a
## procedural pivoting-roller field (tiled from res://assets/3DModels/VR/VR_Roller.glb)
## is laid over the deck instead. The belt's own collision body (`RunBody_*`) is reused
## as the transport surface — every physics frame its `constant_linear_velocity` is
## rotated about vertical by the divert angle, so a box on the deck is driven STRAIGHT,
## LEFT or RIGHT (±`MAX_DIVERT_ANGLE`) like the real pivoting roller units.
##
## Drive it with the inherited `speed` (0 = stopped). The divert direction comes from the
## `divert` property, or from `auto_sort` (alternating LEFT/RIGHT per parcel at the infeed
## light barrier). Keep the conveyor STRAIGHT (single segment) — the divert assumes a
## straight deck.

enum DivertDir { STRAIGHT, LEFT, RIGHT }
## Repeating sequence auto mode assigns to successive boxes.
enum AutoPattern { STRAIGHT_RIGHT_LEFT, LEFT_STRAIGHT, RIGHT_STRAIGHT, LEFT_RIGHT }

const GLB_PATH: String = "res://assets/3DModels/VR/VR_Roller.glb"
const BOX_COLLISION_MASK: int = 8   # boxes ride on physics layer 4 (value 8)
const BOX_LENGTH: float = 0.3       # assumed parcel length (auto-mode fully-on gate)
const PANEL_NATIVE: float = 0.40    # GLB panel tile is 0.40 m square (native size before scaling)
const DECK_THICKNESS: float = 0.12  # solid deck slab depth (blue side-guard material)
const DEBUG: bool = false           # set true to print VR sorting state to the output console

#region Config ---------------------------------------------------------------------
# Fixed tuning — hardcoded, intentionally NOT exposed in the inspector.
const ROLLER_SCALE: float = 1.5          # barrel size as a fraction of its cell
const HOLE_CLEARANCE: float = 1.3        # dark hole radius vs barrel radius
const SURFACE_FRICTION: float = 1.4      # deck grip on the diagonal divert
const FLIP_SPIN: bool = false            # reverse the roller roll direction
const ROLLER_HEIGHT_OFFSET: float = 0.0  # vertical nudge of the roller field
const SHOW_PANELS: bool = false          # GLB white tiles on top of the deck
const BODY_DEPTH: float = 0.45           # solid deck slab depth toward the legs
const MAX_DIVERT_ANGLE: float = 35.0     # pivot angle when diverting
const ROLLER_SPIN_SPEED: float = 8.0     # barrel spin rate
const STAGGER: bool = true               # brick / staggered layout
const ROLLER_ROTATION_DEG: float = 90.0  # barrels across flow → conveys straight by default

## Rollers across the deck width (per section).
@export_range(2, 24, 1) var rollers_across: int = 8:
	set(value):
		rollers_across = value
		if is_node_ready():
			_request_rebuild()
## Number of divert sections (roller rows along the flow).
@export_range(2, 40, 1) var sections: int = 10:
	set(value):
		sections = value
		if is_node_ready():
			_request_rebuild()
## Non-comms fallback divert pattern, one step per box (used when Enable Comms is off).
@export var auto_pattern: AutoPattern = AutoPattern.STRAIGHT_RIGHT_LEFT
## The photo eye that detects + measures each box. ASSIGNING it enables sorting; its
## physical `detected` flag is used, so a normally-closed sensor works as-is.
@export_node_path("Node3D") var sensor: NodePath
## PLC destination tags (BOOL) — latched when the sensor blocks: the box goes LEFT or
## RIGHT if that tag is set, otherwise STRAIGHT (default). Needs Enable Comms.
@export var divert_tag_group_name: String
@export_custom(0, "tag_group_enum") var divert_tag_groups: String:
	set(value):
		divert_tag_group_name = value
		divert_tag_groups = value
@export var straight_tag_name: String = ""
@export var left_tag_name: String = ""
@export var right_tag_name: String = ""
#endregion

# Internal generated nodes / caches
var _panel_mm_inst: MultiMeshInstance3D = null
var _roller_mm_inst: MultiMeshInstance3D = null
var _hole_mm_inst: MultiMeshInstance3D = null
var _hole_mesh_cache: CylinderMesh = null
var _hole_mat_cache: StandardMaterial3D = null
var _roller_shader: ShaderMaterial = null
var _light_barrier: Area3D = null
var _deck_sensor: Area3D = null
var _lb_bodies: Array = []
var _parcels: Dictionary = {}        # RigidBody3D -> latched DivertDir (sampled at the light barrier)
var _fully_on: Dictionary = {}       # RigidBody3D -> true once the box is fully on the deck
var _box_len: Dictionary = {}        # RigidBody3D -> length measured crossing the light barrier
var _lb_entry_x: Dictionary = {}     # RigidBody3D -> local X when it tripped the light barrier
var _sort_counter: int = 0
# Per-section (per row of rollers) divert state — each row diverts independently.
var _section_bodies: Array[StaticBody3D] = []  # one transport body per row
var _section_x: Array[float] = []              # local X of each row centre
var _section_angle_cur: PackedFloat32Array = PackedFloat32Array()  # smoothed angle (deg) per row
var _grid_nz: int = 1                           # rollers per row (idx -> row mapping)
var _roller_positions: Array[Vector3] = []      # per-roller local position (for live yaw)
var _roller_rs: float = 1.0                      # roller instance scale
var _section_pitch: float = 0.09                 # one section length along flow (the divert unit)
var _deck_min_x: float = 0.0                    # local X of the deck infeed edge
var _deck_max_x: float = 0.0                    # local X of the deck discharge edge
# Auto mode (external sensor -> sequenced divert)
var _auto_sensor_node: Node = null
var _auto_last_detected: bool = false           # edge tracker on the sensor (blocked state)
var _auto_primed: bool = false                  # first poll after sim start primes, no edge
var _dbg_frame: int = 0                          # debug heartbeat counter
var _auto_seq: int = 0                           # STRAIGHT/RIGHT/LEFT cycle counter
var _tracked: Array = []                         # [{cmd:int, dist:float, len:float}] predicted boxes
var _auto_passing: Dictionary = {}               # the box currently crossing the assigned sensor
var _sensor_to_deck_dist: float = 0.0            # assigned sensor -> deck infeed distance (metres)
# PLC destination tags (BOOL), read when the sensor blocks
var _div_straight_tag := OIPCommsTag.new()
var _div_left_tag := OIPCommsTag.new()
var _div_right_tag := OIPCommsTag.new()
# GLB unit (one panel + one roller), measured once
var _panel_mesh: Mesh = null
var _panel_xform: Transform3D = Transform3D.IDENTITY
var _roller_mesh: Mesh = null
var _roller_xform: Transform3D = Transform3D.IDENTITY


#region Build ----------------------------------------------------------------------
## Let the belt base build path / bodies / frame / guards / legs, then swap the surface.
func _rebuild() -> void:
	super._rebuild()
	if not is_inside_tree():
		return
	_neutralize_belt_bodies()
	_hide_belt_surface()
	_build_roller_field()
	_build_light_barrier()
	_build_deck_sensor()


func _hide_belt_surface() -> void:
	if is_instance_valid(_mesh_instance):
		_mesh_instance.visible = false


## Disable the inherited belt collision bodies — the per-section bodies are the riding
## surface now, so each row can carry its own (independent) divert velocity.
func _neutralize_belt_bodies() -> void:
	for body: StaticBody3D in _bodies:
		if is_instance_valid(body):
			body.collision_layer = 0
			body.constant_linear_velocity = Vector3.ZERO


## Local-space deck extent (and top Y) derived from the belt collision bodies, so the
## roller field lands exactly where boxes ride regardless of how the path is centered.
func _deck_extent_local() -> Dictionary:
	var min_x: float = 1e9
	var max_x: float = -1e9
	var min_z: float = 1e9
	var max_z: float = -1e9
	var top_y: float = -1e9
	var found: bool = false
	for body: StaticBody3D in _bodies:
		if not is_instance_valid(body):
			continue
		var cs := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs == null or not (cs.shape is BoxShape3D):
			continue
		var hs: Vector3 = (cs.shape as BoxShape3D).size * 0.5
		var xf: Transform3D = body.transform * cs.transform
		for i: int in 8:
			var corner := Vector3(
				hs.x if (i & 1) else -hs.x,
				hs.y if (i & 2) else -hs.y,
				hs.z if (i & 4) else -hs.z)
			var p: Vector3 = xf * corner
			min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
			min_z = minf(min_z, p.z); max_z = maxf(max_z, p.z)
			top_y = maxf(top_y, p.y)
			found = true
	if not found:
		var hl: float = size.x * 0.5
		var hw: float = size.z * 0.5
		return {"min_x": -hl, "max_x": hl, "min_z": -hw, "max_z": hw, "top_y": size.y * 0.5}
	return {"min_x": min_x, "max_x": max_x, "min_z": min_z, "max_z": max_z, "top_y": top_y}


func _build_roller_field() -> void:
	if _panel_mesh == null or _roller_mesh == null:
		_load_glb_unit()
	if _roller_mesh == null:
		return
	var ext: Dictionary = _deck_extent_local()
	var min_x: float = ext["min_x"]
	var max_x: float = ext["max_x"]
	var min_z: float = ext["min_z"]
	var max_z: float = ext["max_z"]
	var y_place: float = float(ext["top_y"]) - 0.04 + ROLLER_HEIGHT_OFFSET
	var hole_y: float = float(ext["top_y"]) - 0.05 + ROLLER_HEIGHT_OFFSET
	var deck_l: float = max_x - min_x
	var deck_w: float = max_z - min_z
	# Explicit grid: `rollers_across` columns x `sections` sections. Roller/hole are sized to the
	# SMALLER cell dimension so they always fit (they shrink to keep the requested counts).
	var nz: int = maxi(1, rollers_across)
	var nx: int = maxi(1, sections)
	var pz: float = deck_w / float(nz)
	var px: float = deck_l / float(nx)
	var cell: float = minf(px, pz)
	var rs: float = (cell / PANEL_NATIVE) * ROLLER_SCALE
	var hole_r: float = 0.085 * rs * HOLE_CLEARANCE
	# Inset the field by the hole radius so edge holes never poke past the deck.
	var span_l: float = maxf(0.01, deck_l - 2.0 * hole_r)
	var span_w: float = maxf(0.01, deck_w - 2.0 * hole_r)
	var cpx: float = span_l / float(nx)
	var cpz: float = span_w / float(nz)
	var panel_basis: Basis = Basis.IDENTITY.scaled(Vector3(px / PANEL_NATIVE, 1.0, pz / PANEL_NATIVE))
	var roller_basis: Basis = Basis(Vector3.UP, deg_to_rad(ROLLER_ROTATION_DEG)).scaled(Vector3(rs, rs, rs))
	var hole_basis: Basis = Basis.IDENTITY.scaled(Vector3(hole_r, 0.012, hole_r))

	_panel_mm_inst = _ensure_mm_inst("_VRPanels", _panel_mm_inst)
	_roller_mm_inst = _ensure_mm_inst("_VRRollers", _roller_mm_inst)
	_hole_mm_inst = _ensure_mm_inst("_VRHoles", _hole_mm_inst)

	var panel_mm := MultiMesh.new()
	panel_mm.transform_format = MultiMesh.TRANSFORM_3D
	panel_mm.mesh = _panel_mesh
	panel_mm.instance_count = nx * nz
	var roller_mm := MultiMesh.new()
	roller_mm.transform_format = MultiMesh.TRANSFORM_3D
	roller_mm.mesh = _roller_mesh
	roller_mm.instance_count = nx * nz
	var hole_mm := MultiMesh.new()
	hole_mm.transform_format = MultiMesh.TRANSFORM_3D
	hole_mm.mesh = _hole_mesh()
	hole_mm.instance_count = nx * nz

	_roller_positions.clear()
	_roller_rs = rs
	_section_pitch = px
	var idx: int = 0
	for ix: int in nx:
		var x: float = min_x + hole_r + (float(ix) + 0.5) * cpx
		# Brick STAGGER: alternate sections offset across the width.
		var z_off: float = 0.0
		if STAGGER:
			z_off = -cpz * 0.2 if (ix % 2 == 0) else cpz * 0.2
		for iz: int in nz:
			var z: float = min_z + hole_r + (float(iz) + 0.5) * cpz + z_off
			var pos := Vector3(x, y_place, z)
			panel_mm.set_instance_transform(idx, Transform3D(panel_basis, pos) * _panel_xform)
			roller_mm.set_instance_transform(idx, Transform3D(roller_basis, pos) * _roller_xform)
			hole_mm.set_instance_transform(idx, Transform3D(hole_basis, Vector3(x, hole_y, z)))
			_roller_positions.append(pos)
			idx += 1

	_panel_mm_inst.multimesh = panel_mm
	_panel_mm_inst.visible = SHOW_PANELS
	_roller_mm_inst.multimesh = roller_mm
	_make_roller_shader()
	_roller_mm_inst.material_override = _roller_shader
	_hole_mm_inst.multimesh = hole_mm
	_hole_mm_inst.material_override = _hole_material()
	_grid_nz = nz
	_build_section_bodies(min_x, deck_l, nx, px, min_z, max_z, float(ext["top_y"]))
	_build_deck_fill(min_x, max_x, min_z, max_z, float(ext["top_y"]))


## One transport StaticBody per row (section). Each carries its own divert velocity in
## _physics_process, so different parcels on the deck can be diverted independently.
func _build_section_bodies(min_x: float, deck_l: float, nx: int, px: float,
		min_z: float, max_z: float, top_y: float) -> void:
	for old: StaticBody3D in _section_bodies:
		if is_instance_valid(old):
			old.queue_free()
	_section_bodies.clear()
	_section_x.clear()
	_deck_min_x = min_x
	_deck_max_x = min_x + deck_l
	var cz: float = (min_z + max_z) * 0.5
	var deck_w: float = max_z - min_z
	for ix: int in nx:
		var x: float = min_x + (float(ix) + 0.5) * deck_l / float(nx)
		var body := StaticBody3D.new()
		body.name = "_VRSection_%d" % ix
		var pm := PhysicsMaterial.new()
		pm.friction = SURFACE_FRICTION
		pm.rough = true
		pm.bounce = 0.0
		body.physics_material_override = pm
		add_child(body, false, Node.INTERNAL_MODE_FRONT)
		body.owner = self
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		# Slight overlap (px * 1.1) so a box crossing a row seam doesn't catch a lip.
		shape.size = Vector3(px * 1.1, 0.04, maxf(0.05, deck_w))
		col.shape = shape
		body.add_child(col)
		body.position = Vector3(x, top_y - 0.02, cz)
		_section_bodies.append(body)
		_section_x.append(x)
	_section_angle_cur = PackedFloat32Array()
	_section_angle_cur.resize(nx)


## Unit cylinder (radius 1, height 1) used as the dark hole disc, scaled per instance.
func _hole_mesh() -> CylinderMesh:
	if _hole_mesh_cache == null:
		_hole_mesh_cache = CylinderMesh.new()
		_hole_mesh_cache.top_radius = 1.0
		_hole_mesh_cache.bottom_radius = 1.0
		_hole_mesh_cache.height = 1.0
		_hole_mesh_cache.radial_segments = 16
		_hole_mesh_cache.rings = 0
	return _hole_mesh_cache


func _hole_material() -> StandardMaterial3D:
	if _hole_mat_cache == null:
		_hole_mat_cache = StandardMaterial3D.new()
		_hole_mat_cache.albedo_color = Color(0.05, 0.05, 0.06)
		_hole_mat_cache.roughness = 0.9
		_hole_mat_cache.metallic = 0.0
	return _hole_mat_cache


## Solid blue deck slab (side-guard material), flush at the deck surface and extending
## down, so the deck reads as a solid body with the rollers poking through the top —
## instead of a hollow shell. Ends stay open (no wall above the surface).
func _build_deck_fill(min_x: float, max_x: float, min_z: float, max_z: float, top_y: float) -> void:
	var fill := get_node_or_null("_VRDeckFill") as MeshInstance3D
	if not is_instance_valid(fill):
		fill = MeshInstance3D.new()
		fill.name = "_VRDeckFill"
		add_child(fill, false, Node.INTERNAL_MODE_FRONT)
		fill.owner = self
	var depth: float = maxf(DECK_THICKNESS, BODY_DEPTH)
	var bm := BoxMesh.new()
	bm.size = Vector3(maxf(0.05, max_x - min_x), depth, maxf(0.05, max_z - min_z))
	fill.mesh = bm
	fill.set_surface_override_material(0, SideGuardMesh.create_material())
	# Slab top just below the panel bottom so the holes become recesses (no z-fight).
	var deck_top: float = top_y - 0.05 + ROLLER_HEIGHT_OFFSET
	fill.position = Vector3((min_x + max_x) * 0.5, deck_top - depth * 0.5, (min_z + max_z) * 0.5)


func _ensure_mm_inst(node_name: String, cached: MultiMeshInstance3D) -> MultiMeshInstance3D:
	var inst: MultiMeshInstance3D = cached
	if not is_instance_valid(inst):
		inst = get_node_or_null(node_name) as MultiMeshInstance3D
	if not is_instance_valid(inst):
		inst = MultiMeshInstance3D.new()
		inst.name = node_name
		add_child(inst, false, Node.INTERNAL_MODE_FRONT)
		inst.owner = self
	return inst


## Instantiate the GLB once and capture the panel + roller meshes with their authored
## local transforms (so the barrel keeps its baked orientation when tiled into a MultiMesh).
func _load_glb_unit() -> void:
	var packed := load(GLB_PATH) as PackedScene
	if packed == null:
		push_warning("VR: could not load %s" % GLB_PATH)
		return
	var inst: Node = packed.instantiate()
	_collect_unit_meshes(inst, Transform3D.IDENTITY)
	inst.free()


func _collect_unit_meshes(node: Node, accum: Transform3D) -> void:
	for c: Node in node.get_children():
		var cx: Transform3D = accum
		if c is Node3D:
			cx = accum * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			var mi := c as MeshInstance3D
			var label: String = (mi.name + " " + mi.mesh.resource_name).to_lower()
			if label.contains("panel"):
				_panel_mesh = mi.mesh
				_panel_xform = cx
			elif label.contains("roller") or label.contains("cylinder"):
				_roller_mesh = mi.mesh
				_roller_xform = cx
		_collect_unit_meshes(c, cx)


## Spin (about the barrel's authored axle) + yaw (divert) driven from uniforms. The mesh
## already carries the red roller material from the GLB; this only adds the motion.
func _make_roller_shader() -> void:
	if _roller_shader != null:
		return
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform float u_speed = 0.0;
uniform vec3 u_albedo : source_color = vec3(0.62, 0.05, 0.04);
varying float v_ang;
void vertex() {
	float sa = TIME * u_speed;
	float cs = cos(sa); float ss = sin(sa);
	vec3 p = VERTEX;
	// Angle of this vertex around the axle BEFORE spinning — fixed to the barrel surface
	// so the ribs visibly travel around it as it rolls (a smooth barrel shows no motion).
	v_ang = atan(p.x, p.z);
	// roll about local Y (the barrel axle as authored in the GLB). The per-row DIVERT yaw
	// is applied in the instance transform (about world up) so it's a true 45 deg turn.
	p = vec3(cs * p.x - ss * p.z, p.y, ss * p.x + cs * p.z);
	vec3 nn = NORMAL;
	nn = vec3(cs * nn.x - ss * nn.z, nn.y, ss * nn.x + cs * nn.z);
	VERTEX = p;
	NORMAL = nn;
}
void fragment() {
	// Alternating dark ribs around the barrel make the rolling visible.
	float band = smoothstep(0.42, 0.5, abs(fract(v_ang / TAU * 8.0) - 0.5) * 2.0);
	ALBEDO = mix(u_albedo, u_albedo * 0.4, band);
	ROUGHNESS = 0.45;
	METALLIC = 0.0;
}
"""
	_roller_shader = ShaderMaterial.new()
	_roller_shader.shader = sh
#endregion


#region Sensors --------------------------------------------------------------------
func _build_light_barrier() -> void:
	var ext: Dictionary = _deck_extent_local()
	_light_barrier = _ensure_area("_VRLightBarrier", _light_barrier, _on_lb_body_entered, _on_lb_body_exited)
	var col := _light_barrier.get_node("CollisionShape3D") as CollisionShape3D
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.03, 0.25, maxf(0.1, float(ext["max_z"]) - float(ext["min_z"])))
	col.shape = shape
	_light_barrier.position = Vector3(float(ext["min_x"]) + 0.05, float(ext["top_y"]) + 0.1,
			(float(ext["min_z"]) + float(ext["max_z"])) * 0.5)


func _build_deck_sensor() -> void:
	var ext: Dictionary = _deck_extent_local()
	_deck_sensor = _ensure_area("_VRDeckSensor", _deck_sensor, _on_deck_body_entered, _on_deck_body_exited)
	var col := _deck_sensor.get_node("CollisionShape3D") as CollisionShape3D
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(0.1, float(ext["max_x"]) - float(ext["min_x"])), 0.5,
			maxf(0.1, float(ext["max_z"]) - float(ext["min_z"])))
	col.shape = shape
	_deck_sensor.position = Vector3((float(ext["min_x"]) + float(ext["max_x"])) * 0.5,
			float(ext["top_y"]) + 0.22, (float(ext["min_z"]) + float(ext["max_z"])) * 0.5)


func _ensure_area(node_name: String, cached: Area3D, on_enter: Callable, on_exit: Callable) -> Area3D:
	var area: Area3D = cached
	if not is_instance_valid(area):
		area = get_node_or_null(node_name) as Area3D
	if not is_instance_valid(area):
		area = Area3D.new()
		area.name = node_name
		area.collision_mask = BOX_COLLISION_MASK
		area.monitoring = true
		add_child(area, false, Node.INTERNAL_MODE_FRONT)
		area.owner = self
		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		area.add_child(col)
		area.body_entered.connect(on_enter)
		area.body_exited.connect(on_exit)
	return area


func _on_lb_body_entered(b: Node) -> void:
	if not _lb_bodies.has(b):
		_lb_bodies.append(b)
	if b is RigidBody3D:
		_parcels[b] = _pick_divert()
		_lb_entry_x[b] = _local_x(b)   # leading edge at the barrier — start measuring length


func _on_lb_body_exited(b: Node) -> void:
	_lb_bodies.erase(b)
	# Tail cleared the infeed light barrier → the box is now FULLY on the deck, and the
	# distance its centre travelled across the barrier IS the box length.
	if b is RigidBody3D:
		if _lb_entry_x.has(b):
			_box_len[b] = maxf(0.05, absf(_local_x(b) - float(_lb_entry_x[b])))
			_lb_entry_x.erase(b)
		_fully_on[b] = true


func _on_deck_body_entered(b: Node) -> void:
	# Fallback latch if the parcel was dropped on without tripping the light barrier.
	if b is RigidBody3D and not _parcels.has(b):
		_parcels[b] = _pick_divert()
		_fully_on[b] = true   # placed straight onto the deck → already fully on


func _on_deck_body_exited(b: Node) -> void:
	if b is RigidBody3D:
		_parcels.erase(b)
		_fully_on.erase(b)
		_box_len.erase(b)
		_lb_entry_x.erase(b)


func _local_x(b: Node) -> float:
	return (global_transform.affine_inverse() * (b as Node3D).global_position).x
#endregion


#region Divert drive ---------------------------------------------------------------
func _physics_process(delta: float) -> void:
	super._physics_process(delta)   # belt base: leg footing poll
	if not Simulation.is_running():
		_tracked.clear()
		_auto_passing = {}
		_auto_last_detected = false
		_auto_primed = false
	# drop parcels that left the scene
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p):
			_parcels.erase(p)
			_fully_on.erase(p)
			_box_len.erase(p)
			_lb_entry_x.erase(p)
	var moving: bool = speed != 0.0 and Simulation.is_running() and not Simulation.is_paused()
	if not sensor.is_empty():
		_poll_auto_sensor()
		_advance_tracked(delta, moving)
	# Each row (section) diverts independently toward the command of the parcel over it.
	for ix: int in _section_bodies.size():
		var target: float = _section_target_angle(_section_x[ix]) if moving else 0.0
		if ix < _section_angle_cur.size():
			_section_angle_cur[ix] = move_toward(_section_angle_cur[ix], target, 240.0 * delta)
		var body: StaticBody3D = _section_bodies[ix]
		if not is_instance_valid(body):
			continue
		if not moving:
			body.constant_linear_velocity = Vector3.ZERO
			continue
		# Physics uses the INSTANT target (not the eased angle) so every row under the box
		# pushes the same direction at once — no ramp gradient that twists/zig-zags the box.
		var rad: float = deg_to_rad(target)
		var flow: Vector3 = body.global_transform.basis.x.normalized()
		body.constant_linear_velocity = (Basis(Vector3.UP, rad) * flow) * speed
	if _roller_shader != null:
		var spin: float = ROLLER_SPIN_SPEED if moving else 0.0
		# Default spins forward with flow; FLIP_SPIN reverses.
		_roller_shader.set_shader_parameter("u_speed", spin if FLIP_SPIN else -spin)
	_update_roller_yaws()
	if DEBUG:
		_dbg_frame += 1
		if _dbg_frame % 60 == 0:
			var n: Node = _resolve_auto_sensor()
			var det: Variant = "NO-NODE/PROP"
			if n != null and "detected" in n:
				det = n.get("detected")
			var maxang: float = 0.0
			for a: float in _section_angle_cur:
				maxang = maxf(maxang, absf(a))
			print("[VR %s] run=%s mov=%s sensorSet=%s det=%s d2deck=%.2f tracked=%d maxAng=%.0f comms=%s" % [
				name, Simulation.is_running(), moving, not sensor.is_empty(), str(det),
				_sensor_to_deck_dist, _tracked.size(), maxang, enable_comms])
			if _tracked.size() > 0:
				var t0: Dictionary = _tracked[0]
				var front: float = _deck_min_x + (float(t0["dist"]) - _sensor_to_deck_dist)
				print("   tracked[0]: cmd=%d dist=%.2f len=%.2f measured=%s front=%.2f deck=[%.2f..%.2f]" % [
					int(t0["cmd"]), float(t0["dist"]), float(t0.get("len", 0.0)),
					bool(t0.get("measured", false)), front, _deck_min_x, _deck_max_x])


## Yaw each row's barrels to its divert angle by rotating the instance transform about
## world up — a true 45 deg turn (base orientation ROLLER_ROTATION_DEG + the row's angle).
func _update_roller_yaws() -> void:
	if not is_instance_valid(_roller_mm_inst):
		return
	var mm: MultiMesh = _roller_mm_inst.multimesh
	if mm == null:
		return
	var idx: int = 0
	for ix: int in _section_angle_cur.size():
		var total_yaw: float = deg_to_rad(ROLLER_ROTATION_DEG + _section_angle_cur[ix])
		var yaw_basis: Basis = Basis(Vector3.UP, total_yaw).scaled(Vector3(_roller_rs, _roller_rs, _roller_rs))
		for iz: int in _grid_nz:
			if idx >= mm.instance_count or idx >= _roller_positions.size():
				return
			mm.set_instance_transform(idx, Transform3D(yaw_basis, _roller_positions[idx]) * _roller_xform)
			idx += 1


## Target divert angle (deg) for the section at local X. EVERY row under the box's
## footprint diverts (and holds until the box leaves it), PLUS a one-section margin both
## ahead (overshoot) and behind (undershoot) — so the sections actually under the box are
## never at the toggling band edge, which is what caused the zig-zag.
func _section_target_angle(rx: float) -> float:
	if not sensor.is_empty():
		for t: Dictionary in _tracked:
			if not bool(t.get("measured", false)):
				continue   # still crossing the sensor — length not known yet
			var blen: float = float(t.get("len", BOX_LENGTH))
			# Predicted leading edge from the sensor: it left the sensor at dist 0 and is
			# _sensor_to_deck_dist upstream of the infeed.
			var front: float = _deck_min_x + (float(t["dist"]) - _sensor_to_deck_dist)
			if front - blen < _deck_min_x:
				continue   # box tail hasn't cleared the infeed yet → not fully on
			var center: float = front - blen * 0.5
			if absf(rx - center) <= blen * 0.5 + _section_pitch:
				return _command_angle(int(t["cmd"]))
		return 0.0
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p) or not _fully_on.has(p):
			continue   # only divert a box once it is fully on the deck
		var reach2: float = float(_box_len.get(p, BOX_LENGTH)) * 0.5 + _section_pitch
		var plx: float = (global_transform.affine_inverse() * (p as Node3D).global_position).x
		if absf(rx - plx) <= reach2:
			return _command_angle(int(_parcels[p]))
	return 0.0


func _command_angle(d: int) -> float:
	if d == int(DivertDir.LEFT):
		return MAX_DIVERT_ANGLE
	if d == int(DivertDir.RIGHT):
		return -MAX_DIVERT_ANGLE
	return 0.0


#region Auto mode ------------------------------------------------------------------
func _resolve_auto_sensor() -> Node:
	if is_instance_valid(_auto_sensor_node):
		return _auto_sensor_node
	if sensor.is_empty():
		return null
	_auto_sensor_node = get_node_or_null(sensor)
	return _auto_sensor_node


## Watch the assigned sensor; on each rising edge of its `detected` flag, queue the next
## divert command and refresh the sensor->deck distance.
func _poll_auto_sensor() -> void:
	var node: Node = _resolve_auto_sensor()
	if node == null:
		return
	if not _section_x.is_empty():
		# Distance the box travels ALONG THE FLOW (local X) from the sensor to the infeed —
		# NOT the 3-D distance, since the sensor can be offset sideways/vertically.
		var sensor_local: Vector3 = global_transform.affine_inverse() * (node as Node3D).global_position
		_sensor_to_deck_dist = _deck_min_x - sensor_local.x
	# `detected` is the PHYSICAL beam state (true when blocked), independent of the sensor's
	# normally_closed setting — so it reads correctly for NO and NC sensors alike.
	var blocked: bool = false
	if "detected" in node:
		blocked = bool(node.get("detected"))
	elif "output" in node:
		blocked = bool(node.get("output"))
	if not _auto_primed:
		# Don't treat the first reading as an edge (e.g. a box already sitting in the beam).
		_auto_primed = true
		_auto_last_detected = blocked
		return
	if blocked and not _auto_last_detected:
		# Leading edge hit the sensor — start a box, begin measuring its length.
		var entry: Dictionary = {"cmd": _auto_next_command(), "dist": 0.0, "len": BOX_LENGTH, "measured": false}
		_tracked.append(entry)
		_auto_passing = entry
		if DEBUG:
			print("[VR %s] >>> BOX entered sensor (rising). cmd=%d  d2deck=%.2f" % [name, int(entry["cmd"]), _sensor_to_deck_dist])
	elif blocked and _auto_last_detected:
		# Box still in the beam — keep reading the PLC; it may set L/R a scan after the PE.
		if enable_comms and not _auto_passing.is_empty():
			var c: int = _read_comms_command()
			if c != int(DivertDir.STRAIGHT) and c != int(_auto_passing.get("cmd", 0)):
				_auto_passing["cmd"] = c
				if DEBUG:
					print("[VR %s]   PLC set destination=%d while box at sensor" % [name, c])
	elif not blocked and _auto_last_detected:
		# Trailing edge cleared the sensor — distance travelled meanwhile IS the box length.
		if not _auto_passing.is_empty():
			_auto_passing["len"] = maxf(0.05, float(_auto_passing["dist"]))
			_auto_passing["measured"] = true
			if DEBUG:
				print("[VR %s] <<< BOX cleared sensor (falling). len=%.3f" % [name, float(_auto_passing["len"])])
			_auto_passing = {}
	_auto_last_detected = blocked


## Advance each predicted box at the roller speed; drop those past the discharge end.
func _advance_tracked(delta: float, moving: bool) -> void:
	if moving:
		for t: Dictionary in _tracked:
			t["dist"] = float(t["dist"]) + speed * delta
	var keep: Array = []
	for t: Dictionary in _tracked:
		var blen: float = float(t.get("len", BOX_LENGTH))
		var front: float = _deck_min_x + (float(t["dist"]) - _sensor_to_deck_dist)
		# Keep diverting while ANY of the box is still on the deck — i.e. until its tail
		# (front - length) passes the discharge, so the remaining part keeps following it.
		if front - blen <= _deck_max_x:
			keep.append(t)
	_tracked = keep


## The destination latched for a box when the sensor blocks: PLC tags if comms are on
## (LEFT/RIGHT if set, else STRAIGHT), otherwise the cycling `auto_pattern`.
## Read the PLC destination tags right now: LEFT/RIGHT if set, else STRAIGHT.
func _read_comms_command() -> int:
	if _div_left_tag.is_ready() and _div_left_tag.read_bit():
		return int(DivertDir.LEFT)
	if _div_right_tag.is_ready() and _div_right_tag.read_bit():
		return int(DivertDir.RIGHT)
	return int(DivertDir.STRAIGHT)


func _auto_next_command() -> int:
	if enable_comms:
		var cmd: int = _read_comms_command()
		if DEBUG:
			print("[VR %s]     comms at entry: cmd=%d  L.ready=%s R.ready=%s  group='%s' L='%s' R='%s'" % [
				name, cmd, _div_left_tag.is_ready(), _div_right_tag.is_ready(),
				divert_tag_group_name, left_tag_name, right_tag_name])
		return cmd
	var order: Array[int]
	match auto_pattern:
		AutoPattern.LEFT_STRAIGHT:
			order = [int(DivertDir.LEFT), int(DivertDir.STRAIGHT)]
		AutoPattern.RIGHT_STRAIGHT:
			order = [int(DivertDir.RIGHT), int(DivertDir.STRAIGHT)]
		AutoPattern.LEFT_RIGHT:
			order = [int(DivertDir.LEFT), int(DivertDir.RIGHT)]
		_:
			order = [int(DivertDir.STRAIGHT), int(DivertDir.RIGHT), int(DivertDir.LEFT)]
	var cmd: int = order[_auto_seq % order.size()]
	_auto_seq += 1
	return cmd
#endregion


## Command latched onto a real box at the light barrier when NOT in auto mode — straight
## (manual divert/auto-sort were removed; diverting is driven by auto mode).
func _pick_divert() -> int:
	return int(DivertDir.STRAIGHT)
#endregion


#region Communications -------------------------------------------------------------
func _enter_tree() -> void:
	super._enter_tree()
	divert_tag_group_name = OIPCommsSetup.default_tag_group(divert_tag_group_name)


func _on_simulation_started() -> void:
	super._on_simulation_started()
	if enable_comms:
		_div_straight_tag.register(divert_tag_group_name, straight_tag_name, OIPComms.TAG_TYPE_BOOL)
		_div_left_tag.register(divert_tag_group_name, left_tag_name, OIPComms.TAG_TYPE_BOOL)
		_div_right_tag.register(divert_tag_group_name, right_tag_name, OIPComms.TAG_TYPE_BOOL)


func _tag_group_initialized(tag_group_name_param: String) -> void:
	super._tag_group_initialized(tag_group_name_param)
	_div_straight_tag.on_group_initialized(tag_group_name_param)
	_div_left_tag.on_group_initialized(tag_group_name_param)
	_div_right_tag.on_group_initialized(tag_group_name_param)


func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	if OIPCommsSetup.validate_tag_property(property, "divert_tag_group_name", "divert_tag_groups", "straight_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "divert_tag_group_name", "divert_tag_groups", "left_tag_name"):
		return
	OIPCommsSetup.validate_tag_property(property, "divert_tag_group_name", "divert_tag_groups", "right_tag_name")
#endregion


#region Preview --------------------------------------------------------------------
func _get_custom_preview_node() -> Node3D:
	var preview_scene := load("res://parts/VR.tscn") as PackedScene
	var preview_node := preview_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) as Node3D
	preview_node.set_meta("is_preview", true)
	_disable_collisions_recursive(preview_node)
	return preview_node
#endregion
