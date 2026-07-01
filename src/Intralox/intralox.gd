@tool
class_name Intralox
extends BeltConveyor

## Intralox ARB-style modular-belt conveyor, built on the `BeltConveyor` base like `VR`.
##
## Inherits the belt conveyor's legs, side guards, frame rails, transport collision, resize
## handles and snapping. It SWAPS THE SURFACE: the flat belt mesh is hidden and the ARB module
## (res://assets/3DModels/ARB/ARB_Section.glb — a 6 in / 0.1524 m pitch, 3 ft 7 in / 1.0922 m
## wide module) is tiled along the deck. Each module is one SECTION.
##
## The module's rollers (the RubberRoller parts) lie along the flow, so spinning them about
## their axle drives the surface LEFT or RIGHT — the ARB divert. Every roller in a section rolls
## together. [member showcase] alternates sections LEFT / RIGHT to demonstrate it. The belt's own
## collision still drives parcels straight at the inherited `speed`. No comms.

const GLB_PATH: String = "res://assets/3DModels/ARB/ARB_Section.glb"
const SECTION_PITCH: float = 0.1524   # 6 in — one module / section along the flow
const SECTION_WIDTH: float = 1.0922   # 3 ft 7 in — module width
const SECTION_GAP: float = 0.03       # gap carved out of each section (included in the 6 in)
const ROLLER_MAT: String = "RubberRoller"
const DIVERT_ANGLE: float = 90.0      # angle each active section pushes boxes (90 = full cross-belt)
const SURFACE_FRICTION: float = 1.4   # per-section transport-body grip

## Number of 6 in modules (sections) along the belt. Setting this resizes the length; resizing
## the length updates this back.
@export_range(1, 400, 1) var sections: int = 12:
	set(value):
		value = maxi(1, value)
		if value == sections:
			return
		sections = value
		if is_node_ready() and not _syncing:
			_set_length_from_sections()
## Showcase: alternate sections roll LEFT / RIGHT to demo the divert.
@export var showcase: bool = false:
	set(value):
		showcase = value
		_transport_dirty = true
		_refresh_roller_colors()

var _deck_mesh: ArrayMesh = null
var _roller_mesh: Mesh = null
var _roller_xforms: Array[Transform3D] = []   # one per roller within a module (corrected space)
var _roller_shader: ShaderMaterial = null
var _nx: int = 1                              # current section count actually built
var _syncing: bool = false                    # guards the sections <-> length sync
var _section_bodies: Array[StaticBody3D] = [] # one transport body per section (independent divert)
var _section_vel: PackedVector3Array = PackedVector3Array()  # last velocity pushed to each section body
# Section velocities only change when speed, run-state or a divert command changes — when nothing
# changed we skip the whole per-section loop (the biggest physics-thread cost with 400 sections).
var _transport_dirty: bool = true
var _last_moving: bool = false
var _last_speed: float = 0.0
var _seg: float = SECTION_PITCH               # current per-section pitch
# The modules are tiled around a belt LOOP (top run -> discharge pulley -> bottom -> infeed pulley)
# so the ARB IS the belt and wraps like a real conveyor. One Node3D per module, animated each frame.
# All modules are drawn by THREE shared MultiMeshes (deck / gap / rollers) instead of one node per
# module — hundreds of sections became hundreds of draw calls + node updates; this collapses it to 3
# draw calls. Per-instance transforms are refreshed each frame; the roller MultiMesh carries u_dir as
# per-instance CUSTOM data so a single shared shader colours idle vs diverting sections.
var _deck_mmi: MultiMeshInstance3D = null
var _gap_mmi: MultiMeshInstance3D = null
var _roller_mmi: MultiMeshInstance3D = null
var _roller_local: Array[Transform3D] = []    # per-roller local transform within a module
var _rollers_per_mod: int = 0
var _deck_scale_xf: Transform3D = Transform3D.IDENTITY
var _gap_offset_xf: Transform3D = Transform3D.IDENTITY
var _n_loop: int = 0                           # module count around the loop
var _module_arc: PackedFloat32Array = PackedFloat32Array()  # base arc-length of each module
var _module_dir: PackedFloat32Array = PackedFloat32Array()  # last u_dir set on each module (skip redundant sets)
var _gap_mesh: Mesh = null                    # grey strip that fills each section gap
var _gap_mat: StandardMaterial3D = null
var _loop_len: float = 0.0
var _pulley_r: float = 0.1                     # end-pulley radius = height/2 (matches belt mesh)
var _top_len: float = 0.0                      # top-run length (= deck length)
var _loop_min_x: float = 0.0
var _loop_max_x: float = 0.0
var _loop_top_y: float = 0.0
var _loop_cz: float = 0.0


## Drag-from-dock preview: show the ARB sorter, not the inherited belt conveyor (the base loads
## BeltConveyor.tscn, so Intralox previewed as a plain belt and was hard to pick after dropping).
func _get_custom_preview_node() -> Node3D:
	var preview_scene := load("res://parts/Intralox.tscn") as PackedScene
	if preview_scene == null:
		return super._get_custom_preview_node()
	var preview_node := preview_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) as Node3D
	preview_node.set_meta("is_preview", true)
	_disable_collisions_recursive(preview_node)
	return preview_node


## Let the belt base build path / bodies / frame / guards / legs, then swap the surface.
func _rebuild() -> void:
	super._rebuild()
	if not is_inside_tree():
		return
	_neutralize_belt_bodies()               # per-section bodies become the riding surface
	if is_instance_valid(_mesh_instance):
		_mesh_instance.visible = false      # the ARB modules ARE the surface; hide the smooth belt
	_build_section_field()


func _set_length_from_sections() -> void:
	if segments.is_empty():
		return
	segments[0].length = float(sections) * SECTION_PITCH
	_request_rebuild()


func _build_section_field() -> void:
	if _deck_mesh == null:
		_bake()
	if _deck_mesh == null:
		return
	var ext: Dictionary = _deck_extent_local()
	var min_x: float = float(ext["min_x"])
	var max_x: float = float(ext["max_x"])
	var min_z: float = float(ext["min_z"])
	var max_z: float = float(ext["max_z"])
	var top_y: float = float(ext["top_y"])
	# Anchor the flat-top X span to the PATH (the collision can run a touch long, which pushed the
	# wrap past the frame). The belt mesh builds its pulleys from these same end transforms, so the
	# ARB wrap now lands exactly where the belt mesh's did — flush with the frame / side guards.
	if _path != null and _path.top_surface_length > 0.01:
		var pe0: float = _path.start_transform().origin.x
		var pe1: float = _path.end_transform().origin.x
		min_x = minf(pe0, pe1)
		max_x = maxf(pe0, pe1)
	var deck_l: float = maxf(0.01, max_x - min_x)
	var deck_w: float = maxf(0.01, max_z - min_z)
	var nx: int = maxi(1, roundi(deck_l / SECTION_PITCH))
	_nx = nx
	if nx != sections:                          # resize -> update the section count back
		_syncing = true
		sections = nx
		_syncing = false
	var seg: float = deck_l / float(nx)
	var module_len: float = maxf(0.02, seg - SECTION_GAP)
	var sx: float = module_len / SECTION_PITCH
	var sz: float = deck_w / SECTION_WIDTH
	var cz: float = (min_z + max_z) * 0.5

	# Loop geometry — the same wrap the belt mesh uses: pulley radius = height/2, loop =
	# top run + discharge arc + bottom run + infeed arc.
	_seg = seg
	_top_len = deck_l
	# Same end pulleys as the belt conveyor: radius = height/2, so the wrap reaches exactly the
	# frame-rail / side-guard ends (which the base also extends by height/2 over the pulleys).
	_pulley_r = maxf(0.02, height * 0.5)
	_loop_len = 2.0 * deck_l + 2.0 * PI * _pulley_r
	_loop_min_x = min_x
	_loop_max_x = max_x
	_loop_top_y = top_y
	_loop_cz = cz

	# Per-roller local transform within a module (scaled the same as the deck). Reused for every
	# module's roller instances in the single shared roller MultiMesh.
	_make_roller_shader()
	_roller_local.clear()
	if _roller_mesh != null:
		for rt: Transform3D in _roller_xforms:
			var p: Vector3 = rt.origin
			# Shrink the roller length (its local-Y axle = the flow) by sx, like the deck.
			var rb: Basis = rt.basis * Basis.IDENTITY.scaled(Vector3(1.0, sx, 1.0))
			_roller_local.append(Transform3D(rb, Vector3(p.x * sx, p.y, p.z * sz)))
	_rollers_per_mod = _roller_local.size()

	# Fill each section gap with a flat grey strip so there's no see-through slot between sections.
	var gap: float = maxf(0.005, seg - module_len)
	var fill := BoxMesh.new()
	fill.size = Vector3(gap, 0.006, deck_w)
	_gap_mesh = fill
	if _gap_mat == null:
		_gap_mat = StandardMaterial3D.new()
		_gap_mat.albedo_color = Color(0.5, 0.5, 0.52)
		_gap_mat.roughness = 0.7

	# One module every `seg` all the way around the loop, all drawn by three shared MultiMeshes.
	var n_loop: int = maxi(1, ceili(_loop_len / seg))
	_n_loop = n_loop
	_deck_scale_xf = Transform3D(Basis.IDENTITY.scaled(Vector3(sx, 1.0, sz)), Vector3.ZERO)
	_gap_offset_xf = Transform3D(Basis(), Vector3(seg * 0.5, -0.003, 0.0))   # leading seam, flush
	_clear_module_nodes()
	_module_arc = PackedFloat32Array()
	_module_arc.resize(n_loop)
	for i: int in n_loop:
		_module_arc[i] = float(i) * seg
	_module_dir = PackedFloat32Array()
	_module_dir.resize(n_loop)
	_module_dir.fill(2.0)                        # sentinel (never a real dir) so the first update applies
	_build_module_multimeshes()

	_build_section_bodies(min_x, deck_l, nx, min_z, max_z, top_y)
	var old_fill := get_node_or_null("_ARBDeckFill")
	if old_fill != null:
		old_fill.queue_free()                   # hollow: no solid deck body
	_place_modules()


## Create/refresh the three shared MultiMeshInstances that draw every module (deck / gap / rollers).
func _build_module_multimeshes() -> void:
	_deck_mmi = _ensure_mmi("_ARBDeckMM", _deck_mmi)
	_deck_mmi.material_override = null                    # deck uses the ARB mesh's own material
	_deck_mmi.multimesh = _make_mm(_deck_mesh, _n_loop, false)
	_gap_mmi = _ensure_mmi("_ARBGapMM", _gap_mmi)
	_gap_mmi.material_override = _gap_mat
	_gap_mmi.multimesh = _make_mm(_gap_mesh, _n_loop, false)
	_roller_mmi = _ensure_mmi("_ARBRollerMM", _roller_mmi)
	if _roller_mesh != null and _rollers_per_mod > 0:
		_roller_mmi.material_override = _roller_shader    # one shared shader; u_dir is per-instance
		_roller_mmi.multimesh = _make_mm(_roller_mesh, _n_loop * _rollers_per_mod, true)
	else:
		_roller_mmi.multimesh = null


func _make_mm(mesh: Mesh, count: int, custom: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = count
	return mm


func _ensure_mmi(node_name: String, cached: MultiMeshInstance3D) -> MultiMeshInstance3D:
	var mmi: MultiMeshInstance3D = cached
	if not is_instance_valid(mmi):
		mmi = get_node_or_null(node_name) as MultiMeshInstance3D
	if not is_instance_valid(mmi):
		mmi = MultiMeshInstance3D.new()
		mmi.name = node_name
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi, false, Node.INTERNAL_MODE_FRONT)
		mmi.owner = self                                 # owner=self -> the editor can pick the ARB
	return mmi


## Remove leftover per-module nodes from the older (one-node-per-module) build. The shared MultiMesh
## instances are reused across rebuilds, so they're not freed here.
func _clear_module_nodes() -> void:
	for child: Node in get_children(true):
		var nm: String = String(child.name)
		if nm.begins_with("_ARBModule_") or nm == "_ARBDeck" or nm == "_ARBRollers" or nm == "_ARBDeckFill":
			child.queue_free()


## Position + orientation of a module centred at loop arc-length `d` (0 = top-run infeed). The
## module rides the surface with its +Y facing outward, so it stays flat on the runs and rotates
## around the end pulleys.
func _loop_xform(d: float) -> Transform3D:
	var r: float = _pulley_r
	var arc: float = PI * r
	var tangent: Vector3
	var normal: Vector3
	var pos: Vector3
	if d < _top_len:
		pos = Vector3(_loop_min_x + d, _loop_top_y, _loop_cz)
		tangent = Vector3(1.0, 0.0, 0.0)
		normal = Vector3(0.0, 1.0, 0.0)
	elif d < _top_len + arc:
		var th: float = (d - _top_len) / r
		pos = Vector3(_loop_max_x + r * sin(th), (_loop_top_y - r) + r * cos(th), _loop_cz)
		tangent = Vector3(cos(th), -sin(th), 0.0)
		normal = Vector3(sin(th), cos(th), 0.0)
	elif d < 2.0 * _top_len + arc:
		var dd: float = d - (_top_len + arc)
		pos = Vector3(_loop_max_x - dd, _loop_top_y - 2.0 * r, _loop_cz)
		tangent = Vector3(-1.0, 0.0, 0.0)
		normal = Vector3(0.0, -1.0, 0.0)
	else:
		var th2: float = (d - (2.0 * _top_len + arc)) / r
		pos = Vector3(_loop_min_x - r * sin(th2), (_loop_top_y - r) - r * cos(th2), _loop_cz)
		tangent = Vector3(-cos(th2), sin(th2), 0.0)
		normal = Vector3(-sin(th2), -cos(th2), 0.0)
	return Transform3D(Basis(tangent, normal, Vector3(0.0, 0.0, 1.0)), pos)


## Place every module at its FIXED loop position ONCE (static bed — never moved per frame). Boxes are
## carried by the section bodies; the rollers only "roll" via the shader's scrolling band.
func _place_modules() -> void:
	if _n_loop <= 0 or _loop_len <= 0.0 or _deck_mmi == null:
		return
	var deck_mm: MultiMesh = _deck_mmi.multimesh
	var gap_mm: MultiMesh = _gap_mmi.multimesh if _gap_mmi != null else null
	var roller_mm: MultiMesh = _roller_mmi.multimesh if _roller_mmi != null else null
	var rpm: int = _rollers_per_mod
	for i: int in _n_loop:
		var xf: Transform3D = _loop_xform(_module_arc[i])
		if deck_mm != null:
			deck_mm.set_instance_transform(i, xf * _deck_scale_xf)
		if gap_mm != null:
			gap_mm.set_instance_transform(i, xf * _gap_offset_xf)
		if roller_mm != null and rpm > 0:
			var base: int = i * rpm
			for j: int in rpm:
				roller_mm.set_instance_transform(base + j, xf * _roller_local[j])
	_refresh_roller_colors()


## Stamp each module's roller COLOUR (idle black / diverting red) from its fixed zone. Cheap — the
## transforms never change, so this is only called on build and when a divert command changes.
func _refresh_roller_colors() -> void:
	if _roller_mmi == null or _rollers_per_mod <= 0 or _n_loop <= 0:
		return
	var roller_mm: MultiMesh = _roller_mmi.multimesh
	if roller_mm == null:
		return
	for i: int in _n_loop:
		var d: float = _module_arc[i]
		var dir: float = 0.0
		if d < _top_len:
			dir = _section_dir(clampi(floori(d / _seg), 0, _nx - 1))
		if _module_dir[i] == dir:
			continue                                     # unchanged -> skip
		_module_dir[i] = dir
		# Encode dir {-1,0,+1} -> {0,0.5,1} so it survives any normalized custom-data storage.
		var enc: float = (dir + 1.0) * 0.5
		var base: int = i * _rollers_per_mod
		for j: int in _rollers_per_mod:
			roller_mm.set_instance_custom_data(base + j, Color(enc, 0.0, 0.0, 0.0))


## Roll direction for a section: +1 LEFT, -1 RIGHT, 0 straight. Comms bits (when enabled) win
## over the showcase: two bits per section in the divert word(s), even = LEFT, odd = RIGHT.
func _section_dir(ix: int) -> float:
	if enable_comms and not _div_words.is_empty():
		var w: int = ix >> 4                       # 16 sections per word
		if w < _div_words.size():
			var b: int = (ix & 15) * 2             # 2 bits per section
			var word: int = _div_words[w]
			var left: bool = (word & (1 << b)) != 0
			var right: bool = (word & (1 << (b + 1))) != 0
			if left and not right:
				return 1.0
			if right and not left:
				return -1.0
			return 0.0                             # both or neither -> straight
	if showcase:
		return 1.0 if (ix % 2 == 0) else -1.0
	return 0.0


# ---------- static roller bed (rollers "roll" via the shader; boxes ride the section bodies) ----------
func _process(_delta: float) -> void:
	# STATIC roller bed: the modules never move (placed once in _place_modules), so there is nothing
	# to update per frame — the "rolling" look is a GPU-only scrolling band in the roller shader, and
	# boxes are carried by the section bodies. Just keep the smooth belt hidden as a safety.
	if is_instance_valid(_mesh_instance) and _mesh_instance.visible:
		_mesh_instance.visible = false


# ---------- transport (per-section independent divert, like VR) ----------
func _physics_process(delta: float) -> void:
	super._physics_process(delta)            # belt base: leg footing poll
	if enable_comms:
		_poll_divert_words()
	var moving: bool = speed != 0.0 and Simulation.is_running() and not Simulation.is_paused()
	if moving != _last_moving or speed != _last_speed:
		_last_moving = moving
		_last_speed = speed
		_transport_dirty = true
	# Nothing that affects section velocity changed since last tick — the bodies keep their cached
	# constant_linear_velocity, so skip the 400-section loop entirely (huge physics-thread saving).
	if not _transport_dirty:
		return
	_transport_dirty = false
	# All section bodies share the conveyor's orientation, so compute the flow tangent ONCE per frame
	# instead of reading each body's global_transform. Each section ALWAYS conveys forward at the sorter
	# speed; an active divert section ADDS a cross-belt push (DIVERT_ANGLE, default 90 = perpendicular)
	# also at the sorter speed, so a box travels forward AND sideways at once (per-section, it walks off).
	var flow: Vector3 = global_transform.basis.x.normalized()
	for ix: int in _section_bodies.size():
		var body: StaticBody3D = _section_bodies[ix]
		if not is_instance_valid(body):
			continue
		var vel: Vector3 = Vector3.ZERO
		if moving:
			var dir: float = _section_dir(ix)
			vel = flow * speed
			if dir != 0.0:
				vel += (Basis(Vector3.UP, deg_to_rad(dir * DIVERT_ANGLE)) * flow).normalized() * speed
		# Only push to the physics body when the velocity actually changes (idle sections stay constant).
		if ix < _section_vel.size() and _section_vel[ix] == vel:
			continue
		if ix < _section_vel.size():
			_section_vel[ix] = vel
		body.constant_linear_velocity = vel


## Disable the inherited flat-belt collision so the per-section bodies are the riding surface —
## each section can then carry its own (independent) divert velocity.
func _neutralize_belt_bodies() -> void:
	for body: StaticBody3D in _bodies:
		if is_instance_valid(body):
			body.collision_layer = 0
			body.constant_linear_velocity = Vector3.ZERO


## One transport StaticBody per section, so a box spanning several sections is pushed
## independently by each (its velocity is driven in _physics_process).
func _build_section_bodies(min_x: float, deck_l: float, nx: int, min_z: float, max_z: float, top_y: float) -> void:
	for old: StaticBody3D in _section_bodies:
		if is_instance_valid(old):
			old.queue_free()
	_section_bodies.clear()
	_section_vel = PackedVector3Array()
	_section_vel.resize(nx)
	_section_vel.fill(Vector3(INF, INF, INF))   # sentinel so the first push always applies
	_transport_dirty = true                     # fresh bodies -> push velocities next tick
	var cz: float = (min_z + max_z) * 0.5
	var deck_w: float = max_z - min_z
	var px: float = deck_l / float(nx)
	for ix: int in nx:
		var x: float = min_x + (float(ix) + 0.5) * px
		var body := StaticBody3D.new()
		body.name = "_ARBSection_%d" % ix
		var pm := PhysicsMaterial.new()
		pm.friction = SURFACE_FRICTION
		pm.rough = true
		pm.bounce = 0.0
		body.physics_material_override = pm
		add_child(body, false, Node.INTERNAL_MODE_FRONT)
		body.owner = self
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		# Small overlap (px * 1.05) so a box crossing a seam doesn't catch a lip, while keeping the
		# double-contact band (box touching two bodies at once) as narrow as possible for physics perf.
		shape.size = Vector3(px * 1.05, 0.04, maxf(0.05, deck_w))
		col.shape = shape
		body.add_child(col)
		body.position = Vector3(x, top_y - 0.02, cz)
		# Opt-in (via the inherited `velocity_blending`, default OFF): when enabled, drive_body samples
		# the flow under each box so its LINEAR channel nets the box toward the MEAN of the sections it
		# straddles (mixed diverts resolve to the majority instead of jittering) and its ANGULAR channel
		# applies the yaw torque that SKEWS the box from the left/right variation (the torque angular_damp
		# would otherwise swallow). Left off, drive_body stays a no-op and pays no per-box raycasts.
		ConveyorTransport.set_surface_blending(body, velocity_blending)
		_section_bodies.append(body)


## Low-poly cylinder matching the GLB roller's size/axis (its length along local Y).
func _make_roller_cylinder(src: AABB) -> CylinderMesh:
	var cyl := CylinderMesh.new()
	var r: float = maxf(src.size.x, src.size.z) * 0.5
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = maxf(0.01, src.size.y)
	cyl.radial_segments = 6    # low-poly: rollers are solid black/red, so roundness barely matters
	cyl.rings = 0
	return cyl


# ---------- bake ----------
## Instantiate the ARB module once: rotate it 90 deg (flow Z -> conveyor X), recentre and drop
## its top to Y=0, then split it — the rubber rollers become a single instanced template + a
## per-roller transform list (for the animated MultiMesh), everything else is merged into one
## static deck mesh. Cached after the first call.
func _bake() -> void:
	var packed := load(GLB_PATH) as PackedScene
	if packed == null:
		push_warning("Intralox: could not load %s" % GLB_PATH)
		return
	var root: Node = packed.instantiate()
	var boxes: Array[AABB] = []
	_collect_aabbs(root, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		root.free()
		return
	var aabb: AABB = boxes[0]
	for i: int in range(1, boxes.size()):
		aabb = aabb.merge(boxes[i])
	var rot: Basis = Basis(Vector3.UP, deg_to_rad(90.0))
	var c: Vector3 = aabb.get_center()
	var top: float = aabb.position.y + aabb.size.y
	var correction := Transform3D(rot, Vector3(-c.z, -top, c.x))

	_roller_xforms.clear()
	_roller_mesh = null
	var deck_st_by_mat: Dictionary = {}
	_bake_walk(root, Transform3D.IDENTITY, correction, deck_st_by_mat)
	root.free()
	var deck := ArrayMesh.new()
	for mat: Variant in deck_st_by_mat:
		var st: SurfaceTool = deck_st_by_mat[mat]
		st.set_material(mat as Material)
		st.commit(deck)
	_deck_mesh = deck


func _bake_walk(node: Node, accum: Transform3D, correction: Transform3D, deck_st_by_mat: Dictionary) -> void:
	for c: Node in node.get_children():
		var cx: Transform3D = accum
		if c is Node3D:
			cx = accum * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			var mi := c as MeshInstance3D
			var mesh: Mesh = mi.mesh
			var xf: Transform3D = correction * cx
			var is_roller: bool = String(mi.name).to_lower().contains("roller")
			for s: int in mesh.get_surface_count():
				var mat: Material = mi.get_active_material(s)
				if mat == null:
					mat = mesh.surface_get_material(s)
				if not is_roller and mat != null and ROLLER_MAT in mat.resource_name:
					is_roller = true
				if is_roller:
					if _roller_mesh == null:
						# Low-poly stand-in for the GLB roller (same size/axis): tiny rollers
						# tiled thousands of times, so a 6-sided cylinder saves a lot of verts
						# with no visible difference once the rib shader is on it.
						_roller_mesh = _make_roller_cylinder(mesh.get_aabb())
					if s == 0:
						_roller_xforms.append(xf)  # one entry per roller node
				else:
					var st: SurfaceTool = deck_st_by_mat.get(mat)
					if st == null:
						st = SurfaceTool.new()
						st.begin(Mesh.PRIMITIVE_TRIANGLES)
						deck_st_by_mat[mat] = st
					st.append_from(mesh, s, xf)
		_bake_walk(c, cx, correction, deck_st_by_mat)


func _collect_aabbs(node: Node, accum: Transform3D, out: Array[AABB]) -> void:
	for c: Node in node.get_children():
		var cx: Transform3D = accum
		if c is Node3D:
			cx = accum * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			out.append(cx * (c as MeshInstance3D).mesh.get_aabb())
		_collect_aabbs(c, cx, out)


## Spin shader: rolls each roller about its local Y (its axle) by TIME, in the direction the
## section's instance custom data carries (+/-1, or 0 to hold still). Dark rubber albedo.
func _make_roller_shader() -> void:
	if _roller_shader != null:
		return
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
// Roll direction per roller instance, from MultiMesh custom data (.r), encoded (dir+1)/2 -> {0,0.5,1}.
varying float v_dir;
void vertex() {
	v_dir = INSTANCE_CUSTOM.x * 2.0 - 1.0;
}
void fragment() {
	// Solid colour only (no animation): idle sections BLACK, diverting sections DARK RED.
	float active = step(0.5, abs(v_dir));
	ALBEDO = mix(vec3(0.03, 0.03, 0.03), vec3(0.30, 0.02, 0.02), active);
	ROUGHNESS = 0.55;
	METALLIC = 0.0;
}
"""
	_roller_shader = ShaderMaterial.new()
	_roller_shader.shader = sh


## Local-space deck extent + top Y from the belt collision bodies (the VR pattern), so the
## section field lands where parcels ride regardless of how the path is centred.
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


#region Communications
@export_category("Intralox Divert")
## Per-section divert commands from a PLC / OPC UA server. Needs the inherited Enable Comms on;
## when read, these bits drive the diverts and OVERRIDE the Showcase toggle.
@export var divert_tag_group_name: String
## Tag group for the divert command word(s).
@export_custom(0, "tag_group_enum") var divert_tag_groups: String:
	set(value):
		divert_tag_group_name = value
		divert_tag_groups = value
## Command tag (READ): INT32 word(s). Two bits per section — even bit = LEFT, odd bit = RIGHT, in
## section order (bit 0 = sec 0 left, bit 1 = sec 0 right, bit 2 = sec 1 left, ...). One word holds
## 16 sections; beyond that the words are addressed [code]name[0][/code], [code]name[1][/code], ...
## [br]Datatype: [code]INT32[/code]
@export var divert_tag_name: String = ""

var _div_tags: Array[OIPCommsTag] = []
var _div_words: PackedInt32Array = PackedInt32Array()


func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	OIPCommsSetup.validate_tag_property(property, "divert_tag_group_name", "divert_tag_groups", "divert_tag_name")


func _enter_tree() -> void:
	super._enter_tree()
	# The base already connects tag_group_initialized -> _tag_group_initialized (our override),
	# so don't connect again here — just default our divert group.
	divert_tag_group_name = OIPCommsSetup.default_tag_group(divert_tag_group_name)


func _on_simulation_started() -> void:
	super._on_simulation_started()
	_register_divert_tags()


## Register one INT32 divert word per 16 sections (name, name[1], name[2], ...).
func _register_divert_tags() -> void:
	_div_tags.clear()
	var n_words: int = maxi(1, (_nx + 15) >> 4)
	_div_words = PackedInt32Array()
	_div_words.resize(n_words)
	if not enable_comms:
		return
	for w: int in n_words:
		var t := OIPCommsTag.new()
		var nm: String = divert_tag_name if n_words <= 1 else "%s[%d]" % [divert_tag_name, w]
		t.register(divert_tag_group_name, nm, OIPCommsTag.TYPE_INT32)
		_div_tags.append(t)


func _tag_group_initialized(group: String) -> void:
	super._tag_group_initialized(group)
	for t: OIPCommsTag in _div_tags:
		t.on_group_initialized(group)


## Read the divert word(s); on a change, re-stamp the per-section roll direction onto the rollers.
func _poll_divert_words() -> void:
	if _div_tags.is_empty():
		return
	var changed: bool = false
	for w: int in _div_tags.size():
		if _div_tags[w].is_ready():
			var v: int = _div_tags[w].read_int32()
			if w < _div_words.size() and _div_words[w] != v:
				_div_words[w] = v
				changed = true
	if changed:
		_transport_dirty = true              # recompute section velocities next physics tick
		_refresh_roller_colors()
#endregion
