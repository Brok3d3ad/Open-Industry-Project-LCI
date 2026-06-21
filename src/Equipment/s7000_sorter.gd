@tool
class_name S7000Sorter
extends ResizableNode3D

## Intralox ARB S7000 Non-Con sorter — full resizable OIP conveyor part.
## size.x = length, size.y = height (leg lift), size.z = width (ResizableNode3D convention).
## The detailed end assemblies (Idle/Drive/Motor) ride the GLB child scale (hybrid); the
## belt deck / frame / guards stretch with it; the angled-roller MultiMesh, transport+divert
## StaticBody3D zones and the StraightLeg legs are procedural and rebuild from the live size.
## Rollers spin on the GPU (one draw call); a parcel is conveyed forward and an active divert
## zone angles its surface velocity toward its chute (the ARB sort). Chutes snap to it.

@export var running: bool = true:
	set(v):
		running = v
		_apply_drive()
@export_range(0.0, 2.5, 0.05, "suffix:m/s") var belt_speed: float = 1.067
@export_range(15.0, 45.0, 1.0, "suffix:deg") var divert_angle_deg: float = 45.0
@export_range(0.03, 0.12, 0.002, "suffix:m") var roller_pitch: float = 0.06:
	set(v):
		roller_pitch = v
		if _ready_done:
			_build_rollers()
@export_range(0.0, 20.0, 0.5) var roller_spin_speed: float = 8.0
@export var auto_sort: bool = true
@export_enum("Off:0", "Round-robin:1", "All Left:2", "All Right:3") var sort_mode: int = 1
@export var surface_friction: float = 1.4
@export var legs_enabled: bool = true:
	set(v):
		legs_enabled = v
		if _ready_done:
			_rebuild_legs()
@export var leg_model_scene: PackedScene = preload("res://parts/StraightLeg.tscn")
@export_range(0.6, 4.5, 0.01, "suffix:m") var processing_height: float = 1.7221:
	set(v):
		processing_height = clampf(v, AUTHORED_TOB + MIN_EXTENSION, AUTHORED_TOB + MAX_EXTENSION)
		leg_extension = processing_height - AUTHORED_TOB
		if not _syncing and _ready_done and _base_height > 0.0:
			_syncing = true
			size = Vector3(_base_length * _len_scale, _base_height + leg_extension, _base_width * _wid_scale)
			_syncing = false
			_apply_size()

const GLB_PATH: String = "res://assets/3DModels/Equipment/arb_s7000.glb"
const DEFAULT_LENGTH: float = 25.98
const AUTHORED_WIDTH: float = 1.0922
const AUTHORED_TOB: float = 1.7221
const MIN_LENGTH: float = 4.0
const MIN_WIDTH: float = 0.8
const MIN_EXTENSION: float = -0.25
const MAX_EXTENSION: float = 2.8
const DIVERT_ZONE_LEN: float = 2.286
const BELT_LAYER_BIT: int = 1 << 2
const BOX_LAYER_BIT: int = 1 << 3
const STATIONS: Array = [
	{"x": 12.66, "sides": "L"}, {"x": 25.0, "sides": "LR"},
	{"x": 37.2, "sides": "LR"}, {"x": 49.5, "sides": "LR"},
]

var leg_extension: float = 0.0
var _ready_done: bool = false
var _syncing: bool = false
var _model: Node3D
var _base_length: float = 0.0
var _base_width: float = 0.0
var _base_height: float = 0.0
var _deck_top_base: float = AUTHORED_TOB
var _len_scale: float = 1.0
var _wid_scale: float = 1.0
var _mm_inst: MultiMeshInstance3D
var _mm: MultiMesh
var _shader_mat: ShaderMaterial
var _zones: Array = []
var _segments: Array = []
var _legs: Array = []
var _zone_of_instance: PackedInt32Array = PackedInt32Array()
var _sort_targets: Array = []
var _sort_counter: int = 0


func _init() -> void:
	super._init()
	size_default = Vector3(DEFAULT_LENGTH, AUTHORED_TOB + 0.3, AUTHORED_WIDTH)   # native 43in (1.0922 m); 1.524 distorted the baked model
	size_min = Vector3(MIN_LENGTH, 0.4, MIN_WIDTH)


func _enter_tree() -> void:
	super._enter_tree()


func _exit_tree() -> void:
	super._exit_tree()
	if is_inside_tree():
		ConveyorSnapping.notify_contacts_rebuild(self)


func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		ConveyorSnapping.notify_contacts_rebuild(self)


func _ready() -> void:
	_model = get_node_or_null("Model") as Node3D
	if _model == null:
		for c: Node in get_children():
			if c is Node3D and (c as Node3D).find_child("Belt_Surface", true, false) != null:
				_model = c as Node3D
				break
	if _model == null:
		var ps: PackedScene = load(GLB_PATH) as PackedScene
		if ps != null:
			_model = ps.instantiate() as Node3D
			_model.name = "Model"
			add_child(_model)
			_model.owner = null
	if _model == null:
		push_warning("S7000Sorter: arb_s7000.glb not found / not imported yet.")
		return
	_measure_base()
	_apply_materials()
	# fresh instance (model scale untouched) defaults to the halved length
	if absf(_model.scale.x - 1.0) < 0.001 and _base_length > 0.0:
		_len_scale = DEFAULT_LENGTH / _base_length
	# Set the authoritative `size` BEFORE building, so rollers/physics/legs are sized correctly
	# on the very first spawn (size starts at ZERO; without this the first build is empty until
	# the user nudges a resize handle).
	if _base_height > 0.0:
		_syncing = true
		size = Vector3(_base_length * _len_scale, _base_height + leg_extension, _base_width * _wid_scale)
		_syncing = false
	_apply_size()
	_build_rollers()
	_build_physics()
	_build_sort_targets()
	_rebuild_legs()
	_ready_done = true
	_apply_drive()
	set_physics_process(true)
	if is_inside_tree():
		ConveyorSnapping.notify_contacts_rebuild(self)


#region resize (ResizableNode3D)
func _on_size_changed() -> void:
	if _syncing or _base_height <= 0.0:
		return
	_syncing = true
	_len_scale = size.x / _base_length if _base_length > 0.0 else 1.0
	_wid_scale = size.z / _base_width if _base_width > 0.0 else 1.0
	leg_extension = size.y - _base_height
	processing_height = leg_extension + AUTHORED_TOB
	_syncing = false
	if _ready_done:
		_apply_size()


func _get_constrained_size(new_size: Vector3) -> Vector3:
	if _base_height <= 0.0:
		return new_size
	return Vector3(
		maxf(MIN_LENGTH, new_size.x),
		clampf(new_size.y, _base_height + MIN_EXTENSION, _base_height + MAX_EXTENSION),
		maxf(MIN_WIDTH, new_size.z))


func _get_resize_local_bounds(for_size: Vector3) -> AABB:
	# tail-anchored: idle end at x=0, drive end at x=length (geometry spans [0,length])
	return AABB(Vector3(0.0, 0.0, -for_size.z * 0.5), for_size)


func _measure_base() -> void:
	if not is_instance_valid(_model):
		return
	var msc: Vector3 = _model.scale
	if msc.x == 0.0 or msc.y == 0.0 or msc.z == 0.0:
		msc = Vector3.ONE
	var lift: float = _model.position.y
	var mn: Vector3 = Vector3(1e9, 1e9, 1e9)
	var mx: Vector3 = Vector3(-1e9, -1e9, -1e9)
	for mi: MeshInstance3D in _all_meshes():
		var a: AABB = _to_local_aabb(_mesh_world_aabb(mi))
		mn = mn.min(a.position)
		mx = mx.max(a.position + a.size)
	_base_height = (mx.y - mn.y) / msc.y
	var belt: Node = _find_mesh("Belt_Surface")
	if belt is MeshInstance3D:
		var ba: AABB = _to_local_aabb(_mesh_world_aabb(belt as MeshInstance3D))
		_base_length = ba.size.x / msc.x
		_base_width = ba.size.z / msc.z
		_deck_top_base = (ba.position.y + ba.size.y - lift) / msc.y
	else:
		_base_length = (mx.x - mn.x) / msc.x
		_base_width = (mx.z - mn.z) / msc.z
		_deck_top_base = AUTHORED_TOB
	_len_scale = msc.x
	_wid_scale = msc.z


func _apply_size() -> void:
	if not is_instance_valid(_model):
		return
	_model.scale = Vector3(_len_scale, 1.0, _wid_scale)
	_model.position.y = leg_extension
	if _ready_done:
		_build_rollers()
		_build_physics()
		_build_sort_targets()
		_rebuild_legs()
		_apply_drive()


func _belt_top_local() -> float:
	return _deck_top_base + leg_extension
#endregion


#region model helpers
func _all_meshes() -> Array:
	var acc: Array = []
	_find_all_rec(self, acc)
	return acc


func _find_all_rec(node: Node, acc: Array) -> void:
	for c: Node in node.get_children():
		if c is MeshInstance3D:
			acc.append(c)
		_find_all_rec(c, acc)


func _find_mesh(node_name: String) -> Node:
	if _model == null:
		return null
	return _model.find_child(node_name, true, false)


func _mesh_world_aabb(mi: MeshInstance3D) -> AABB:
	var local_box: AABB = mi.get_aabb()
	var xf: Transform3D = mi.global_transform
	var a: AABB = AABB(xf * local_box.get_endpoint(0), Vector3.ZERO)
	for i: int in range(1, 8):
		a = a.expand(xf * local_box.get_endpoint(i))
	return a


func _to_local_aabb(world: AABB) -> AABB:
	var inv: Transform3D = global_transform.affine_inverse()
	var a: AABB = AABB(inv * world.get_endpoint(0), Vector3.ZERO)
	for i: int in range(1, 8):
		a = a.expand(inv * world.get_endpoint(i))
	return a
#endregion


#region materials
func _apply_materials() -> void:
	if _model == null:
		return
	var conv_mat: Material = ConveyorFrameMesh.create_material()
	var stack: Array = [_model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var nm: String = String(mi.name)
			if nm == "Legs_All":
				mi.visible = false           # replaced by procedural StraightLeg legs
				continue
			var mat: Material
			if conv_mat != null and _is_structural(nm):
				mat = conv_mat
			else:
				mat = _mat_for(nm)
			var count: int = maxi(1, mi.get_surface_override_material_count())
			for si: int in count:
				mi.set_surface_override_material(si, mat)


func _is_structural(nm: String) -> bool:
	return nm.contains("Guard") or nm.contains("SideWall") \
		or nm.contains("Frame_Rail") or nm.contains("Frame_Cross") or nm.contains("Endplate")


func _mat_for(nm: String) -> StandardMaterial3D:
	var c: Color = Color(0.74, 0.74, 0.73)
	var rough: float = 0.55
	if nm.contains("Lens"):
		c = Color(0.55, 0.12, 0.10); rough = 0.15
	elif nm.contains("Sprocket"):
		c = Color(0.34, 0.34, 0.36); rough = 0.45
	elif nm.contains("Shaft"):
		c = Color(0.40, 0.40, 0.42); rough = 0.42
	elif nm.contains("Bearing"):
		c = Color(0.30, 0.30, 0.32); rough = 0.50
	elif nm.contains("Brush"):
		c = Color(0.14, 0.12, 0.10); rough = 0.95
	elif nm.contains("FanCover") or nm.contains("AirPrep"):
		c = Color(0.70, 0.70, 0.72); rough = 0.40
	elif nm.contains("Motor"):
		c = Color(0.33, 0.33, 0.35); rough = 0.45
	elif nm.contains("Festo") or nm.contains("Manifold") or nm.contains("AirBowl"):
		c = Color(0.10, 0.28, 0.55); rough = 0.42
	elif nm.contains("RnR"):
		c = Color(0.46, 0.46, 0.48); rough = 0.50
	elif nm.contains("Encoder"):
		c = Color(0.07, 0.08, 0.12); rough = 0.45
	elif nm.contains("Post"):
		c = Color(0.74, 0.74, 0.73); rough = 0.55
	elif nm.contains("Sensor"):
		c = Color(0.07, 0.08, 0.12); rough = 0.40
	elif nm.contains("CableTray"):
		c = Color(0.66, 0.66, 0.69); rough = 0.50
	elif nm.contains("Cover"):
		c = Color(0.34, 0.34, 0.35); rough = 0.85
	elif nm.contains("Belt_Surface"):
		c = Color(0.05, 0.06, 0.11); rough = 0.80
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = 0.0
	m.roughness = rough
	return m
#endregion


#region rollers (MultiMesh + spin shader)
func _make_roller_mesh() -> ArrayMesh:
	var segs: int = 12
	var r: float = 0.018
	var rc: float = r * 0.74
	var hl: float = 0.025
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
		p0.append(Vector3(rc * ca, -hl, rc * sa))
		p1.append(Vector3(r * ca, 0.0, r * sa))
		p2.append(Vector3(rc * ca, hl, rc * sa))
		nr.append(Vector3(ca, 0.0, sa))
	for i: int in segs:
		var j: int = (i + 1) % segs
		_band(st, p0[i], p1[i], p1[j], p0[j], nr[i], nr[j])
		_band(st, p1[i], p2[i], p2[j], p1[j], nr[i], nr[j])
	var top: Vector3 = Vector3(0, hl, 0)
	var bot: Vector3 = Vector3(0, -hl, 0)
	for i: int in segs:
		var j: int = (i + 1) % segs
		_cap(st, bot, p0[j], p0[i], Vector3(0, -1, 0))
		_cap(st, top, p2[i], p2[j], Vector3(0, 1, 0))
	return st.commit()


func _band(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nc: Vector3) -> void:
	st.set_normal(na); st.add_vertex(a)
	st.set_normal(na); st.add_vertex(b)
	st.set_normal(nc); st.add_vertex(c)
	st.set_normal(na); st.add_vertex(a)
	st.set_normal(nc); st.add_vertex(c)
	st.set_normal(nc); st.add_vertex(d)


func _cap(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	st.set_normal(n); st.add_vertex(a)
	st.set_normal(n); st.add_vertex(b)
	st.set_normal(n); st.add_vertex(c)


func _build_rollers() -> void:
	if _mm_inst == null:
		_mm_inst = MultiMeshInstance3D.new()
		_mm_inst.name = "RollerField"
		add_child(_mm_inst)
		_mm_inst.owner = null
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _make_roller_mesh()
	var length: float = size.x
	var width: float = size.z
	var half_w: float = width * 0.5
	var btop: float = _belt_top_local()
	var nz: int = maxi(1, int(round(width / roller_pitch)))
	var nx: int = maxi(1, int(round(length / roller_pitch)))
	_mm.instance_count = nx * nz
	var ori: Basis = Basis(Vector3(0, 1, 0), deg_to_rad(45.0)) * Basis(Vector3(1, 0, 0), deg_to_rad(-90.0))
	_zone_of_instance = PackedInt32Array()
	_zone_of_instance.resize(_mm.instance_count)
	var idx: int = 0
	for ix: int in nx:
		var x: float = (float(ix) + 0.5) * roller_pitch
		var zi: int = _zone_index_at(x)
		for iz: int in nz:
			var z: float = -half_w + (float(iz) + 0.5) * roller_pitch
			_mm.set_instance_transform(idx, Transform3D(ori, Vector3(x, btop, z)))
			_mm.set_instance_custom_data(idx, Color(0.0, float(idx % 7) / 7.0, 0.0, 0.0))
			_zone_of_instance[idx] = zi
			idx += 1
	_mm_inst.multimesh = _mm
	_make_shader()
	_mm_inst.material_override = _shader_mat


func _make_shader() -> void:
	if _shader_mat != null:
		return
	var sh: Shader = Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
uniform float u_speed = 8.0;
uniform vec3 u_albedo : source_color = vec3(0.66, 0.66, 0.67);
void vertex() {
	float active = INSTANCE_CUSTOM.x;
	float phase  = INSTANCE_CUSTOM.y * 6.2831853;
	float ang = (TIME * u_speed) * mix(1.0, 2.4, active) + phase;
	float c = cos(ang); float s = sin(ang);
	vec3 p = VERTEX;
	VERTEX = vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
	vec3 n = NORMAL;
	NORMAL = vec3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
}
void fragment() {
	ALBEDO = u_albedo;
	ROUGHNESS = 0.36;
	METALLIC = 0.0;
}
"""
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = sh
	_shader_mat.set_shader_parameter("u_speed", roller_spin_speed)


func _set_zone_rollers_active(zone_i: int, on: bool) -> void:
	if _mm == null:
		return
	var val: float = 1.0 if on else 0.0
	for i: int in _zone_of_instance.size():
		if _zone_of_instance[i] == zone_i:
			var cd: Color = _mm.get_instance_custom_data(i)
			_mm.set_instance_custom_data(i, Color(val, cd.g, 0.0, 0.0))
#endregion


#region physics (transport segments + divert zones)
func _zone_index_at(x: float) -> int:
	for z_i: int in STATIONS.size():
		var st: Dictionary = STATIONS[z_i]
		var cx: float = float(st["x"])
		if absf(x - cx) <= DIVERT_ZONE_LEN * 0.5:
			return z_i
	return -1


func _build_physics() -> void:
	for z: Dictionary in _zones:
		var zb: Variant = z.get("body")
		if zb is Node:
			(zb as Node).queue_free()
		var za: Variant = z.get("area")
		if za is Node:
			(za as Node).queue_free()
	for s: Node in _segments:
		s.queue_free()
	_zones.clear()
	_segments.clear()

	var length: float = size.x
	var width: float = size.z
	var pmat: PhysicsMaterial = PhysicsMaterial.new()
	pmat.friction = surface_friction
	pmat.rough = true
	pmat.bounce = 0.0

	for z_i: int in STATIONS.size():
		var st: Dictionary = STATIONS[z_i]
		var cx: float = float(st["x"])
		if cx > length:
			continue
		var x0: float = maxf(0.0, cx - DIVERT_ZONE_LEN * 0.5)
		var x1: float = minf(length, cx + DIVERT_ZONE_LEN * 0.5)
		var body: StaticBody3D = _make_belt_body("DivertZone_%d" % z_i, x0, x1, width, pmat)
		var area: Area3D = _make_zone_area("DivertArea_%d" % z_i, x0, x1, width)
		_zones.append({"x0": x0, "x1": x1, "sides": String(st["sides"]),
			"body": body, "area": area, "active_side": ""})

	var bounds: Array = [0.0]
	for z: Dictionary in _zones:
		bounds.append(float(z["x0"]))
		bounds.append(float(z["x1"]))
	bounds.append(length)
	bounds.sort()
	var k: int = 0
	while k + 1 < bounds.size():
		var a: float = float(bounds[k])
		var b: float = float(bounds[k + 1])
		if b - a > 0.05 and _zone_index_at((a + b) * 0.5) == -1:
			_segments.append(_make_belt_body("Transport_%d" % k, a, b, width, pmat))
		k += 1
	_make_infeed_area(width)


func _make_belt_body(nm: String, x0: float, x1: float, width: float, pmat: PhysicsMaterial) -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	body.name = nm
	body.collision_layer = BELT_LAYER_BIT
	body.collision_mask = 0
	body.physics_material_override = pmat
	add_child(body)
	body.owner = null
	var col: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(maxf(0.02, x1 - x0), 0.04, width)
	col.shape = shape
	col.position = Vector3((x0 + x1) * 0.5, _belt_top_local() - 0.02, 0.0)
	body.add_child(col)
	return body


func _make_zone_area(nm: String, x0: float, x1: float, width: float) -> Area3D:
	var area: Area3D = Area3D.new()
	area.name = nm
	area.collision_layer = 0
	area.collision_mask = BOX_LAYER_BIT
	add_child(area)
	area.owner = null
	var col: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(maxf(0.02, x1 - x0), 0.5, width)
	col.shape = shape
	col.position = Vector3((x0 + x1) * 0.5, _belt_top_local() + 0.20, 0.0)
	area.add_child(col)
	return area


func _make_infeed_area(width: float) -> void:
	var area: Area3D = get_node_or_null("InfeedTagger") as Area3D
	if area != null:
		area.queue_free()
	area = Area3D.new()
	area.name = "InfeedTagger"
	area.collision_layer = 0
	area.collision_mask = BOX_LAYER_BIT
	add_child(area)
	area.owner = null
	var col: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(0.6, 0.6, width)
	col.shape = shape
	col.position = Vector3(0.6, _belt_top_local() + 0.25, 0.0)
	area.add_child(col)
	area.body_entered.connect(_on_infeed_body)
#endregion


#region drive + sort
func _build_sort_targets() -> void:
	_sort_targets.clear()
	for z_i: int in _zones.size():
		var zd: Dictionary = _zones[z_i]
		var sides: String = String(zd["sides"])
		if sides.contains("L"):
			_sort_targets.append({"zone": z_i, "side": "L"})
		if sides.contains("R"):
			_sort_targets.append({"zone": z_i, "side": "R"})


func _on_infeed_body(body: Node3D) -> void:
	if not (body is RigidBody3D):
		return
	if body.has_meta("s7000_target_zone"):
		return
	var tz: int = -1
	var ts: String = ""
	if sort_mode == 1 and not _sort_targets.is_empty():
		var t: Dictionary = _sort_targets[_sort_counter % _sort_targets.size()]
		_sort_counter += 1
		tz = int(t["zone"]); ts = String(t["side"])
	elif sort_mode == 2 or sort_mode == 3:
		var want: String = "L" if sort_mode == 2 else "R"
		for z_i: int in _zones.size():
			var zd: Dictionary = _zones[z_i]
			if String(zd["sides"]).contains(want):
				tz = z_i; ts = want
				break
	body.set_meta("s7000_target_zone", tz)
	body.set_meta("s7000_target_side", ts)


func _flow_world() -> Vector3:
	return (global_transform.basis * Vector3(1, 0, 0)).normalized()


func _apply_drive() -> void:
	if not _ready_done:
		return
	var v: Vector3 = _flow_world() * (belt_speed if running else 0.0)
	for s: Variant in _segments:
		if s is StaticBody3D:
			(s as StaticBody3D).constant_linear_velocity = v
	for z: Dictionary in _zones:
		var b: Variant = z["body"]
		if b is StaticBody3D:
			(b as StaticBody3D).constant_linear_velocity = v


func _physics_process(_delta: float) -> void:
	if not _ready_done or _mm_inst == null:
		return
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("u_speed", roller_spin_speed if running else 0.0)
	if Engine.is_editor_hint() and not running:
		return
	var fwd: Vector3 = _flow_world() * (belt_speed if running else 0.0)
	var up: Vector3 = (global_transform.basis * Vector3(0, 1, 0)).normalized()
	for s: Variant in _segments:
		if s is StaticBody3D:
			(s as StaticBody3D).constant_linear_velocity = fwd
	for z_i: int in _zones.size():
		var zd: Dictionary = _zones[z_i]
		var body: StaticBody3D = zd["body"]
		var area: Area3D = zd["area"]
		if body == null or area == null:
			continue
		var want_side: String = ""
		if auto_sort and running:
			for b: Node3D in area.get_overlapping_bodies():
				if b is RigidBody3D and b.has_meta("s7000_target_zone"):
					if int(b.get_meta("s7000_target_zone")) == z_i:
						want_side = String(b.get_meta("s7000_target_side"))
						break
		if want_side != String(zd["active_side"]):
			zd["active_side"] = want_side
			_set_zone_rollers_active(z_i, want_side != "")
		if want_side == "":
			body.constant_linear_velocity = fwd
		else:
			var sign_s: float = 1.0 if want_side == "L" else -1.0
			var ang: float = deg_to_rad(divert_angle_deg) * sign_s
			body.constant_linear_velocity = fwd.rotated(up, ang)
#endregion


#region legs (procedural StraightLeg, floor-planted, conveyor look)
func _rebuild_legs() -> void:
	for old_leg: Node3D in _legs:
		if is_instance_valid(old_leg):
			old_leg.queue_free()
	_legs.clear()
	if not legs_enabled or leg_model_scene == null:
		return
	var length: float = size.x
	var half_w: float = maxf(0.1, size.z * 0.5)
	var leg_h: float = maxf(0.1, _belt_top_local() - 0.12)   # floor (y=0) up to just under the deck
	var inset: float = minf(0.6, length * 0.1)
	var xs: Array[float] = [inset, length - inset]
	var span: float = length - 2.0 * inset
	var n_mid: int = int(span / 2.4)
	for m: int in n_mid:
		xs.insert(1 + m, inset + span * float(m + 1) / float(n_mid + 1))
	var idx: int = 0
	for lx: float in xs:
		var leg: Node3D = leg_model_scene.instantiate() as Node3D
		if leg == null:
			continue
		leg.name = "_Leg_%d" % idx
		idx += 1
		add_child(leg, false, Node.INTERNAL_MODE_FRONT)
		leg.owner = null
		leg.position = Vector3(lx, 0.0, 0.0)
		leg.scale = Vector3(1.0, leg_h, half_w)
		_legs.append(leg)
#endregion


#region snapping
func get_snap_features() -> Array:
	var feats: Array = []
	var pulley: float = 0.0   # snap flush to the neighbour (no end-roller gap)
	var y: float = _belt_top_local()
	var length: float = size.x
	var hw: float = size.z * 0.5
	feats.append({
		"shape": ConveyorSnapFeatures.Shape.POINT, "kind": &"straight_end_back",
		"local_pos": Vector3(-pulley, y, 0.0), "local_outward": Vector3(-1, 0, 0), "end_name": &"back"})
	feats.append({
		"shape": ConveyorSnapFeatures.Shape.POINT, "kind": &"straight_end_front",
		"local_pos": Vector3(length + pulley, y, 0.0), "local_outward": Vector3(1, 0, 0), "end_name": &"front"})
	feats.append({
		"shape": ConveyorSnapFeatures.Shape.SEGMENT, "kind": &"straight_sideguard_left",
		"seg_start": Vector3(0.0, y, -hw), "seg_end": Vector3(length, y, -hw),
		"seg_outward_local": Vector3(0, 0, -1)})
	feats.append({
		"shape": ConveyorSnapFeatures.Shape.SEGMENT, "kind": &"straight_sideguard_right",
		"seg_start": Vector3(0.0, y, hw), "seg_end": Vector3(length, y, hw),
		"seg_outward_local": Vector3(0, 0, 1)})
	return feats
#endregion
