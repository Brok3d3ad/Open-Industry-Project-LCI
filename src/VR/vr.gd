@tool
class_name VR
extends BeltConveyor

## Pivoting-roller sorter built on the `BeltConveyor` base.
##
## Inherits the belt conveyor's legs, side guards, frame rails, resize handles and
## snapping unchanged. It only SWAPS THE SURFACE: the flat belt mesh is hidden and a
## procedural pivoting-roller field (tiled from res://assets/3DModels/VR/VR_Roller.glb)
## is laid over the deck instead. The belt's own collision body (`RunBody_*`) is reused
## as the transport surface — every physics frame its `constant_linear_velocity` is
## rotated about vertical by the divert angle, so a box on the deck is driven STRAIGHT,
## LEFT or RIGHT (±[member divert_angle]) like the real pivoting roller units.
##
## Drive it with the inherited `speed` (0 = stopped). The divert direction comes from the
## PLC destination tags, latched while the assigned sensor blocks (no tag set = STRAIGHT).
## The latched command is handed to the physical box when it crosses the infeed light
## barrier, and the divert wave follows the REAL box from there — prediction can't drift.
## Keep the conveyor STRAIGHT (single segment) — the divert assumes a straight deck.

enum DivertDir { STRAIGHT, LEFT, RIGHT }

const GLB_PATH: String = "res://assets/3DModels/VR/VR_Roller.glb"
const BOX_COLLISION_MASK: int = 8   # boxes ride on physics layer 4 (value 8)
const BOX_LENGTH: float = 0.3       # fallback parcel length (no sensor / unmeasured parcel latch)
const PANEL_NATIVE: float = 0.40    # GLB panel tile is 0.40 m square (native size before scaling)
const DECK_THICKNESS: float = 0.12  # solid deck slab depth (blue side-guard material)

#region Config ---------------------------------------------------------------------
# Fixed tuning — hardcoded, intentionally NOT exposed in the inspector.
const ROLLER_SCALE: float = 1.5          # barrel size as a fraction of its cell
const HOLE_CLEARANCE: float = 1.3        # dark hole radius vs barrel radius
const SURFACE_FRICTION: float = 1.4      # deck grip on the diagonal divert
const FLIP_SPIN: bool = false            # reverse the roller roll direction
const ROLLER_HEIGHT_OFFSET: float = 0.0  # vertical nudge of the roller field
const SHOW_PANELS: bool = false          # GLB white tiles on top of the deck
const BODY_DEPTH: float = 0.45           # solid deck slab depth toward the legs
const MAX_YAW_RATE_DEG: float = 240.0    # box yaw rate ceiling while curving into the divert
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
## Roller pivot angle (degrees) when diverting LEFT or RIGHT.
@export_range(0.0, 45.0, 0.5, "suffix:°") var divert_angle: float = 35.0
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
var _curve_yaw: Dictionary = {}      # RigidBody3D -> conveyor-local heading at divert start
var _lb_entry_x: Dictionary = {}     # RigidBody3D -> local X when it tripped the light barrier
var _sort_counter: int = 0
# Per-section (per row of rollers) divert state — each row diverts independently.
var _section_bodies: Array[StaticBody3D] = []  # one transport body per row
var _section_x: Array[float] = []              # local X of each row centre
var _section_angle_cur: PackedFloat32Array = PackedFloat32Array()  # smoothed angle (deg) per row
var _grid_nz: int = 1                           # rollers per row (idx -> row mapping)
var _section_angle_pushed: PackedFloat32Array = PackedFloat32Array()  # last yaw uploaded to the MultiMesh per row
var _section_vel_applied: PackedVector3Array = PackedVector3Array()   # last constant velocity written per row
var _spin_pushed: float = INF                   # last u_speed uniform uploaded
var _idle_cleaned: bool = false                 # one-shot idle reset latch
var _roller_positions: Array[Vector3] = []      # per-roller local position (for live yaw)
var _roller_rs: float = 1.0                      # roller instance scale
var _section_pitch: float = 0.09                 # one section length along flow (the divert unit)
var _deck_min_x: float = 0.0                    # local X of the deck infeed edge
var _deck_max_x: float = 0.0                    # local X of the deck discharge edge
# Sensor tracking (assigned photo eye -> PLC-commanded divert)
var _sensor_node: Node = null
var _sensor_last_detected: bool = false          # edge tracker on the sensor (blocked state)
var _sensor_primed: bool = false                 # first poll after sim start primes, no edge
## FIFO of commands latched at the PE, one per box, waiting for their box to
## physically arrive at the infeed light barrier (where the head entry is claimed).
var _pending_cmds: Array = []
## The entry still owning the command channel: the box in the beam, or the one that
## most recently cleared (until the grace expires). Late L/R tag values land here —
## and follow through to the physical parcel if the entry was already claimed.
var _grace_entry: Dictionary = {}
var _divert_spans: Array = []                    # per-frame [{x, reach, ang}] of fully-on parcels
var _divert_poll_ms: int = 100                   # divert tag group poll interval (ms)
var _cmd_grace_ms: int = 300                     # post-PE window a late command still counts (ms)
var _poll_warned: bool = false                   # one-shot poll-rate-vs-PE-time warning latch
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
	# Change-gate caches: zeros match the freshly built state (yaw-0 field, stationary bodies).
	_section_angle_pushed = PackedFloat32Array()
	_section_angle_pushed.resize(nx)
	_section_vel_applied = PackedVector3Array()
	_section_vel_applied.resize(nx)


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
	# Slab top just below the panel bottom so the holes become recesses (no z-fight).
	var deck_top: float = top_y - 0.05 + ROLLER_HEIGHT_OFFSET
	# Depth tied to the belt `height` so the slab BOTTOM lands at the belt bottom where the legs
	# attach — keeps the deck, body and legs aligned instead of a hardcoded depth that can punch
	# past the legs into the floor when `height` differs.
	var belt_bottom: float = top_y - height
	var depth: float = maxf(0.05, deck_top - belt_bottom)
	var bm := BoxMesh.new()
	bm.size = Vector3(maxf(0.05, max_x - min_x), depth, maxf(0.05, max_z - min_z))
	fill.mesh = bm
	fill.set_surface_override_material(0, SideGuardMesh.create_material())
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
		_parcels[b] = _claim_pending_cmd(b as RigidBody3D)
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
		_parcels[b] = int(DivertDir.STRAIGHT)
		_fully_on[b] = true   # placed straight onto the deck → already fully on


func _on_deck_body_exited(b: Node) -> void:
	if b is RigidBody3D:
		_parcels.erase(b)
		_fully_on.erase(b)
		_box_len.erase(b)
		_lb_entry_x.erase(b)
		_curve_yaw.erase(b)


func _local_x(b: Node) -> float:
	return (global_transform.affine_inverse() * (b as Node3D).global_position).x
#endregion


#region Divert drive ---------------------------------------------------------------
func _physics_process(delta: float) -> void:
	super._physics_process(delta)   # belt base: leg footing poll
	if not Simulation.is_running():
		# One-shot idle reset, then dormant. The old path kept re-uploading every
		# roller transform and section velocity at 120 Hz while merely EDITING —
		# a visible editor drag once a few VRs were in the scene.
		if _idle_cleaned:
			return
		_idle_cleaned = true
		_pending_cmds.clear()
		_grace_entry = {}
		_divert_spans.clear()
		_sensor_last_detected = false
		_sensor_primed = false
		_curve_yaw.clear()
		for ix: int in _section_angle_cur.size():
			_section_angle_cur[ix] = 0.0
		for ix: int in _section_bodies.size():
			var body: StaticBody3D = _section_bodies[ix]
			if is_instance_valid(body):
				body.constant_linear_velocity = Vector3.ZERO
			if ix < _section_vel_applied.size():
				_section_vel_applied[ix] = Vector3.ZERO
		_update_roller_yaws()
		_set_roller_spin(0.0)
		return
	_idle_cleaned = false
	# drop parcels that left the scene
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p):
			_parcels.erase(p)
			_fully_on.erase(p)
			_box_len.erase(p)
			_lb_entry_x.erase(p)
			_curve_yaw.erase(p)
	var moving: bool = speed != 0.0 and not Simulation.is_paused()
	if not sensor.is_empty():
		_poll_sensor()
		_advance_pending(delta, moving)
	_rebuild_divert_spans()
	# Each row (section) diverts independently toward the command of the parcel over it.
	for ix: int in _section_bodies.size():
		var target: float = _section_target_angle(_section_x[ix]) if moving else 0.0
		if ix < _section_angle_cur.size():
			_section_angle_cur[ix] = move_toward(_section_angle_cur[ix], target, 240.0 * delta)
		var body: StaticBody3D = _section_bodies[ix]
		if not is_instance_valid(body):
			continue
		# Physics uses the INSTANT target (not the eased angle) so every row under the box
		# pushes the same direction at once — no ramp gradient that twists/zig-zags the box.
		var desired: Vector3 = Vector3.ZERO
		if moving:
			var rad: float = deg_to_rad(target)
			var flow: Vector3 = body.global_transform.basis.x.normalized()
			desired = (Basis(Vector3.UP, rad) * flow) * speed
		# Write the body velocity only on change — otherwise it's `sections` redundant
		# physics-server writes every tick.
		if ix < _section_vel_applied.size():
			if desired.is_equal_approx(_section_vel_applied[ix]):
				continue
			_section_vel_applied[ix] = desired
		body.constant_linear_velocity = desired
	_curve_parcels(delta, moving)
	_set_roller_spin(ROLLER_SPIN_SPEED if moving else 0.0)
	_update_roller_yaws()


## Yaw each row's barrels to its divert angle by rotating the instance transform about
## world up — a true 45 deg turn (base orientation ROLLER_ROTATION_DEG + the row's angle).
## Rows whose eased angle hasn't moved are skipped — re-uploading every instance
## transform per tick was the dominant per-frame cost of an idle VR.
func _update_roller_yaws() -> void:
	if not is_instance_valid(_roller_mm_inst):
		return
	var mm: MultiMesh = _roller_mm_inst.multimesh
	if mm == null:
		return
	if _section_angle_pushed.size() != _section_angle_cur.size():
		_section_angle_pushed.resize(_section_angle_cur.size())
		_section_angle_pushed.fill(1.0e9)   # size changed mid-flight — force a full push
	var idx: int = 0
	for ix: int in _section_angle_cur.size():
		var ang: float = _section_angle_cur[ix]
		if absf(ang - _section_angle_pushed[ix]) < 0.01:
			idx += _grid_nz
			continue
		_section_angle_pushed[ix] = ang
		var total_yaw: float = deg_to_rad(ROLLER_ROTATION_DEG + ang)
		var yaw_basis: Basis = Basis(Vector3.UP, total_yaw).scaled(Vector3(_roller_rs, _roller_rs, _roller_rs))
		for iz: int in _grid_nz:
			if idx >= mm.instance_count or idx >= _roller_positions.size():
				return
			mm.set_instance_transform(idx, Transform3D(yaw_basis, _roller_positions[idx]) * _roller_xform)
			idx += 1


## Upload the spin uniform only when it changes (it's constant while running).
func _set_roller_spin(spin: float) -> void:
	if _roller_shader == null:
		return
	var signed_spin: float = spin if FLIP_SPIN else -spin
	if signed_spin == _spin_pushed:
		return
	_spin_pushed = signed_spin
	_roller_shader.set_shader_parameter("u_speed", signed_spin)


## Per-frame cache of every fully-on parcel's divert span: ACTUAL local X, half-length
## reach (+ one section margin) and command angle. Built once per physics frame so the
## per-section angle lookup below doesn't repeat an affine_inverse per parcel per row.
func _rebuild_divert_spans() -> void:
	_divert_spans.clear()
	if _parcels.is_empty():
		return
	var inv: Transform3D = global_transform.affine_inverse()
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p) or not _fully_on.has(p):
			continue   # only divert a box once it is fully on the deck
		_divert_spans.append({
			"x": (inv * (p as Node3D).global_position).x,
			"reach": float(_box_len.get(p, BOX_LENGTH)) * 0.5 + _section_pitch,
			"ang": _command_angle(int(_parcels[p])),
		})


## Target divert angle (deg) for the section at local X. EVERY row under the box's
## footprint diverts (and holds until the box leaves it), PLUS a one-section margin both
## ahead (overshoot) and behind (undershoot) — so the sections actually under the box are
## never at the toggling band edge, which is what caused the zig-zag. Driven by the
## PHYSICAL box positions (latched at the light barrier), so the wave can't drift.
func _section_target_angle(rx: float) -> float:
	for s: Dictionary in _divert_spans:
		if absf(rx - float(s["x"])) <= float(s["reach"]):
			return float(s["ang"])
	return 0.0


func _command_angle(d: int) -> float:
	if d == int(DivertDir.LEFT):
		return divert_angle
	if d == int(DivertDir.RIGHT):
		return -divert_angle
	return 0.0


## Yaw each diverting parcel toward its divert direction so it visibly CURVES into the
## takeaway (like a real pivoting-roller unit skews the box) instead of translating
## sideways still facing down the line. CLOSED LOOP: the rotation achieved so far is
## MEASURED from the body's actual heading (vs its heading when the divert began), so
## solver losses — roller friction, contact impulses — can't shortchange the turn; the
## drive keeps steering until the box really sits at the full roller angle. The rate is
## paced against the time left to the discharge edge, so the turn completes exactly as
## the box leaves the deck, on any deck length or belt speed.
func _curve_parcels(delta: float, moving: bool) -> void:
	if not moving or delta <= 0.0:
		return
	var inv: Transform3D = global_transform.affine_inverse()
	var inv_basis: Basis = global_transform.basis.inverse()
	var flow: Vector3 = global_transform.basis.x.normalized()
	var rate_cap: float = deg_to_rad(MAX_YAW_RATE_DEG)
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p) or not _fully_on.has(p):
			continue
		var body := p as RigidBody3D
		if body == null or body.freeze or body.sleeping:
			continue
		var ang: float = _command_angle(int(_parcels[body]))
		if ang == 0.0:
			_curve_yaw.erase(body)   # divert finished (or not begun) — re-arm for the next one
			continue
		# Current heading in conveyor space, flattened to the deck plane.
		var heading: Vector3 = inv_basis * body.global_transform.basis.x
		heading.y = 0.0
		if heading.length_squared() < 1e-6:
			continue   # degenerate (box tipped on end) — skip this frame
		heading = heading.normalized()
		if not _curve_yaw.has(body):
			_curve_yaw[body] = heading   # reference heading at divert start
		var start_heading: Vector3 = _curve_yaw[body]
		# Yaw actually achieved since the divert began (signed about UP, + = LEFT) —
		# read back from the body, not integrated from what we commanded.
		var turned: float = atan2(start_heading.cross(heading).y, start_heading.dot(heading))
		var remaining: float = deg_to_rad(ang) - turned
		if absf(remaining) < 0.01:
			continue   # box really sits at the full divert angle
		# Time left on the deck at the box's ACTUAL forward speed (floored at a quarter of
		# the belt speed so a briefly-jammed box can't demand an infinite yaw rate).
		var dist_left: float = maxf(_deck_max_x - (inv * body.global_position).x, 0.0)
		var fwd: float = maxf(flow.dot(body.linear_velocity), absf(speed) * 0.25)
		var time_left: float = maxf(dist_left / maxf(fwd, 0.01), delta)
		# Same sign convention as the section velocities (Basis about UP): +angle = LEFT.
		var yaw_vel: float = clampf(remaining / time_left, -rate_cap, rate_cap)
		var w: Vector3 = body.angular_velocity
		w.y = yaw_vel
		body.angular_velocity = w
#endregion


#region Sensor tracking ------------------------------------------------------------
func _resolve_sensor() -> Node:
	if is_instance_valid(_sensor_node):
		return _sensor_node
	if sensor.is_empty():
		return null
	_sensor_node = get_node_or_null(sensor)
	return _sensor_node


## Watch the assigned sensor; on each rising edge of its `detected` flag, queue the next
## divert command and refresh the sensor->deck distance.
func _poll_sensor() -> void:
	var node: Node = _resolve_sensor()
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
	if not _sensor_primed:
		# Don't treat the first reading as an edge (e.g. a box already sitting in the beam).
		_sensor_primed = true
		_sensor_last_detected = blocked
		return
	if blocked and not _sensor_last_detected:
		# Leading edge hit the sensor — queue a command slot for this box, latched with
		# whatever tag is high right now (nothing set = STRAIGHT, may still update below).
		var cmd: int = _read_comms_command() if enable_comms else int(DivertDir.STRAIGHT)
		var entry: Dictionary = {"cmd": cmd, "dist": 0.0, "in_beam": true,
				"enter_ms": Time.get_ticks_msec(), "cleared_ms": 0, "body": null}
		_pending_cmds.append(entry)
		_grace_entry = entry
	elif not blocked and _sensor_last_detected:
		# Trailing edge cleared the sensor. The command channel stays open for the grace
		# window (one poll interval + margin), handled in _update_grace_command.
		if not _grace_entry.is_empty() and bool(_grace_entry.get("in_beam", false)):
			_grace_entry["in_beam"] = false
			_grace_entry["cleared_ms"] = Time.get_ticks_msec()
			# A box that blocks the PE for less than one comms poll can carry a command
			# the sim never sees — that's a configuration fault, make it loud.
			var blocked_ms: int = int(_grace_entry["cleared_ms"]) - int(_grace_entry["enter_ms"])
			if enable_comms and blocked_ms < _divert_poll_ms and not _poll_warned:
				_poll_warned = true
				push_warning("VR %s: box blocked the PE for %d ms but tag group \"%s\" polls every %d ms — divert commands can be missed. Slow the line, lengthen the PE gap, or poll faster." % [
						name, blocked_ms, divert_tag_group_name, _divert_poll_ms])
	_sensor_last_detected = blocked
	_update_grace_command()


## While the box blocks the PE — and for the grace window after it clears — keep
## reading the L/R tags and apply what they say to that box, wherever it is by now
## (still queued, or already latched onto its physical parcel). In the beam the
## last non-straight value wins (the PLC may revise); after clearing, only a box
## still uncommanded accepts a late value, so a held tag can't re-command.
func _update_grace_command() -> void:
	if not enable_comms or _grace_entry.is_empty():
		return
	var in_beam: bool = bool(_grace_entry.get("in_beam", false))
	if not in_beam and Time.get_ticks_msec() - int(_grace_entry["cleared_ms"]) > _cmd_grace_ms:
		_grace_entry = {}
		return
	var cur: int = int(_grace_entry.get("cmd", 0))
	if not in_beam and cur != int(DivertDir.STRAIGHT):
		return
	var c: int = _read_comms_command()
	if c == int(DivertDir.STRAIGHT) or c == cur:
		return
	_grace_entry["cmd"] = c
	# Already handed to a physical box (short sensor->deck run) — update the parcel too.
	var body: Variant = _grace_entry.get("body")
	if body != null and is_instance_valid(body) and _parcels.has(body):
		_parcels[body] = c


## Hand the oldest queued PE command to the box that just physically crossed the
## infeed light barrier. From here the divert wave follows the REAL body. FIFO is
## safe because the conveyor between the PE and the deck preserves order.
func _claim_pending_cmd(b: RigidBody3D) -> int:
	if _pending_cmds.is_empty():
		return int(DivertDir.STRAIGHT)
	var entry: Dictionary = _pending_cmds.pop_front()
	entry["body"] = b
	return int(entry["cmd"])


## Advance each queued command at the roller speed (an upper bound on the real box's
## progress) and expire entries whose box never reached the deck — e.g. picked off the
## line between the PE and the infeed — so a stale command can't hit the wrong box.
func _advance_pending(delta: float, moving: bool) -> void:
	if not moving:
		return
	var expire_at: float = _sensor_to_deck_dist * 2.0 + 1.0
	var keep: Array = []
	for t: Dictionary in _pending_cmds:
		t["dist"] = float(t["dist"]) + absf(speed) * delta
		if bool(t.get("in_beam", false)) or float(t["dist"]) <= expire_at:
			keep.append(t)
	_pending_cmds = keep


## Read the PLC destination tags right now: LEFT/RIGHT if set, else STRAIGHT.
func _read_comms_command() -> int:
	if _div_left_tag.is_ready() and _div_left_tag.read_bit():
		return int(DivertDir.LEFT)
	if _div_right_tag.is_ready() and _div_right_tag.read_bit():
		return int(DivertDir.RIGHT)
	return int(DivertDir.STRAIGHT)
#endregion


#region Communications -------------------------------------------------------------
func _enter_tree() -> void:
	super._enter_tree()
	divert_tag_group_name = OIPCommsSetup.default_tag_group(divert_tag_group_name)


## Poll interval (ms) of the divert tag group, from the same config the comms service
## registers groups from. Sizes the command grace window and the too-fast-PE warning.
func _divert_group_poll_ms() -> int:
	var config := ConfigFile.new()
	if config.load("res://oip_data/tag_groups.cfg") != OK:
		return 100
	var group_count: int = config.get_value("info", "group_count", 0)
	for i: int in range(group_count):
		var section: String = "group_" + str(i)
		if str(config.get_value(section, "name", "")) == divert_tag_group_name:
			return maxi(10, int(str(config.get_value(section, "polling_rate", "100"))))
	return 100


func _on_simulation_started() -> void:
	super._on_simulation_started()
	_poll_warned = false
	if enable_comms:
		_divert_poll_ms = _divert_group_poll_ms()
		# One poll means a command written during the PE block can land one poll late;
		# two polls plus margin catches it without bleeding onto the next box.
		_cmd_grace_ms = maxi(300, _divert_poll_ms * 2)
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
