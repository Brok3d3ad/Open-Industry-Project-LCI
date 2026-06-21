@tool
class_name VarioRoute
extends ResizableNode3D

## Körber VarioRoute pivoting-roller-unit (PRU) matrix sorter (VR800 / VR1600).
##
## Conveyor-style part: resizable (drag handles), legs raise/lower, removable side
## guards, and a pivoting roller deck that conveys boxes STRAIGHT and diverts/aligns
## them LEFT or RIGHT by rotating the deck's surface velocity (and the visible red
## rollers) up to ±45° about vertical — like the real pivoting roller units.
##
## Built on the imported GLB (varioroute_vr800.glb / varioroute_vr1600.glb). Physics,
## the input light barrier and the OIP legs (parts/StraightLeg.tscn) are generated as
## INTERNAL children at runtime, so the saved .tscn stays minimal (model + script).
##
## Resize (ResizableNode3D `size`, X=length Y=height Z=width):
##   - X / Z drag handles stretch the deck (length = more sorting area, width fixed-ish).
##   - Y / top handle raises/lowers the legs (leg_extension), the deck rises with them.
##
## Communications (subset of Körber ROU_006 Device Control — for the Amazon LVL2
## input/output check; full byte map aligns to the PLC AOI):
##   IN  (PLC -> VR): run (BOOL), speed (REAL m/s), divert_command (DINT 0/1/2)
##   OUT (VR -> PLC): light_barrier_blocked (BOOL), running (BOOL), sort_target (DINT)

enum DivertDir { STRAIGHT, LEFT, RIGHT }
enum AlignTo { NONE, LEFT, RIGHT }

const BOX_COLLISION_MASK: int = 8     # boxes sit on layer 4 (value 8); matches LaserSensor
const MIN_LENGTH: float = 0.8
const MAX_LENGTH: float = 12.0   # hard cap: a stray editor transform delta can never run the length away
const MIN_WIDTH: float = 0.4
const MIN_EXTENSION: float = -0.25
const MAX_EXTENSION: float = 3.0
const STANDARD_WIDTH: float = 1.524   # default OIP belt-conveyor width; fresh single-module VR matches it
const PARCEL_COVERAGE: float = 0.30   # half-length (m) of a parcel's divert footprint along flow
const MAX_LINES: int = 24             # per ROU_006 / AOI a module supports up to 24 pivot lines
const BODY_BOTTOM_AUTHORED: float = 0.47  # the body's natural bottom height (matches build_varioroute.py)
const DECK_TOP_AUTHORED: float = 0.90     # the deck/processing surface's natural height

#region Exports -------------------------------------------------------------------
## Powers the roller field (and belts). Boxes are conveyed only while running.
## Default ON so a freshly placed VR runs without having to enable it each time; it only
## actually conveys during the simulation (see _sim_active), and the state persists across
## sim stop/restart.
@export var running: bool = true:
	set(value):
		running = value
		if _running_tag.is_ready():
			_running_tag.write_bit(value)
		if _rtr_tag.is_ready():
			_rtr_tag.write_bit(value)   # ready-to-receive while running

## Nominal transport speed (spec: 0.5 .. 2.0 m/s).
@export_range(0.0, 2.5, 0.05, "suffix:m/s") var speed: float = 1.5

## Current divert direction applied to every module.
@export var divert: DivertDir = DivertDir.STRAIGHT:
	set(value):
		divert = value

## Maximum pivot angle used to divert (spec: 15 .. 45 deg).
@export_range(15.0, 45.0, 1.0, "suffix:deg") var max_divert_angle: float = 45.0
## Curved divert: number of lines over which the angle ramps from 0 to max (ROU_006
## "curve distance"). 1 = step (parallel-like), higher = gentler curve.
@export_range(1, 8, 1) var curve_distance: int = 2

## Auto-sort demo: each parcel gets an alternating LEFT/RIGHT divert as it enters (like the
## S7000 sorter). Default OFF so the `divert` setting (Straight/Left/Right) is HONORED. Turn
## ON only for the self-diverting demo — note the deck is ONE body, so all boxes on it follow
## the FIRST parcel's direction (a shared deck can't drive each box differently).
@export var auto_sort: bool = false
## Visible spin speed of the 3D barrel rollers (the conveying surface that turns forward and,
## on divert, yaws diagonally to drive the box sideways).
@export_range(0.0, 20.0, 0.5) var roller_spin_speed: float = 8.0

## Aligner mode: gently push boxes to one border instead of fully diverting them.
@export var align_to: AlignTo = AlignTo.NONE
## Angle used while aligning (gentler than a full divert).
@export_range(5.0, 45.0, 1.0, "suffix:deg") var align_angle: float = 20.0

## Surface friction so the powered deck grips boxes — HIGH (like the S7000 sorter) so a
## box doesn't slip on the diagonal divert; combines with the box's own ~0.5.
@export_range(0.0, 4.0, 0.05) var surface_friction: float = 1.4:
	set(value):
		surface_friction = value
		for b: StaticBody3D in _transport_bodies + _belt_bodies:
			if is_instance_valid(b) and b.physics_material_override != null:
				b.physics_material_override.friction = value

## When snapped/placed against a conveyor, auto-match the deck width to that conveyor
## so they line up exactly. Turn off for the fixed-width VR1600 if you don't want it.
@export var auto_match_width: bool = true
## Vertical fine-tune of the snap connection height (negative = sit lower so the deck
## lines up flush with the conveyor belt instead of slightly above it).
@export_range(-0.2, 0.2, 0.005, "suffix:m") var snap_height_offset: float = 0.0
## The FRONT and BACK snap ends sit this much LOWER than the deck, so a box crossing the
## seam to/from the next conveyor doesn't catch a lip and jam. Sides keep the deck height.
@export_range(0.0, 0.15, 0.005, "suffix:m") var end_snap_drop: float = 0.02

@export_group("Side Guards")
@export var left_guard_enabled: bool = true:
	set(value):
		left_guard_enabled = value
		if is_node_ready():
			_update_guards()
@export var right_guard_enabled: bool = true:
	set(value):
		right_guard_enabled = value
		if is_node_ready():
			_update_guards()
## Infeed-end guard. OFF by default so parcels can flow IN from the upstream conveyor
## (turn on only to close the back end).
@export var infeed_guard_enabled: bool = false:
	set(value):
		infeed_guard_enabled = value
		if is_node_ready():
			_update_guards()

@export_group("Legs")
@export var legs_enabled: bool = true:
	set(value):
		legs_enabled = value
		if is_node_ready():
			_rebuild_legs()
## Lengthen (or shorten, negative) the legs; the deck rises/falls with them.
## Mirrored by the Y resize handle / size.y.
# Processing height = the deck / belt surface height above the floor (where boxes ride),
# in metres. Default 1.1 m so it lines up with the conveyors. Legs auto-fill below it.
@export_range(0.6, 4.0, 0.01, "suffix:m") var processing_height: float = 1.1:
	set(value):
		processing_height = clampf(value, DECK_TOP_AUTHORED + MIN_EXTENSION, DECK_TOP_AUTHORED + MAX_EXTENSION)
		leg_extension = processing_height - DECK_TOP_AUTHORED
		if is_node_ready():
			_apply_size()
		if not _syncing and _base_height > 0.0:
			_syncing = true
			size = Vector3(_base_length * _len_scale, _base_height + leg_extension, _base_width * _wid_scale)
			_syncing = false
var leg_extension: float = 1.1 - 0.90   # derived body lift = processing_height - deck top
@export var leg_model_scene: PackedScene = preload("res://parts/StraightLeg.tscn")
#endregion

# Internal generated nodes / caches
var _model: Node3D = null
var _transport_bodies: Array[StaticBody3D] = []
var _belt_bodies: Array[StaticBody3D] = []
var _roller_lines: Array[Node3D] = []
var _guards: Dictionary = {}
var _light_barrier: Area3D = null
var _lb_bodies: Array = []
var _legs: Array[Node3D] = []
var _flow_arrow: Node3D = null
var _line_strips: Array = []          # per pivot-line VISUAL groups (divert wave): {x, nodes, angle}
var _deck_sensor: Area3D = null
var _parcels: Dictionary = {}         # RigidBody3D -> latched DivertDir (set at the light barrier)
var _n_lines: int = 0
var _roller_angle: float = 0.0
var _built: bool = false
# 3D spinning barrel-roller field (replaces the flat pebbles visually)
var _spin_mm_inst: MultiMeshInstance3D = null
var _spin_mm: MultiMesh = null
var _spin_shader: ShaderMaterial = null
var _sort_counter: int = 0
var _half_length: float = 1.0
var _half_width: float = 0.5
var _lb_blocked: bool = false
var _sim_active: bool = false          # true between Simulation.started and .stopped — drive ONLY then
# resize bookkeeping
var _base_length: float = 0.0
var _base_width: float = 0.0
var _base_height: float = 0.0
var _base_body_bottom: float = 0.0
var _len_scale: float = 1.0
var _wid_scale: float = 1.0
var _syncing: bool = false
var _match_pending: bool = false
var _last_run: bool = false            # run-tag edge detector (so a constant value never forces running)


#region ResizableNode3D integration -----------------------------------------------
func _init() -> void:
	super._init()
	size_default = Vector3(2.0, 1.2, 1.0)
	size_min = Vector3(MIN_LENGTH, 0.4, MIN_WIDTH)


func _enter_tree() -> void:
	super._enter_tree()
	_comms_enter()


func _exit_tree() -> void:
	super._exit_tree()
	_comms_exit()
	if is_instance_valid(_flow_arrow):
		FlowDirectionArrow.unregister(_flow_arrow)
	ConveyorSnapping.notify_contacts_rebuild(self)


func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		ConveyorSnapping.notify_contacts_rebuild(self)
		_request_connection_rebuild()   # re-check our own neighbour width when WE move


func _ready() -> void:
	_model = get_node_or_null("Model") as Node3D
	if _model == null:
		for c: Node in get_children():
			if c is Node3D:
				_model = c as Node3D
				break
	_measure_base()
	# Fresh single-module VR (model scale untouched) defaults to the conveyor width so it
	# lines up out of the box. Resized instances (scale already baked) keep their width.
	if is_instance_valid(_model) and absf(_model.scale.z - 1.0) < 0.001 and _base_width > 0.0 and _base_width < 1.2:
		_wid_scale = STANDARD_WIDTH / _base_width
	_built = false
	_apply_size()
	_build()
	if not _syncing:
		_syncing = true
		size = Vector3(_base_length * _len_scale, _base_height + leg_extension, _base_width * _wid_scale)
		_syncing = false
	ConveyorSnapping.notify_contacts_rebuild(self)


func _on_size_changed() -> void:
	if _syncing or _base_height <= 0.0:
		return
	_syncing = true
	_len_scale = size.x / _base_length if _base_length > 0.0 else 1.0
	_wid_scale = size.z / _base_width if _base_width > 0.0 else 1.0
	leg_extension = size.y - _base_height
	processing_height = leg_extension + DECK_TOP_AUTHORED
	_syncing = false
	if is_node_ready():
		_apply_size()


func _get_constrained_size(new_size: Vector3) -> Vector3:
	if _base_height <= 0.0:
		return new_size
	return Vector3(
		clampf(new_size.x, MIN_LENGTH, MAX_LENGTH),
		clampf(new_size.y, _base_height + MIN_EXTENSION, _base_height + MAX_EXTENSION),
		maxf(MIN_WIDTH, new_size.z))


## Override the base ResizableNode3D handler so a plain MOVE/snap never bleeds into `size`.
## The base version did `size = original_size + motion` on EVERY transform delta, so moving
## or snapping the VR grew size.x and the deck stretched along flow. Here only an actual
## resize-handle drag (non-zero motion on that axis) changes the matching size component
## (mirrors belt_conveyor.gd's guarded handler).
func _transform_requested(data: Dictionary) -> void:
	if not EditorInterface.get_selection().get_selected_nodes().has(self):
		return
	if not data.has("motion"):
		return
	var md: Array = data["motion"]
	var mx: float = md[0]
	var my: float = md[1]
	var mz: float = md[2]
	var motion := Vector3(mx, my, mz)
	if not transform_in_progress:
		original_size = size
		transform_in_progress = true
	var new_size: Vector3 = original_size
	if not is_zero_approx(motion.x):
		new_size.x = original_size.x + motion.x
	if not is_zero_approx(motion.y):
		new_size.y = original_size.y + motion.y
	if not is_zero_approx(motion.z):
		new_size.z = original_size.z + motion.z
	if new_size == original_size:
		return
	size = _get_constrained_size(new_size)


func _get_resize_local_bounds(for_size: Vector3) -> AABB:
	return AABB(Vector3(-for_size.x * 0.5, 0.0, -for_size.z * 0.5), for_size)


## Measure the model's natural (unscaled) dimensions by dividing the current
## part-local extent by the model's current scale, so it works on a fresh or a
## previously-resized/saved instance.
func _measure_base() -> void:
	if not is_instance_valid(_model):
		return
	var msc: Vector3 = _model.scale
	if msc.x == 0.0 or msc.y == 0.0 or msc.z == 0.0:
		msc = Vector3.ONE
	var mn := Vector3(1e9, 1e9, 1e9)        # full extent (height)
	var mx := Vector3(-1e9, -1e9, -1e9)
	var bmn := Vector3(1e9, 1e9, 1e9)       # BODY footprint only (length/width) -- excludes cabinet/sensors
	var bmx := Vector3(-1e9, -1e9, -1e9)
	var have_body: bool = false
	var inv: Transform3D = global_transform.affine_inverse()
	for mi: MeshInstance3D in _all_meshes():
		var a: AABB = _mesh_world_aabb(mi)
		for i: int in 8:
			var p: Vector3 = inv * a.get_endpoint(i)
			mn = mn.min(p); mx = mx.max(p)
		if mi.name.ends_with("_Body") and not mi.name.contains("Cabinet"):
			have_body = true
			for i: int in 8:
				var bp: Vector3 = inv * a.get_endpoint(i)
				bmn = bmn.min(bp); bmx = bmx.max(bp)
	if not have_body:
		bmn = mn; bmx = mx
	# Footprint (length/width) from the frame body so the side-mounted cabinet/sensors
	# don't inflate the width; height from the full extent (incl. guards).
	_base_length = (bmx.x - bmn.x) / msc.x
	_base_width = (bmx.z - bmn.z) / msc.z
	_base_height = (mx.y - mn.y) / msc.y
	_base_body_bottom = bmn.y / msc.y
	_len_scale = msc.x
	_wid_scale = msc.z


## Apply current length/width scale + leg lift to the model, then rebuild physics.
func _apply_size() -> void:
	if not is_instance_valid(_model):
		return
	_model.scale = Vector3(_len_scale, 1.0, _wid_scale)
	_model.position.y = leg_extension
	if _built:
		_build_transport_bodies()
		_build_light_barrier()
		_build_deck_sensor()
		_guards.clear()
		_update_guards()
		_rebuild_legs()
		_update_flow_arrow()
		_build_spin_rollers()
#endregion


#region Lifecycle -----------------------------------------------------------------
func _build() -> void:
	_collect_nodes()
	_build_transport_bodies()
	_build_light_barrier()
	_build_deck_sensor()
	_guards.clear()
	_update_guards()
	_rebuild_legs()
	_update_flow_arrow()
	_build_spin_rollers()
	_built = true


func _physics_process(delta: float) -> void:
	# Skip ONLY while idle in the editor. During OIP's in-editor simulation `running` is set
	# AND is_editor_hint() stays true, so an unconditional return left the VR DEAD in the sim
	# (bodies never got a velocity → boxes didn't move). Same guard the S7000 sorter uses.
	if Engine.is_editor_hint() and not _sim_active:
		return
	# Drive transport whenever 'running' is set (set by the PLC run tag or the inspector;
	# cleared on sim stop). Matches the PBChute pattern -- don't gate on Simulation.is_running().
	var active: bool = running
	# input light barrier output
	var blocked: bool = _lb_bodies.size() > 0
	if blocked != _lb_blocked:
		_lb_blocked = blocked
		if _lb_tag.is_ready():
			_lb_tag.write_bit(blocked)
	# drop parcels that left the scene
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p):
			_parcels.erase(p)
	var v: float = speed if active else 0.0
	var pitch: float = _strip_pitch()
	# PHYSICS: one solid deck body, pushed in the divert direction of the parcel on it.
	var deck_rad: float = deg_to_rad(_deck_divert_angle()) if active else 0.0
	# 3D barrel rollers: roll forward (u_speed) and yaw to the divert angle (u_yaw)
	if _spin_shader != null:
		_spin_shader.set_shader_parameter("u_speed", roller_spin_speed if active else 0.0)
		_spin_shader.set_shader_parameter("u_yaw", deck_rad)
	for body: StaticBody3D in _transport_bodies:
		if not is_instance_valid(body):
			continue
		if v == 0.0:
			body.constant_linear_velocity = Vector3.ZERO
		else:
			var flow: Vector3 = body.global_transform.basis.x.normalized()
			body.constant_linear_velocity = (Basis(Vector3.UP, deck_rad) * flow) * v
	# straight belts
	for belt: StaticBody3D in _belt_bodies:
		if not is_instance_valid(belt):
			continue
		if v == 0.0:
			belt.constant_linear_velocity = Vector3.ZERO
		else:
			belt.constant_linear_velocity = belt.global_transform.basis.x.normalized() * v
	# VISUAL: per-line divert wave -- each pivot line's rollers angle to the parcel over it
	for e: Dictionary in _line_strips:
		var tgt: float = _line_target_angle(float(e["x"]), pitch) if active else 0.0
		var ang: float = move_toward(float(e["angle"]), tgt, 240.0 * delta)
		e["angle"] = ang
		var rad: float = deg_to_rad(ang)
		for line: Variant in e["nodes"]:
			if not is_instance_valid(line):
				continue
			for roller: Node in (line as Node3D).get_children():
				if roller is Node3D:
					(roller as Node3D).rotation.y = rad
#endregion


## Divert angle for the solid deck body = the direction of the parcel currently on the deck.
func _deck_divert_angle() -> float:
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p):
			continue
		var d: int = _parcels[p]
		if d == int(DivertDir.LEFT):
			return max_divert_angle
		if d == int(DivertDir.RIGHT):
			return -max_divert_angle
	if align_to == AlignTo.LEFT:
		return align_angle
	if align_to == AlignTo.RIGHT:
		return -align_angle
	return 0.0


## Per-parcel divert command. Auto-sort = alternate LEFT/RIGHT so the VR diverts on its own.
func _pick_divert() -> int:
	if not auto_sort:
		return int(divert)
	_sort_counter += 1
	return int(DivertDir.LEFT) if (_sort_counter % 2 == 0) else int(DivertDir.RIGHT)


#region Spin rollers (3D barrels: roll forward + yaw diagonal on divert) -----------
func _build_spin_rollers() -> void:
	_hide_pebble_rollers()
	if _spin_mm_inst == null:
		_spin_mm_inst = MultiMeshInstance3D.new()
		_spin_mm_inst.name = "_SpinRollers"
		add_child(_spin_mm_inst, false, Node.INTERNAL_MODE_FRONT)
		_spin_mm_inst.owner = null
	# roller field over the deck mesh extent (falls back to the full size footprint)
	var min_x: float = -size.x * 0.5
	var max_x: float = size.x * 0.5
	var min_z: float = -size.z * 0.5
	var max_z: float = size.z * 0.5
	var top: float = _deck_top_local()
	var decks: Array = _find_all(func(n: Node) -> bool: return n is MeshInstance3D and n.name.contains("_Deck"))
	if not decks.is_empty():
		min_x = 1e9; max_x = -1e9; min_z = 1e9; max_z = -1e9
		for dk: Node in decks:
			var la: AABB = _to_local_aabb(_mesh_world_aabb(dk as MeshInstance3D))
			min_x = minf(min_x, la.position.x); max_x = maxf(max_x, la.position.x + la.size.x)
			min_z = minf(min_z, la.position.z); max_z = maxf(max_z, la.position.z + la.size.z)
	var pitch: float = 0.10
	var nx: int = maxi(1, int(round((max_x - min_x) / pitch)))
	var nz: int = maxi(1, int(round((max_z - min_z) / pitch)))
	_spin_mm = MultiMesh.new()
	_spin_mm.transform_format = MultiMesh.TRANSFORM_3D
	_spin_mm.mesh = _make_vr_roller_mesh()
	_spin_mm.instance_count = nx * nz
	var idx: int = 0
	for ix: int in nx:
		var x: float = min_x + (float(ix) + 0.5) * (max_x - min_x) / float(nx)
		for iz: int in nz:
			var z: float = min_z + (float(iz) + 0.5) * (max_z - min_z) / float(nz)
			_spin_mm.set_instance_transform(idx, Transform3D(Basis.IDENTITY, Vector3(x, top, z)))
			idx += 1
	_spin_mm_inst.multimesh = _spin_mm
	_make_vr_roller_shader()
	_spin_mm_inst.material_override = _spin_shader


func _hide_pebble_rollers() -> void:
	for line: Node3D in _roller_lines:
		if not is_instance_valid(line):
			continue
		for roller: Node in (line as Node3D).get_children():
			if roller is MeshInstance3D:
				(roller as MeshInstance3D).visible = false


func _make_vr_roller_mesh() -> ArrayMesh:
	# barrel whose axle is local Z (cross): rolling about Z drives the box along +X (flow)
	var segs: int = 12
	var r: float = 0.032
	var rc: float = r * 0.78
	var hl: float = 0.034
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p0: Array[Vector3] = []
	var p1: Array[Vector3] = []
	var p2: Array[Vector3] = []
	var nr: Array[Vector3] = []
	for i: int in segs:
		var a: float = TAU * float(i) / float(segs)
		var ca: float = cos(a)
		var sa: float = sin(a)
		p0.append(Vector3(rc * ca, rc * sa, -hl))
		p1.append(Vector3(r * ca, r * sa, 0.0))
		p2.append(Vector3(rc * ca, rc * sa, hl))
		nr.append(Vector3(ca, sa, 0.0))
	for i: int in segs:
		var j: int = (i + 1) % segs
		_vr_band(st, p0[i], p1[i], p1[j], p0[j], nr[i], nr[j])
		_vr_band(st, p1[i], p2[i], p2[j], p1[j], nr[i], nr[j])
	var fr: Vector3 = Vector3(0, 0, hl)
	var bk: Vector3 = Vector3(0, 0, -hl)
	for i: int in segs:
		var j: int = (i + 1) % segs
		_vr_cap(st, bk, p0[j], p0[i], Vector3(0, 0, -1))
		_vr_cap(st, fr, p2[i], p2[j], Vector3(0, 0, 1))
	return st.commit()


func _vr_band(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nc: Vector3) -> void:
	st.set_normal(na); st.add_vertex(a)
	st.set_normal(na); st.add_vertex(b)
	st.set_normal(nc); st.add_vertex(c)
	st.set_normal(na); st.add_vertex(a)
	st.set_normal(nc); st.add_vertex(c)
	st.set_normal(nc); st.add_vertex(d)


func _vr_cap(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	st.set_normal(n); st.add_vertex(a)
	st.set_normal(n); st.add_vertex(b)
	st.set_normal(n); st.add_vertex(c)


func _make_vr_roller_shader() -> void:
	if _spin_shader != null:
		return
	var sh: Shader = Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform float u_speed = 0.0;
uniform float u_yaw = 0.0;
uniform vec3 u_albedo : source_color = vec3(0.62, 0.05, 0.04);
void vertex() {
	float sa = TIME * u_speed;
	float cs = cos(sa); float ss = sin(sa);
	vec3 p = VERTEX;
	p = vec3(cs * p.x + ss * p.y, -ss * p.x + cs * p.y, p.z);   // roll about Z (top -> +X)
	vec3 nn = NORMAL;
	nn = vec3(cs * nn.x + ss * nn.y, -ss * nn.x + cs * nn.y, nn.z);
	float cy = cos(u_yaw); float sy = sin(u_yaw);
	p = vec3(cy * p.x + sy * p.z, p.y, -sy * p.x + cy * p.z);   // yaw about Y (divert)
	nn = vec3(cy * nn.x + sy * nn.z, nn.y, -sy * nn.x + cy * nn.z);
	VERTEX = p;
	NORMAL = nn;
}
void fragment() {
	ALBEDO = u_albedo;
	ROUGHNESS = 0.45;
	METALLIC = 0.0;
}
"""
	_spin_shader = ShaderMaterial.new()
	_spin_shader.shader = sh
#endregion


#region Build helpers -------------------------------------------------------------
func _all_meshes() -> Array:
	return _find_all(func(n: Node) -> bool: return n is MeshInstance3D)


func _collect_nodes() -> void:
	_roller_lines.clear()
	for l: Node in _find_all(func(n: Node) -> bool: return n is Node3D and n.name.contains("PivotLine_")):
		_roller_lines.append(l as Node3D)


func _find_all(pred: Callable) -> Array:
	var acc: Array = []
	_find_all_rec(pred, self, acc)
	return acc


func _find_all_rec(pred: Callable, node: Node, acc: Array) -> void:
	for c: Node in node.get_children():
		if pred.call(c):
			acc.append(c)
		_find_all_rec(pred, c, acc)


func _find_one(pred: Callable) -> Node:
	var r: Array = _find_all(pred)
	return r[0] if r.size() > 0 else null


func _mesh_world_aabb(mi: MeshInstance3D) -> AABB:
	var local_box: AABB = mi.get_aabb()
	var xf: Transform3D = mi.global_transform
	var aabb := AABB(xf * local_box.get_endpoint(0), Vector3.ZERO)
	for i: int in range(1, 8):
		aabb = aabb.expand(xf * local_box.get_endpoint(i))
	return aabb


func _to_local_aabb(world: AABB) -> AABB:
	var inv: Transform3D = global_transform.affine_inverse()
	var a := AABB(inv * world.get_endpoint(0), Vector3.ZERO)
	for i: int in range(1, 8):
		a = a.expand(inv * world.get_endpoint(i))
	return a


## Physics = ONE solid transport body per deck (reliable -- a box on many small adjacent
## strips snags on the seams and won't ride). Visual divert wave is per pivot line.
func _build_transport_bodies() -> void:
	for b: StaticBody3D in _transport_bodies:
		if is_instance_valid(b):
			b.queue_free()
	for b: StaticBody3D in _belt_bodies:
		if is_instance_valid(b):
			b.queue_free()
	_transport_bodies.clear()
	_belt_bodies.clear()
	_line_strips.clear()

	var min_x: float = 1e9
	var max_x: float = -1e9
	var min_z: float = 1e9
	var max_z: float = -1e9
	for d: Node in _find_all(func(n: Node) -> bool: return n is MeshInstance3D and n.name.contains("_Deck")):
		var body: StaticBody3D = _make_surface_body(d as MeshInstance3D, "TransportBody")
		if body != null:
			_transport_bodies.append(body)
		var la: AABB = _to_local_aabb(_mesh_world_aabb(d as MeshInstance3D))
		min_x = minf(min_x, la.position.x); max_x = maxf(max_x, la.position.x + la.size.x)
		min_z = minf(min_z, la.position.z); max_z = maxf(max_z, la.position.z + la.size.z)

	# visual-only grouping of rollers by pivot line (X) for the divert wave -- no collision
	var by_x: Dictionary = {}
	for line: Node3D in _roller_lines:
		var lx: float = _line_local_x(line)
		if lx == INF:
			continue
		var key: int = roundi(lx * 1000.0)
		if not by_x.has(key):
			by_x[key] = []
		(by_x[key] as Array).append(line)
	var keys: Array = by_x.keys()
	keys.sort()
	_n_lines = keys.size()
	for key: int in keys:
		_line_strips.append({"x": float(key) / 1000.0, "nodes": by_x[key], "angle": 0.0})

	# straight belts (infeed/discharge transport)
	for be: Node in _find_all(func(n: Node) -> bool: return n is MeshInstance3D \
			and (n.name.contains("_BeltFront") or n.name.contains("_BeltRear")) and not n.name.contains("_Roller")):
		var belt_body: StaticBody3D = _make_surface_body(be as MeshInstance3D, "BeltBody")
		if belt_body != null:
			_belt_bodies.append(belt_body)
		var la2: AABB = _to_local_aabb(_mesh_world_aabb(be as MeshInstance3D))
		min_x = minf(min_x, la2.position.x); max_x = maxf(max_x, la2.position.x + la2.size.x)

	if max_x > min_x:
		_half_length = maxf(absf(min_x), absf(max_x))
	if max_z > min_z:
		_half_width = maxf(absf(min_z), absf(max_z))


func _line_local_x(line: Node3D) -> float:
	for c: Node in line.get_children():
		if c is Node3D:
			return (global_transform.affine_inverse() * (c as Node3D).global_position).x
	return INF


func _strip_pitch() -> float:
	if _line_strips.size() >= 2:
		var a: float = _line_strips[0]["x"]
		var b: float = _line_strips[_line_strips.size() - 1]["x"]
		return maxf(0.05, absf(b - a) / float(_line_strips.size() - 1))
	return 0.1


func _make_surface_body(mi: MeshInstance3D, prefix: String) -> StaticBody3D:
	var la: AABB = _to_local_aabb(_mesh_world_aabb(mi))
	var sx: float = la.size.x
	var sz: float = la.size.z
	if sx < 0.02 or sz < 0.02:
		return null
	var top: float = la.position.y + la.size.y
	var body := StaticBody3D.new()
	body.name = "_%s_%s" % [prefix, mi.name]
	# Same grip as the S7000 sorter: rough + zero bounce so the powered surface drags the
	# box firmly forward and sideways on the diagonal divert instead of slipping.
	var pm := PhysicsMaterial.new()
	pm.friction = surface_friction
	pm.rough = true
	pm.bounce = 0.0
	body.physics_material_override = pm
	add_child(body, false, Node.INTERNAL_MODE_FRONT)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	var thick: float = 0.04
	shape.size = Vector3(sx, thick, sz)
	col.shape = shape
	body.add_child(col)
	body.position = Vector3(la.get_center().x, top - thick * 0.5 + 0.01, la.get_center().z)
	return body


func _build_light_barrier() -> void:
	if is_instance_valid(_light_barrier):
		_light_barrier.queue_free()
	var decks: Array = _find_all(func(n: Node) -> bool: return n is MeshInstance3D and n.name.contains("_Deck"))
	if decks.is_empty():
		return
	var min_x: float = 1e9
	var min_z: float = 1e9
	var max_z: float = -1e9
	var top: float = 0.9
	for d: Node in decks:
		var la: AABB = _to_local_aabb(_mesh_world_aabb(d as MeshInstance3D))
		min_x = minf(min_x, la.position.x)
		min_z = minf(min_z, la.position.z); max_z = maxf(max_z, la.position.z + la.size.z)
		top = maxf(top, la.position.y + la.size.y)
	var area := Area3D.new()
	area.name = "_LightBarrier"
	area.collision_mask = BOX_COLLISION_MASK
	area.monitoring = true
	add_child(area, false, Node.INTERNAL_MODE_FRONT)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.03, 0.25, maxf(0.1, max_z - min_z))
	col.shape = shape
	area.add_child(col)
	area.position = Vector3(min_x + 0.05, top + 0.1, (min_z + max_z) * 0.5)
	if not area.body_entered.is_connected(_on_lb_body_entered):
		area.body_entered.connect(_on_lb_body_entered)
	if not area.body_exited.is_connected(_on_lb_body_exited):
		area.body_exited.connect(_on_lb_body_exited)
	_light_barrier = area


func _on_lb_body_entered(b: Node) -> void:
	if not _lb_bodies.has(b):
		_lb_bodies.append(b)
	# Latch the current divert command for this parcel while it blocks the light barrier
	# (ROU_006: parcel-specific command is sampled at the input light eye).
	if b is RigidBody3D:
		_parcels[b] = _pick_divert()


func _on_lb_body_exited(b: Node) -> void:
	_lb_bodies.erase(b)


## Deck sensor spans the whole roller matrix; tracks which parcels are on it so the
## divert wave knows which lines to switch. Built as an internal child.
func _build_deck_sensor() -> void:
	if is_instance_valid(_deck_sensor):
		_deck_sensor.queue_free()
	var decks: Array = _find_all(func(n: Node) -> bool: return n is MeshInstance3D and n.name.contains("_Deck"))
	if decks.is_empty():
		return
	var min_x: float = 1e9
	var max_x: float = -1e9
	var min_z: float = 1e9
	var max_z: float = -1e9
	var top: float = 0.9
	for d: Node in decks:
		var la: AABB = _to_local_aabb(_mesh_world_aabb(d as MeshInstance3D))
		min_x = minf(min_x, la.position.x); max_x = maxf(max_x, la.position.x + la.size.x)
		min_z = minf(min_z, la.position.z); max_z = maxf(max_z, la.position.z + la.size.z)
		top = maxf(top, la.position.y + la.size.y)
	var area := Area3D.new()
	area.name = "_DeckSensor"
	area.collision_mask = BOX_COLLISION_MASK
	area.monitoring = true
	add_child(area, false, Node.INTERNAL_MODE_FRONT)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(0.1, max_x - min_x), 0.5, maxf(0.1, max_z - min_z))
	col.shape = shape
	area.add_child(col)
	area.position = Vector3((min_x + max_x) * 0.5, top + 0.22, (min_z + max_z) * 0.5)
	if not area.body_entered.is_connected(_on_deck_body_entered):
		area.body_entered.connect(_on_deck_body_entered)
	if not area.body_exited.is_connected(_on_deck_body_exited):
		area.body_exited.connect(_on_deck_body_exited)
	_deck_sensor = area


func _on_deck_body_entered(b: Node) -> void:
	# Fallback latch (if the parcel never tripped the light barrier, e.g. dropped on).
	if b is RigidBody3D and not _parcels.has(b):
		_parcels[b] = _pick_divert()


func _on_deck_body_exited(b: Node) -> void:
	if b is RigidBody3D:
		_parcels.erase(b)


## Target pivot angle for the line at local X, summed over the parcels currently on it.
func _line_target_angle(x: float, pitch: float) -> float:
	var best: float = 0.0
	for p: Variant in _parcels.keys():
		if not is_instance_valid(p):
			continue
		var d: int = _parcels[p]
		if d == int(DivertDir.STRAIGHT):
			continue
		var plx: float = (global_transform.affine_inverse() * (p as Node3D).global_position).x
		if x < plx - PARCEL_COVERAGE or x > plx + PARCEL_COVERAGE:
			continue
		# Curved divert: ramp the angle over `curve_distance` lines from the leading edge.
		var lines_from_lead: float = (plx + PARCEL_COVERAGE - x) / pitch
		var ramp: float = clampf(lines_from_lead / float(maxi(1, curve_distance)), 0.0, 1.0)
		var ang: float = max_divert_angle * ramp
		var signed: float = ang if d == int(DivertDir.LEFT) else -ang
		if absf(signed) > absf(best):
			best = signed
	# Aligner mode applies a gentle constant angle when nothing is actively diverting.
	if best == 0.0 and align_to != AlignTo.NONE:
		best = align_angle if align_to == AlignTo.LEFT else -align_angle
	return best


#endregion


#region Side guards ---------------------------------------------------------------
func _update_guards() -> void:
	# Free any previously-built guard collision bodies first, so a disabled guard never
	# leaves a stale invisible blocker behind. NOTE: get_children(true) -- the guard
	# bodies are INTERNAL children, which plain get_children() does NOT return.
	for c: Node in get_children(true):
		if c is StaticBody3D and (c as StaticBody3D).name.begins_with("_GuardBody_"):
			c.queue_free()
	_guards.clear()
	_resolve_guard("left", "_Guard_Left", left_guard_enabled)
	_resolve_guard("right", "_Guard_Right", right_guard_enabled)
	_resolve_guard("infeed", "_Guard_Infeed", infeed_guard_enabled)


func _resolve_guard(key: String, suffix: String, enabled: bool) -> void:
	var rec: Dictionary = _guards.get(key, {})
	var visual: MeshInstance3D = rec.get("visual", null)
	if not is_instance_valid(visual):
		visual = _find_one(func(n: Node) -> bool: return n is MeshInstance3D and n.name.ends_with(suffix)) as MeshInstance3D
		rec["visual"] = visual
	if is_instance_valid(visual):
		visual.visible = enabled
		# Build a collision body ONLY when the guard is ON. When OFF, NO body exists at all
		# (the previous one was already freed in _update_guards), so a disabled guard can
		# NEVER block a diverting box — more robust than toggling CollisionShape3D.disabled.
		if enabled:
			rec["body"] = _make_guard_body(visual)
		else:
			rec["body"] = null
	_guards[key] = rec


func _make_guard_body(mi: MeshInstance3D) -> StaticBody3D:
	var la: AABB = _to_local_aabb(_mesh_world_aabb(mi))
	var body := StaticBody3D.new()
	body.name = "_GuardBody_%s" % mi.name
	add_child(body, false, Node.INTERNAL_MODE_FRONT)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(0.02, la.size.x), maxf(0.02, la.size.y), maxf(0.02, la.size.z))
	col.shape = shape
	body.add_child(col)
	body.position = la.get_center()
	return body
#endregion


#region Legs ----------------------------------------------------------------------
func _rebuild_legs() -> void:
	for old_leg: Node3D in _legs:
		if is_instance_valid(old_leg):
			old_leg.queue_free()
	_legs.clear()
	if not legs_enabled or leg_model_scene == null:
		return
	var bodynode: MeshInstance3D = _find_one(func(n: Node) -> bool: return n is MeshInstance3D and n.name.ends_with("_Body") and not n.name.contains("Cabinet")) as MeshInstance3D
	if not is_instance_valid(bodynode):
		return
	var la: AABB = _to_local_aabb(_mesh_world_aabb(bodynode))
	var body_bottom: float = la.position.y
	var leg_h: float = maxf(0.1, body_bottom)              # floor (local y=0) -> body bottom
	var x0: float = la.position.x + 0.18
	var x1: float = la.position.x + la.size.x - 0.18
	var z_centre: float = la.position.z + la.size.z * 0.5
	# Each StraightLeg is a full-width frame (two posts + base), sized by scale.z = half width
	# -- so place ONE per X at the body centre, exactly like a belt conveyor (not two per X).
	var half_w: float = maxf(0.1, la.size.z * 0.5)
	var xs: Array[float] = [x0, x1]
	if (x1 - x0) > 1.6:
		xs.insert(1, (x0 + x1) * 0.5)
	if (x1 - x0) > 3.2:
		xs.insert(2, x0 + (x1 - x0) * 0.66)
		xs.insert(1, x0 + (x1 - x0) * 0.33)
	var idx: int = 0
	for lx: float in xs:
		var leg: Node3D = leg_model_scene.instantiate() as Node3D
		if leg == null:
			continue
		leg.name = "_Leg_%d" % idx
		idx += 1
		add_child(leg, false, Node.INTERNAL_MODE_FRONT)
		leg.position = Vector3(lx, 0.0, z_centre)
		leg.scale = Vector3(1.0, leg_h, half_w)
		_legs.append(leg)
#endregion


#region Flow arrow ----------------------------------------------------------------
func _update_flow_arrow() -> void:
	if not is_inside_tree():
		return
	if is_instance_valid(_flow_arrow):
		FlowDirectionArrow.unregister(_flow_arrow)
		_flow_arrow.queue_free()
		_flow_arrow = null
	var deck_top: float = _deck_top_local()
	# create() positions the arrow at size.y/2 + 0.2, so pass size.y = 2*deck_top to
	# land it just above the deck; it points +X (flow) and is length size.x*0.6.
	var arrow: Node3D = FlowDirectionArrow.create(Vector3(_half_length * 2.0, deck_top * 2.0, _half_width * 2.0))
	add_child(arrow, false, Node.INTERNAL_MODE_FRONT)
	_flow_arrow = arrow
	FlowDirectionArrow.register(_flow_arrow)
#endregion


#region Snapping ------------------------------------------------------------------
func get_snap_features() -> Array:
	# Use `size` (authoritative) so features are correct even before _build runs.
	var by: float = _deck_top_local() + snap_height_offset   # deck top (incl leg lift) + fine-tune
	# Front/back ends snap a touch LOWER than the deck so boxes don't catch a lip at the
	# seam (a higher feature ref makes the snap seat the body lower — see ConveyorSnapping).
	var end_y: float = by + end_snap_drop
	var hl: float = size.x * 0.5
	var hw: float = size.z * 0.5
	return [
		{"shape": 0, "kind": &"straight_end_front", "local_pos": Vector3(hl, end_y, 0.0),
			"local_outward": Vector3(1, 0, 0), "end_name": &"front"},
		{"shape": 0, "kind": &"straight_end_back", "local_pos": Vector3(-hl, end_y, 0.0),
			"local_outward": Vector3(-1, 0, 0), "end_name": &"back"},
		{"shape": 1, "kind": &"straight_sideguard_left",
			"seg_start": Vector3(-hl, by, hw), "seg_end": Vector3(hl, by, hw),
			"seg_outward_local": Vector3(0, 0, 1)},
		{"shape": 1, "kind": &"straight_sideguard_right",
			"seg_start": Vector3(-hl, by, -hw), "seg_end": Vector3(hl, by, -hw),
			"seg_outward_local": Vector3(0, 0, -1)},
	]


func _deck_top_local() -> float:
	var d: Node = _find_one(func(n: Node) -> bool: return n is MeshInstance3D and n.name.contains("_Deck"))
	if d == null:
		return 0.9 + leg_extension
	var la: AABB = _to_local_aabb(_mesh_world_aabb(d as MeshInstance3D))
	return la.position.y + la.size.y
#endregion


#region Auto match (width + deck height) to neighbour conveyor --------------------
## Called by ConveyorSnapping when a neighbour part is placed/moved next to us
## (and from our own _notification when WE move).
func _request_connection_rebuild() -> void:
	if not is_inside_tree() or _match_pending:
		return
	_match_pending = true
	_do_match_neighbor.call_deferred()


func _do_match_neighbor() -> void:
	_match_pending = false
	if not is_inside_tree() or not auto_match_width:
		return
	var conv: Node3D = _nearest_conveyor()
	if conv == null:
		return
	# Match WIDTH only -- leg height stays where the user set it (default 1.1 m legs).
	var w: float = _conveyor_width(conv)
	if w > 0.0 and absf(w - size.z) > 0.02:
		size = Vector3(size.x, size.y, w)


func _conveyor_width(n: Node) -> float:
	if "width" in n:
		return float(n.get("width"))
	if "size" in n:
		return float((n.get("size") as Vector3).z)
	return 0.0


## Nearest conveyor-like part touching one of our ends, else null.
func _nearest_conveyor() -> Node3D:
	var root: Node = get_tree().get_edited_scene_root() if Engine.is_editor_hint() else null
	if root == null:
		root = get_tree().current_scene
	if root == null:
		root = get_tree().root
	if root == null:
		return null
	var dy: float = _deck_top_local()
	var my_front: Vector3 = global_transform * Vector3(size.x * 0.5, dy, 0.0)
	var my_back: Vector3 = global_transform * Vector3(-size.x * 0.5, dy, 0.0)
	var best: Node3D = null
	var best_d: float = 0.8
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n == self or n == _model or not (n is Node3D) or not n.is_inside_tree():
			continue
		if is_ancestor_of(n):
			continue
		if not (n.has_method("get_snap_features") or ("width" in n)):
			continue
		var n3: Node3D = n as Node3D
		var nx: float = 0.0
		if "size" in n:
			nx = float((n.get("size") as Vector3).x) * 0.5
		for e: Vector3 in [n3.global_transform * Vector3(nx, 0.0, 0.0), n3.global_transform * Vector3(-nx, 0.0, 0.0)]:
			var d: float = minf(my_front.distance_to(e), my_back.distance_to(e))
			if d < best_d:
				best_d = d
				best = n3
	return best
#endregion


#region Communications (ROU_006 subset) -------------------------------------------
@export_category("Communications")
@export var enable_comms: bool = false
@export var run_tag_group_name: String
@export_custom(0, "tag_group_enum") var run_tag_groups: String:
	set(value):
		run_tag_group_name = value
		run_tag_groups = value
## Command tag (READ): TRUE starts the sorter.[br]Datatype: [code]BOOL[/code]
@export var run_tag_name: String = ""
@export var fault_ack_tag_group_name: String
@export_custom(0, "tag_group_enum") var fault_ack_tag_groups: String:
	set(value):
		fault_ack_tag_group_name = value
		fault_ack_tag_groups = value
## Fault acknowledge / clear (READ).[br]AOI [code]VR_Outputs[1].5[/code] · [code]BOOL[/code]
@export var fault_ack_tag_name: String = ""
@export var div_right_tag_group_name: String
@export_custom(0, "tag_group_enum") var div_right_tag_groups: String:
	set(value):
		div_right_tag_group_name = value
		div_right_tag_groups = value
## Divert RIGHT command (READ).[br]AOI [code]VR_Outputs[8].2[/code] · [code]BOOL[/code]
@export var div_right_tag_name: String = ""
@export var div_left_tag_group_name: String
@export_custom(0, "tag_group_enum") var div_left_tag_groups: String:
	set(value):
		div_left_tag_group_name = value
		div_left_tag_groups = value
## Divert LEFT command (READ).[br]AOI [code]VR_Outputs[8].3[/code] · [code]BOOL[/code]
@export var div_left_tag_name: String = ""
@export var ready_tag_group_name: String
@export_custom(0, "tag_group_enum") var ready_tag_groups: String:
	set(value):
		ready_tag_group_name = value
		ready_tag_groups = value
## Ready / OK to start (WRITE).[br]AOI [code]VR_Inputs[1].1[/code] · [code]BOOL[/code]
@export var ready_tag_name: String = ""
@export var rtr_tag_group_name: String
@export_custom(0, "tag_group_enum") var rtr_tag_groups: String:
	set(value):
		rtr_tag_group_name = value
		rtr_tag_groups = value
## OK to feed parcels / ready-to-receive (WRITE).[br]AOI [code]VR_Inputs[1].2[/code] · [code]BOOL[/code]
@export var rtr_tag_name: String = ""
@export var running_tag_group_name: String
@export_custom(0, "tag_group_enum") var running_tag_groups: String:
	set(value):
		running_tag_group_name = value
		running_tag_groups = value
## Running in auto mode (WRITE).[br]AOI [code]VR_Inputs[1].3[/code] · [code]BOOL[/code]
@export var running_tag_name: String = ""
@export var fault_tag_group_name: String
@export_custom(0, "tag_group_enum") var fault_tag_groups: String:
	set(value):
		fault_tag_group_name = value
		fault_tag_groups = value
## Fault active (WRITE).[br]AOI [code]VR_Inputs[1].7[/code] · [code]BOOL[/code]
@export var fault_tag_name: String = ""
@export var lb_tag_group_name: String
@export_custom(0, "tag_group_enum") var lb_tag_groups: String:
	set(value):
		lb_tag_group_name = value
		lb_tag_groups = value
## Input light barrier B002 blocked (WRITE).[br]ROU_006 light barrier · [code]BOOL[/code]
@export var lb_tag_name: String = ""

# ---- per-pivot-line fault status (WRITE, one bit per line; AOI reads them per line) ----
## Pivot-line numbers (1..24) to SIMULATE as faulty -> their bits go to the PLC AOI
## (Pivot_Drive_Fault_Line.N / Pivot_Roller_Fault_Line.N). Empty = all lines healthy.
@export var faulted_lines: PackedInt32Array = PackedInt32Array():
	set(value):
		faulted_lines = value
		_write_fault_bytes()
@export var drive_fault_b1_tag_group_name: String
@export_custom(0, "tag_group_enum") var drive_fault_b1_tag_groups: String:
	set(value):
		drive_fault_b1_tag_group_name = value
		drive_fault_b1_tag_groups = value
## Pivot DRIVE fault, lines 1..8 (WRITE).[br]AOI [code]VR_Inputs[8][/code] · [code]SINT[/code]
@export var drive_fault_b1_tag_name: String = ""
@export var drive_fault_b2_tag_group_name: String
@export_custom(0, "tag_group_enum") var drive_fault_b2_tag_groups: String:
	set(value):
		drive_fault_b2_tag_group_name = value
		drive_fault_b2_tag_groups = value
## Pivot DRIVE fault, lines 9..16 (WRITE).[br]AOI [code]VR_Inputs[9][/code] · [code]SINT[/code]
@export var drive_fault_b2_tag_name: String = ""
@export var drive_fault_b3_tag_group_name: String
@export_custom(0, "tag_group_enum") var drive_fault_b3_tag_groups: String:
	set(value):
		drive_fault_b3_tag_group_name = value
		drive_fault_b3_tag_groups = value
## Pivot DRIVE fault, lines 17..24 (WRITE).[br]AOI [code]VR_Inputs[10][/code] · [code]SINT[/code]
@export var drive_fault_b3_tag_name: String = ""
@export var roller_fault_b1_tag_group_name: String
@export_custom(0, "tag_group_enum") var roller_fault_b1_tag_groups: String:
	set(value):
		roller_fault_b1_tag_group_name = value
		roller_fault_b1_tag_groups = value
## Pivot ROLLER fault, lines 1..8 (WRITE).[br]AOI [code]VR_Inputs[16][/code] · [code]SINT[/code]
@export var roller_fault_b1_tag_name: String = ""
@export var roller_fault_b2_tag_group_name: String
@export_custom(0, "tag_group_enum") var roller_fault_b2_tag_groups: String:
	set(value):
		roller_fault_b2_tag_group_name = value
		roller_fault_b2_tag_groups = value
## Pivot ROLLER fault, lines 9..16 (WRITE).[br]AOI [code]VR_Inputs[17][/code] · [code]SINT[/code]
@export var roller_fault_b2_tag_name: String = ""
@export var roller_fault_b3_tag_group_name: String
@export_custom(0, "tag_group_enum") var roller_fault_b3_tag_groups: String:
	set(value):
		roller_fault_b3_tag_group_name = value
		roller_fault_b3_tag_groups = value
## Pivot ROLLER fault, lines 17..24 (WRITE).[br]AOI [code]VR_Inputs[18][/code] · [code]SINT[/code]
@export var roller_fault_b3_tag_name: String = ""

var _run_tag: OIPCommsTag = OIPCommsTag.new()
var _fault_ack_tag: OIPCommsTag = OIPCommsTag.new()
var _div_right_tag: OIPCommsTag = OIPCommsTag.new()
var _div_left_tag: OIPCommsTag = OIPCommsTag.new()
var _ready_tag: OIPCommsTag = OIPCommsTag.new()
var _rtr_tag: OIPCommsTag = OIPCommsTag.new()
var _running_tag: OIPCommsTag = OIPCommsTag.new()
var _fault_tag: OIPCommsTag = OIPCommsTag.new()
var _lb_tag: OIPCommsTag = OIPCommsTag.new()
var _drive_fault_tags: Array[OIPCommsTag] = [OIPCommsTag.new(), OIPCommsTag.new(), OIPCommsTag.new()]
var _roller_fault_tags: Array[OIPCommsTag] = [OIPCommsTag.new(), OIPCommsTag.new(), OIPCommsTag.new()]


func _validate_property(property: Dictionary) -> void:
	for spec: Array in [
			["run_tag_group_name", "run_tag_groups", "run_tag_name"],
			["fault_ack_tag_group_name", "fault_ack_tag_groups", "fault_ack_tag_name"],
			["div_right_tag_group_name", "div_right_tag_groups", "div_right_tag_name"],
			["div_left_tag_group_name", "div_left_tag_groups", "div_left_tag_name"],
			["ready_tag_group_name", "ready_tag_groups", "ready_tag_name"],
			["rtr_tag_group_name", "rtr_tag_groups", "rtr_tag_name"],
			["running_tag_group_name", "running_tag_groups", "running_tag_name"],
			["fault_tag_group_name", "fault_tag_groups", "fault_tag_name"],
			["lb_tag_group_name", "lb_tag_groups", "lb_tag_name"],
			["drive_fault_b1_tag_group_name", "drive_fault_b1_tag_groups", "drive_fault_b1_tag_name"],
			["drive_fault_b2_tag_group_name", "drive_fault_b2_tag_groups", "drive_fault_b2_tag_name"],
			["drive_fault_b3_tag_group_name", "drive_fault_b3_tag_groups", "drive_fault_b3_tag_name"],
			["roller_fault_b1_tag_group_name", "roller_fault_b1_tag_groups", "roller_fault_b1_tag_name"],
			["roller_fault_b2_tag_group_name", "roller_fault_b2_tag_groups", "roller_fault_b2_tag_name"],
			["roller_fault_b3_tag_group_name", "roller_fault_b3_tag_groups", "roller_fault_b3_tag_name"]]:
		if OIPCommsSetup.validate_tag_property(property, str(spec[0]), str(spec[1]), str(spec[2])):
			return


func _comms_enter() -> void:
	run_tag_group_name = OIPCommsSetup.default_tag_group(run_tag_group_name)
	fault_ack_tag_group_name = OIPCommsSetup.default_tag_group(fault_ack_tag_group_name)
	div_right_tag_group_name = OIPCommsSetup.default_tag_group(div_right_tag_group_name)
	div_left_tag_group_name = OIPCommsSetup.default_tag_group(div_left_tag_group_name)
	ready_tag_group_name = OIPCommsSetup.default_tag_group(ready_tag_group_name)
	rtr_tag_group_name = OIPCommsSetup.default_tag_group(rtr_tag_group_name)
	running_tag_group_name = OIPCommsSetup.default_tag_group(running_tag_group_name)
	fault_tag_group_name = OIPCommsSetup.default_tag_group(fault_tag_group_name)
	lb_tag_group_name = OIPCommsSetup.default_tag_group(lb_tag_group_name)
	drive_fault_b1_tag_group_name = OIPCommsSetup.default_tag_group(drive_fault_b1_tag_group_name)
	drive_fault_b2_tag_group_name = OIPCommsSetup.default_tag_group(drive_fault_b2_tag_group_name)
	drive_fault_b3_tag_group_name = OIPCommsSetup.default_tag_group(drive_fault_b3_tag_group_name)
	roller_fault_b1_tag_group_name = OIPCommsSetup.default_tag_group(roller_fault_b1_tag_group_name)
	roller_fault_b2_tag_group_name = OIPCommsSetup.default_tag_group(roller_fault_b2_tag_group_name)
	roller_fault_b3_tag_group_name = OIPCommsSetup.default_tag_group(roller_fault_b3_tag_group_name)
	if not Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.connect(_on_simulation_started)
	if not Simulation.stopped.is_connected(_on_simulation_ended):
		Simulation.stopped.connect(_on_simulation_ended)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _comms_exit() -> void:
	if Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.disconnect(_on_simulation_started)
	if Simulation.stopped.is_connected(_on_simulation_ended):
		Simulation.stopped.disconnect(_on_simulation_ended)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _on_simulation_started() -> void:
	_sim_active = true   # set even when comms is off, so the VR conveys during the sim
	if not enable_comms:
		return
	_run_tag.register(run_tag_group_name, run_tag_name, OIPCommsTag.TYPE_BOOL)
	_fault_ack_tag.register(fault_ack_tag_group_name, fault_ack_tag_name, OIPCommsTag.TYPE_BOOL)
	_div_right_tag.register(div_right_tag_group_name, div_right_tag_name, OIPCommsTag.TYPE_BOOL)
	_div_left_tag.register(div_left_tag_group_name, div_left_tag_name, OIPCommsTag.TYPE_BOOL)
	_ready_tag.register(ready_tag_group_name, ready_tag_name, OIPCommsTag.TYPE_BOOL)
	_rtr_tag.register(rtr_tag_group_name, rtr_tag_name, OIPCommsTag.TYPE_BOOL)
	_running_tag.register(running_tag_group_name, running_tag_name, OIPCommsTag.TYPE_BOOL)
	_fault_tag.register(fault_tag_group_name, fault_tag_name, OIPCommsTag.TYPE_BOOL)
	_lb_tag.register(lb_tag_group_name, lb_tag_name, OIPCommsTag.TYPE_BOOL)
	_drive_fault_tags[0].register(drive_fault_b1_tag_group_name, drive_fault_b1_tag_name, OIPCommsTag.TYPE_UINT8)
	_drive_fault_tags[1].register(drive_fault_b2_tag_group_name, drive_fault_b2_tag_name, OIPCommsTag.TYPE_UINT8)
	_drive_fault_tags[2].register(drive_fault_b3_tag_group_name, drive_fault_b3_tag_name, OIPCommsTag.TYPE_UINT8)
	_roller_fault_tags[0].register(roller_fault_b1_tag_group_name, roller_fault_b1_tag_name, OIPCommsTag.TYPE_UINT8)
	_roller_fault_tags[1].register(roller_fault_b2_tag_group_name, roller_fault_b2_tag_name, OIPCommsTag.TYPE_UINT8)
	_roller_fault_tags[2].register(roller_fault_b3_tag_group_name, roller_fault_b3_tag_name, OIPCommsTag.TYPE_UINT8)


func _on_simulation_ended() -> void:
	_sim_active = false   # stop conveying on sim stop, but KEEP `running` so it auto-runs on restart
	for body: StaticBody3D in _transport_bodies + _belt_bodies:
		if is_instance_valid(body):
			body.constant_linear_velocity = Vector3.ZERO
	_parcels.clear()


func _tag_group_initialized(group: String) -> void:
	if _run_tag.on_group_initialized(group):
		_last_run = _run_tag.read_bit()   # prime the edge detector with the resting value
	_fault_ack_tag.on_group_initialized(group)
	_div_right_tag.on_group_initialized(group)
	_div_left_tag.on_group_initialized(group)
	# Sim status: ready=TRUE and fault=FALSE are constant; running/rtr/lb track state.
	if _ready_tag.on_group_initialized(group):
		_ready_tag.write_bit(true)
	if _fault_tag.on_group_initialized(group):
		_fault_tag.write_bit(false)
	if _running_tag.on_group_initialized(group):
		_running_tag.write_bit(running)
	if _rtr_tag.on_group_initialized(group):
		_rtr_tag.write_bit(running)
	if _lb_tag.on_group_initialized(group):
		_lb_tag.write_bit(_lb_blocked)
	var any_fault_ready: bool = false
	for ft: OIPCommsTag in _drive_fault_tags + _roller_fault_tags:
		if ft.on_group_initialized(group):
			any_fault_ready = true
	if any_fault_ready:
		_write_fault_bytes()


## Encode `faulted_lines` into the six per-line fault bytes the AOI reads.
func _write_fault_bytes() -> void:
	var bytes: Array[int] = [0, 0, 0, 0, 0, 0]   # drive[1-8,9-16,17-24], roller[1-8,9-16,17-24]
	for ln: int in faulted_lines:
		if ln < 1 or ln > MAX_LINES:
			continue
		var bi: int = (ln - 1) >> 3            # byte index 0..2 (no integer division)
		var bit: int = (ln - 1) & 7
		bytes[bi] |= (1 << bit)
		bytes[3 + bi] |= (1 << bit)
	for i: int in 3:
		if _drive_fault_tags[i].is_ready():
			_drive_fault_tags[i].write_uint8(bytes[i])
		if _roller_fault_tags[i].is_ready():
			_roller_fault_tags[i].write_uint8(bytes[3 + i])


func _tag_group_polled(group: String) -> void:
	if not enable_comms:
		return
	if _run_tag.is_ready():
		var r: bool = _run_tag.read_bit()
		if r != _last_run:        # only act on a real change, so a disconnected/constant tag
			running = r           # never overrides a manually-set running
			_last_run = r
	# Per-parcel divert command (ROU_006 module digital control bits, set by the sort logic).
	var want: DivertDir = DivertDir.STRAIGHT
	if _div_right_tag.is_ready() and _div_right_tag.read_bit():
		want = DivertDir.RIGHT
	elif _div_left_tag.is_ready() and _div_left_tag.read_bit():
		want = DivertDir.LEFT
	if want != divert:
		divert = want
#endregion
