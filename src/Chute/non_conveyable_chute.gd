@tool
class_name NonConveyableChute
extends BeltConveyor

## Non-conveyable gravity chute built on the `BeltConveyor` base (like `Intralox`) purely to reuse
## its LEGS, side guards, frame rails, snapping and resize gizmo — NOT its belt motion.
##
## The flat belt mesh is hidden and a single FIXED chute bed (Non_Conveyable_Chute.glb) is placed
## over the deck. The bed does NOT tile, stretch or animate; it stays at its native size. The
## conveyor's `speed` is 0 so the surface is static. Raising / lowering the part grows the legs
## (they follow the floor), which is the only thing that changes.
##
## [member bed_offset_y] nudges the bed up/down to sit on the belt surface; [member bed_yaw]
## flips it if the long axis lands the wrong way.

const GLB_PATH: String = "res://assets/3DModels/Chutes/Non_Conveyable_Chute.glb"

## Vertical nudge of the bed relative to the belt surface (m). Default -0.085 seats the grate at the
## right height (tuned in Simulation1.tscn).
@export var bed_offset_y: float = -0.085:
	set(value):
		bed_offset_y = value
		_place_bed()
## Yaw of the bed in degrees; 90 aligns its long axis (local Z) with the conveyor flow (X).
@export_range(-180.0, 180.0, 90.0) var bed_yaw: float = 90.0:
	set(value):
		bed_yaw = value
		_place_bed()
## Roll about the conveyor Z to cancel the bed mesh's built-in ~11.1 deg incline so it sits level
## without rotating the whole part.
@export_range(-45.0, 45.0, 0.1, "suffix:deg") var bed_tilt: float = 11.1:
	set(value):
		bed_tilt = value
		_place_bed()

@export_group("Hinges")
## Lift the LEFT end flap up by [member hinge_open_angle]; off returns it to rest.
@export var hinge_left_open: bool = false
## Lift the RIGHT end flap up by [member hinge_open_angle]; off returns it to rest.
@export var hinge_right_open: bool = false
## Flap open angle in degrees (sign flips the swing direction).
@export_range(-90.0, 90.0, 1.0, "suffix:deg") var hinge_open_angle: float = 45.0
## Flap animation speed, degrees per second.
@export_range(10.0, 360.0, 1.0) var hinge_speed: float = 120.0

@export_group("Guards")
## Side-guard wall along the LEFT long edge of the bed (−Z side; same mesh as a conveyor side guard).
@export var left_side_guard: bool = true:
	set(value):
		left_side_guard = value
		_build_guards()
## Side-guard wall along the RIGHT long edge of the bed (+Z side).
@export var right_side_guard: bool = true:
	set(value):
		right_side_guard = value
		_build_guards()
## A matching side-guard wall across the BACK end (the end without the hinge flaps).
@export var back_guard: bool = true:
	set(value):
		back_guard = value
		_build_guards()

var _bed: Node3D = null
var _hinge_base: Dictionary = {}              # hinge part name -> rest Transform3D (bed-local)
var _pivot_l: Vector3 = Vector3.ZERO
var _pivot_r: Vector3 = Vector3.ZERO
var _hinge_axis: Vector3 = Vector3.RIGHT
var _angle_l: float = 0.0
var _angle_r: float = 0.0
var _hinge_ready: bool = false
var _bed_local_aabb: AABB = AABB()
var _bed_aabb_ready: bool = false


## Let the belt base build path / bodies / frame / guards / legs, then swap in the chute bed.
func _rebuild() -> void:
	super._rebuild()
	if not is_inside_tree():
		return
	if is_instance_valid(_mesh_instance):
		_mesh_instance.visible = false      # hide the flat belt; the chute bed is the surface
	_place_bed()
	_build_guards()


## Snap on the chute's OUTER deck edge (the full bed footprint, which includes the frame/hinge/guard
## overhang), not the path-surface centre. The belt base pushes its ends out by height/2 (pulley
## wrap) and the path centre sits INSIDE the real outer extent — both let the deck/hinge/sideguard
## poke past the seam and leak into the conveyor. Landing the true outer edge on the neighbour's deck
## makes the top surfaces meet with nothing crossing over.
func get_snap_features() -> Array:
	var features: Array = super.get_snap_features()
	if _path == null or _path.runs.is_empty() or not is_instance_valid(_bed):
		return features
	var surf: Transform3D = _deck_surface_frame()
	var inv: Transform3D = surf.affine_inverse()
	var ab: AABB = _bed_aabb()
	var lo: float = 1.0e9
	var hi: float = -1.0e9
	for i: int in 8:
		var corner := ab.position + Vector3(
			ab.size.x if (i & 1) else 0.0,
			ab.size.y if (i & 2) else 0.0,
			ab.size.z if (i & 4) else 0.0)
		var p: Vector3 = inv * (_bed.transform * corner)   # bed corner in deck-surface space
		lo = minf(lo, p.x)
		hi = maxf(hi, p.x)
	# Edges at the deck-surface level, along the (possibly inclined) flow tangent. Per-end Y nudges
	# tuned in Simulation1.tscn so a snapped chute seats at the right height (raising the snap point
	# lowers the landed part): earlier -0.100/+0.050, then a +0.134 seat correction, then +0.030 more.
	var back_o: Vector3 = surf.origin + surf.basis.x * lo + Vector3(0.0, 0.064, 0.0)
	var front_o: Vector3 = surf.origin + surf.basis.x * hi + Vector3(0.0, 0.214, 0.0)
	for f: Dictionary in features:
		var kind: StringName = f.get("kind", &"")
		if kind == &"straight_end_back":
			f["local_pos"] = back_o
		elif kind == &"straight_end_front":
			f["local_pos"] = front_o
	return features


## Drag-from-dock preview: show the CHUTE, not the inherited belt conveyor (the base loads
## BeltConveyor.tscn, so the chute previewed as a plain belt and was hard to pick after dropping).
func _get_custom_preview_node() -> Node3D:
	var preview_scene := load("res://parts/NonConveyableChute.tscn") as PackedScene
	if preview_scene == null:
		return super._get_custom_preview_node()
	var preview_node := preview_scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED) as Node3D
	preview_node.set_meta("is_preview", true)
	_disable_collisions_recursive(preview_node)
	return preview_node


func _place_bed() -> void:
	if not is_inside_tree():
		return
	if not is_instance_valid(_bed):
		_bed = get_node_or_null("_ChuteBed") as Node3D
	if not is_instance_valid(_bed):
		var packed := load(GLB_PATH) as PackedScene
		if packed == null:
			push_warning("NonConveyableChute: could not load %s" % GLB_PATH)
			return
		_bed = packed.instantiate()
		_bed.name = "_ChuteBed"
		add_child(_bed, false, Node.INTERNAL_MODE_FRONT)
		_bed.owner = self
		_reown_recursive(_bed)                  # owner=self so the editor can pick the bed to select the chute
	var ab: AABB = _bed_aabb()
	var c: Vector3 = ab.get_center()
	# Anchor by the actual GRATE ride surface (the `ch_grid_long_*` nodes), NOT the AABB top/bottom.
	# The AABB top is up at the hinge flaps and the bottom is below the grate, so either one puts the
	# surface where cargo does NOT ride. The grate plane is what should sit at the deck.
	var grate_y: float = _grate_surface_local(c.y)
	# The grate node origins are the bar CENTRES; drop by the bar half-thickness so the bar TOPS
	# (the actual ride surface) sit flush with the deck instead of poking above it.
	var grate_t: float = _grate_half_thickness()
	# Sit on the deck's actual (possibly inclined) surface frame: origin = surface centre, basis.x =
	# along-flow tangent, basis.y = surface normal, basis.z = cross-belt. This makes the bed FOLLOW
	# the conveyor `incline` instead of lying flat.
	var surf: Transform3D = _deck_surface_frame()
	# Yaw the long axis into the flow and roll out the GLB's baked ~11.1 deg, layered on the incline.
	var rot: Basis = surf.basis * Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(bed_tilt)) \
			* Basis(Vector3.UP, deg_to_rad(bed_yaw))
	# Grate TOP flush with the deck: sink the bar centres by half a bar-thickness along the normal.
	var origin_pt: Vector3 = surf.origin + surf.basis.y * (bed_offset_y - grate_t)
	# Centre the bed on the surface and land its GRATE plane on the deck, then yaw/roll/incline it.
	_bed.transform = Transform3D(rot, origin_pt) * Transform3D(Basis(), Vector3(-c.x, -grate_y, -c.z))
	_cache_hinges()
	_apply_hinges()


## Bed-local Y of the grated ride surface, from the `ch_grid_long_*` node origins (all coplanar at
## the deck surface). Falls back to [param fallback] (the AABB centre Y) if none are found.
func _grate_surface_local(fallback: float) -> float:
	var ys: Array[float] = []
	_collect_grate_ys(_bed, Transform3D.IDENTITY, ys)
	if ys.is_empty():
		return fallback
	var total: float = 0.0
	for y: float in ys:
		total += y
	return total / float(ys.size())


func _collect_grate_ys(node: Node, accum: Transform3D, out: Array[float]) -> void:
	for child: Node in node.get_children():
		var cx: Transform3D = accum
		if child is Node3D:
			cx = accum * (child as Node3D).transform
			if String(child.name).begins_with("ch_grid_long"):
				out.append(cx.origin.y)
		_collect_grate_ys(child, cx, out)


## Half the grate-bar thickness: the smallest bed-local AABB dimension of a `ch_grid_long` mesh (its
## two large dimensions are the inclined length/spread; the small one is the bar cross-section).
func _grate_half_thickness() -> float:
	var m: float = _min_grate_dim(_bed, Transform3D.IDENTITY, 1.0e9)
	return m * 0.5 if m < 1.0e8 else 0.0


func _min_grate_dim(node: Node, accum: Transform3D, cur: float) -> float:
	var best: float = cur
	for child: Node in node.get_children():
		var cx: Transform3D = accum
		if child is Node3D:
			cx = accum * (child as Node3D).transform
			if child is MeshInstance3D and String(child.name).begins_with("ch_grid_long") \
					and (child as MeshInstance3D).mesh != null:
				var s: Vector3 = (cx * (child as MeshInstance3D).mesh.get_aabb()).size
				best = minf(best, minf(s.x, minf(s.y, s.z)))
		best = _min_grate_dim(child, cx, best)
	return best


## Give every descendant `owner = self` so the editor treats the runtime-built geometry as part of
## this part and a click selects the chute (like VR does with its deck meshes). Also drop the many
## thin grate bars from the shadow pass — individually they're a big shadow-caster cost for no visible
## gain (the frame + legs still cast the chute's silhouette).
func _reown_recursive(node: Node) -> void:
	for child: Node in node.get_children():
		child.owner = self
		if child is GeometryInstance3D and String(child.name).begins_with("ch_grid"):
			(child as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_reown_recursive(child)


## Surface frame at the deck centre. Uses the belt path (which carries the `incline` tilt); falls
## back to a flat frame from the collision extent when the path isn't built yet.
func _deck_surface_frame() -> Transform3D:
	if _path != null and not _path.runs.is_empty():
		return _path.sample(_path.top_surface_length * 0.5)
	var ext: Dictionary = _deck_extent_local()
	var cx: float = (float(ext["min_x"]) + float(ext["max_x"])) * 0.5
	var cz: float = (float(ext["min_z"]) + float(ext["max_z"])) * 0.5
	return Transform3D(Basis(), Vector3(cx, float(ext["top_y"]), cz))


# ---------- end-flap hinges (left / right) ----------
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not _hinge_ready:
		return
	var target_l: float = hinge_open_angle if hinge_left_open else 0.0
	var target_r: float = hinge_open_angle if hinge_right_open else 0.0
	var changed: bool = false
	if not is_equal_approx(_angle_l, target_l):
		_angle_l = move_toward(_angle_l, target_l, hinge_speed * delta)
		changed = true
	if not is_equal_approx(_angle_r, target_r):
		_angle_r = move_toward(_angle_r, target_r, hinge_speed * delta)
		changed = true
	if changed:
		_apply_hinges()


# ---------- guards (real conveyor side-guard mesh, matched to the bed so it doesn't over-extend) ----------
func _build_guards() -> void:
	if not is_inside_tree() or not is_instance_valid(_bed):
		return
	var holder := get_node_or_null("_ChuteGuards") as Node3D
	if holder == null:
		holder = Node3D.new()
		holder.name = "_ChuteGuards"
		add_child(holder, false, Node.INTERNAL_MODE_FRONT)
		holder.owner = self
	for c: Node in holder.get_children():
		c.queue_free()
	# Build everything in the deck's SURFACE frame (carries the `incline` tilt) so the rails and
	# skirts incline together with the bed instead of staying flat. Footprint is measured in that
	# frame from the bed's AABB so the guards match the fixed bed and don't over-extend.
	var surf: Transform3D = _deck_surface_frame()
	var inv: Transform3D = surf.affine_inverse()
	var ab: AABB = _bed_aabb()
	var min_x: float = 1e9
	var max_x: float = -1e9
	var min_z: float = 1e9
	var max_z: float = -1e9
	for i: int in 8:
		var corner := ab.position + Vector3(
			ab.size.x if (i & 1) else 0.0,
			ab.size.y if (i & 2) else 0.0,
			ab.size.z if (i & 4) else 0.0)
		var p: Vector3 = inv * (_bed.transform * corner)   # bed corner in deck-surface space
		min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z); max_z = maxf(max_z, p.z)
	var cx: float = (min_x + max_x) * 0.5
	var cz: float = (min_z + max_z) * 0.5
	var deck_l: float = max_x - min_x
	var deck_w: float = max_z - min_z
	var ft: float = ConveyorFrameMesh.WALL_THICKNESS * 2.0   # frame skirt thickness
	# Full deck length so the rails/skirts cover the whole bed INCLUDING the hinge flaps at the end
	# (the bed AABB, hence deck_l, already spans them). Each side is toggled independently.
	if left_side_guard:
		_add_guard_wall(holder, deck_l, surf * Transform3D(Basis(Vector3.UP, 0.0), Vector3(cx, 0.0, min_z)))
		_add_frame_panel(holder, surf * Transform3D(Basis(), Vector3(cx, -height * 0.5, min_z)), Vector3(deck_l, height, ft))
	if right_side_guard:
		_add_guard_wall(holder, deck_l, surf * Transform3D(Basis(Vector3.UP, deg_to_rad(180.0)), Vector3(cx, 0.0, max_z)))
		_add_frame_panel(holder, surf * Transform3D(Basis(), Vector3(cx, -height * 0.5, max_z)), Vector3(deck_l, height, ft))
	if back_guard:
		# Back wall closes the end WITHOUT the hinge flaps (the original, correct side).
		var hinge_x: float = (inv * (_bed.transform * _pivot_l)).x if _hinge_ready else min_x
		var back_x: float = min_x if hinge_x > cx else max_x
		var yaw: float = -90.0 if back_x > cx else 90.0
		_add_guard_wall(holder, deck_w, surf * Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), Vector3(back_x, 0.0, cz)))
		_add_frame_panel(holder, surf * Transform3D(Basis(), Vector3(back_x, -height * 0.5, cz)), Vector3(ft, height, deck_w))


## One side-guard wall: the same procedural mesh + material the conveyor uses. The wall runs along
## its local X by `wall_len`; `base_xf` places + orients it (already carries any deck incline). Gets
## a StaticBody + BoxShape (same as `SideGuard`) so cargo is CONTAINED instead of clipping through.
func _add_guard_wall(holder: Node3D, wall_len: float, base_xf: Transform3D) -> void:
	var len_c: float = maxf(0.05, wall_len)
	var mi := MeshInstance3D.new()
	mi.mesh = SideGuardMesh.create(len_c)
	mi.material_override = SideGuardMesh.create_material()
	mi.transform = base_xf
	holder.add_child(mi)
	mi.owner = self
	# Collision wall (mask 8 = cargo). Unlike a running-belt SideGuard (friction 0 so cargo slides
	# along it), a CHUTE is an accumulation surface — give the wall real friction so boxes leaning on
	# it come to rest and can SLEEP instead of micro-sliding forever.
	var body := StaticBody3D.new()
	body.collision_mask = 8
	var phys := PhysicsMaterial.new()
	phys.friction = 0.5
	body.physics_material_override = phys
	mi.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	var wh: float = SideGuardMesh.WALL_HEIGHT
	var wt: float = SideGuardMesh.WALL_THICKNESS
	shape.size = Vector3(len_c, wh, SideGuardMesh.COLLISION_THICKNESS)
	cs.shape = shape
	cs.position = Vector3(0.0, wh * 0.5, wt * 0.5)
	body.add_child(cs)


## A blue frame skirt (box) below a guard rail, in the conveyor frame material. `base_xf` carries
## the deck incline; the box's local axes (size.x along flow, size.y vertical, size.z across) tilt
## with it. Carries a matching StaticBody so cargo sitting low in the trough is contained, not clipped.
func _add_frame_panel(holder: Node3D, base_xf: Transform3D, panel_size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = panel_size
	mi.mesh = bm
	mi.material_override = ConveyorFrameMesh.create_material()
	mi.transform = base_xf
	holder.add_child(mi)
	mi.owner = self
	# Collision matching the panel (BoxMesh is centred on its origin, so the shape sits at origin too).
	# Friction 0.5 (accumulation surface) so boxes low in the trough rest and sleep.
	var body := StaticBody3D.new()
	body.collision_mask = 8
	var phys := PhysicsMaterial.new()
	phys.friction = 0.5
	body.physics_material_override = phys
	mi.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = panel_size
	cs.shape = shape
	body.add_child(cs)


## Cache each hinge part's rest transform + the two pin pivots/axis, once.
func _cache_hinges() -> void:
	if _hinge_ready or not is_instance_valid(_bed):
		return
	var pin_l := _bed.get_node_or_null("ch_hinge_L_pin") as Node3D
	var pin_r := _bed.get_node_or_null("ch_hinge_R_pin") as Node3D
	if pin_l == null or pin_r == null:
		return
	_pivot_l = pin_l.transform.origin
	_pivot_r = pin_r.transform.origin
	_hinge_axis = pin_l.transform.basis.y.normalized()   # the pin's long axis
	_hinge_base.clear()
	for c: Node in _bed.get_children():
		var nm: String = String(c.name)
		if (nm.begins_with("ch_hinge_L") or nm.begins_with("ch_hinge_R")) and c is Node3D:
			_hinge_base[nm] = (c as Node3D).transform
	_hinge_ready = true


## Rotate each flap's parts about its pin by the current animated angle.
func _apply_hinges() -> void:
	if not _hinge_ready:
		return
	for nm: String in _hinge_base:
		var part := _bed.get_node_or_null(nm) as Node3D
		if part == null:
			continue
		var is_left: bool = nm.begins_with("ch_hinge_L")
		var pivot: Vector3 = _pivot_l if is_left else _pivot_r
		var ang: float = _angle_l if is_left else _angle_r
		var hinge: Transform3D = Transform3D(Basis(), pivot) \
				* Transform3D(Basis(_hinge_axis, deg_to_rad(ang)), Vector3.ZERO) \
				* Transform3D(Basis(), -pivot)
		part.transform = hinge * (_hinge_base[nm] as Transform3D)


## Combined local-space AABB of the bed mesh (cached after the first instantiate).
func _bed_aabb() -> AABB:
	if _bed_aabb_ready:
		return _bed_local_aabb
	if not is_instance_valid(_bed):
		return AABB()
	var boxes: Array[AABB] = []
	_collect_bed_aabbs(_bed, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return AABB()
	var a: AABB = boxes[0]
	for i: int in range(1, boxes.size()):
		a = a.merge(boxes[i])
	_bed_local_aabb = a
	_bed_aabb_ready = true
	return a


func _collect_bed_aabbs(node: Node, accum: Transform3D, out: Array[AABB]) -> void:
	for c: Node in node.get_children():
		var cx: Transform3D = accum
		if c is Node3D:
			cx = accum * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			out.append(cx * (c as MeshInstance3D).mesh.get_aabb())
		_collect_bed_aabbs(c, cx, out)


## Local-space deck extent + top Y from the belt collision bodies (the VR / Intralox pattern),
## so the bed lands where parcels ride regardless of how the path is centred.
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
@export_category("Chute Hinge Comms")
## Drive the two end flaps from a PLC / OPC UA server. Needs the inherited Enable Comms on; while the
## tag group is live these BOOLs OVERRIDE the manual Hinge Left/Right Open toggles each poll.
@export var hinge_tag_group_name: String
## Tag group for the two hinge command bits.
@export_custom(0, "tag_group_enum") var hinge_tag_groups: String:
	set(value):
		hinge_tag_group_name = value
		hinge_tag_groups = value
## Command tag (READ): true lifts the LEFT end flap to the open angle.[br]Datatype: [code]BOOL[/code]
@export var hinge_left_tag_name: String = ""
## Command tag (READ): true lifts the RIGHT end flap to the open angle.[br]Datatype: [code]BOOL[/code]
@export var hinge_right_tag_name: String = ""

var _hinge_l_tag := OIPCommsTag.new()
var _hinge_r_tag := OIPCommsTag.new()


func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	# The chute builds its OWN guards/skirts (left_side_guard/right_side_guard/back_guard), so hide the
	# belt's inherited guard + frame-rail toggles — they're disabled here and only cause confusion.
	if property.name == "left_side_guards_enabled" or property.name == "right_side_guards_enabled" \
			or property.name == "frame_rails_enabled":
		property.usage = PROPERTY_USAGE_STORAGE
	OIPCommsSetup.validate_tag_property(property, "hinge_tag_group_name", "hinge_tag_groups", "hinge_left_tag_name")
	OIPCommsSetup.validate_tag_property(property, "hinge_tag_group_name", "hinge_tag_groups", "hinge_right_tag_name")


func _enter_tree() -> void:
	super._enter_tree()
	# The base already connects tag_group_initialized/polled -> our overrides; just default the group.
	hinge_tag_group_name = OIPCommsSetup.default_tag_group(hinge_tag_group_name)


func _on_simulation_started() -> void:
	super._on_simulation_started()
	if enable_comms:
		_hinge_l_tag.register(hinge_tag_group_name, hinge_left_tag_name, OIPCommsTag.TYPE_BOOL)
		_hinge_r_tag.register(hinge_tag_group_name, hinge_right_tag_name, OIPCommsTag.TYPE_BOOL)


func _tag_group_initialized(group: String) -> void:
	super._tag_group_initialized(group)
	_hinge_l_tag.on_group_initialized(group)
	_hinge_r_tag.on_group_initialized(group)


## Each poll, mirror the two PLC bits onto the flap-open flags; `_physics_process` then animates.
func _tag_group_polled(group: String) -> void:
	super._tag_group_polled(group)
	if not enable_comms:
		return
	if _hinge_l_tag.matches_group(group) and _hinge_l_tag.is_ready():
		hinge_left_open = _hinge_l_tag.read_bit()
	if _hinge_r_tag.matches_group(group) and _hinge_r_tag.is_ready():
		hinge_right_open = _hinge_r_tag.read_bit()
#endregion
