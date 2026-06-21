@tool
class_name CameraTunnelUnit
extends Node3D

## SICK ICR690 NON-CON camera tunnel. As a parcel passes the read gate the illuminators
## FLASH (the capture), the unit reads the parcel's barcode and reports it to the PLC, and
## the illumination turns GREEN (good read) / RED (no read). Placed purely by hand.
##
## Built only from the APIs the conveyors/spawner use (Area3D, MeshInstance3D emission,
## OIPComms tags, Simulation signals) so it compiles on the custom build.
##  PLC: trigger/good_read/no_read (BOOL out), barcode (INT32 out), lights (BOOL in).
## Nodes: Tunnel_Body (collision) / Cameras / Lights (the flash + status illumination).

const _ILLUM_PATH: String = "camera_tunnel/Lights"
const LIGHT_ENERGY: float = 1.5
const FLASH_ENERGY: float = 14.0
const FLASH_COUNT: int = 3
const FLASH_INTERVAL: float = 0.05
## Real illuminator-light energies (the ICI890-style strobe): a bright burst during a capture,
## a dim work light when steady-on. These light the parcel for real — visible in a dark building.
const FLASH_LIGHT_ENERGY: float = 12.0
const STEADY_LIGHT_ENERGY: float = 2.5
const READ_GATE_THICKNESS: float = 0.30
const COL_READY: Color = Color(0.9, 0.9, 0.85)
const COL_GOOD: Color = Color(0.1, 1.0, 0.2)
const COL_NOREAD: Color = Color(1.0, 0.1, 0.1)

## Steady scan illumination on/off (overridden by the lights PLC tag when comms enabled).
@export var lights_on: bool = false:
	set(value):
		lights_on = value
		_apply_lights()
## Enable the read gate / flash / reporting during simulation.
@export var scan_enabled: bool = true
## Belt width the read gate spans.
@export_range(0.4, 2.0, 0.01, "suffix:m") var gate_width: float = 1.219
## Height of the read aperture above belt top.
@export_range(0.2, 2.0, 0.01, "suffix:m") var gate_height: float = 1.1
## Show the running read-statistics HMI text on the tunnel.
@export var show_hmi: bool = true
## Height (m) of the HMI text above the unit origin — raise it to float above the tunnel.
@export_range(0.5, 8.0, 0.1, "suffix:m") var hmi_height: float = 3.6:
	set(value):
		hmi_height = value
		if _hmi != null and is_instance_valid(_hmi):
			_hmi.position = Vector3(0.0, hmi_height, 0.0)

## Read the barcode OPTICALLY (render the box's code through a camera and decode the
## pixels). Off = read the box's stored barcode metadata directly (no genuine no-reads).
@export var optical_read: bool = true
## Orthographic span (m) of the optical camera around the gate (vertical world extent).
## SMALLER = the code fills more pixels = more reliable reads. ~1.0 m gives a crisp code.
@export_range(0.4, 3.0, 0.01, "suffix:m") var optical_view_size: float = 1.0
## Height (m) the optical camera sits above the box top while it captures.
@export_range(0.3, 4.0, 0.05, "suffix:m") var optical_cam_height: float = 1.4
## DEBUG: save each optical capture to user://optical_capture.png + print the framing metrics
## to the Output, so the capture can be inspected when tuning. Leave OFF in normal use.
@export var optical_debug: bool = false
## Fraction of parcels that NO-READ even with a good label (models damaged/unreadable codes).
## Default 0 = the tunnel reads every labelled parcel — a real 6-camera ICR690 reads ~100%.
@export_range(0.0, 1.0, 0.001) var no_read_rate: float = 0.0
## Code-field string transmitted on a no-read (real SICK systems send a configurable NoRead
## sentinel, not nothing), so a downstream host / sorter can branch on it.
@export var no_read_string: String = "NoRead"

const OPTICAL_VP_WIDTH: int = 1024
const OPTICAL_VP_HEIGHT: int = 512
const MODULES_OPT: int = 18   # mirrors BarcodeLabel.MODULES
# BarcodeLabel.make_texture layout (must match barcode_label.gd / box_spawner.gd):
const TEX_MARGIN: float = 6.0
const TEX_BLOCK: float = 72.0      # MODULES(18) * scale(4)
const TEX_W: float = 318.0         # margin*2 + 4*block + 3*gap
const TEX_H: float = 84.0          # margin*2 + block

var _illum: MeshInstance3D = null
var _illum_mats: Array[StandardMaterial3D] = []
var _area: Area3D = null
var _flash_timer: float = 0.0
var _flashes_left: int = 0
var _in_zone: int = 0
var _scanned: Dictionary = {}
var _good_read_hold: float = 0.0
var _status: Color = COL_READY
var _hmi: Label3D = null

var _stat_total: int = 0
var _stat_good: int = 0
var _stat_noread: int = 0
var _stat_last: String = ""
var _run_time: float = 0.0

var _sv: SubViewport = null
var _opt_cam: Camera3D = null
var _optical_busy: bool = false
var _flash_lights: Array[SpotLight3D] = []

## Emitted on every read: full string, numeric value, optical (TRUE when decoded from the
## camera image, FALSE when read from the box's stored metadata).
signal barcode_read(code: String, value: int, optical: bool)


func _ready() -> void:
	_cache_illum()
	_apply_lights()
	if Simulation.is_running():
		_build_runtime()


# ---------- illumination (flash + status colour on the Lights node) ----------
func _cache_illum() -> void:
	_illum = get_node_or_null(NodePath(_ILLUM_PATH)) as MeshInstance3D
	_illum_mats.clear()
	if _illum == null or _illum.mesh == null:
		return
	for i: int in _illum.mesh.get_surface_count():
		var base: Material = _illum.mesh.surface_get_material(i)
		if base is StandardMaterial3D:
			var m: StandardMaterial3D = (base as StandardMaterial3D).duplicate()
			_illum.set_surface_override_material(i, m)
			_illum_mats.append(m)


func _apply_lights() -> void:
	if _illum == null or not is_instance_valid(_illum):
		_cache_illum()
	var e: float = LIGHT_ENERGY if lights_on else 0.0
	for m: StandardMaterial3D in _illum_mats:
		m.emission_enabled = true
		m.emission = _status
		m.emission_energy_multiplier = e
	_set_illum_light_energy(false)


func _set_flash(energy: float) -> void:
	for m: StandardMaterial3D in _illum_mats:
		m.emission_enabled = true
		m.emission = _status
		m.emission_energy_multiplier = energy if energy > 0.0 else (LIGHT_ENERGY if lights_on else 0.0)
	_set_illum_light_energy(energy > 0.0)


# Drive the REAL illuminator SpotLights: bright burst during a capture flash, a dim level when
# steady-on, else off. (The status colour stays on the Lights mesh; the SpotLights are white.)
func _set_illum_light_energy(flashing: bool) -> void:
	var lit: float = FLASH_LIGHT_ENERGY if flashing else (STEADY_LIGHT_ENERGY if lights_on else 0.0)
	for sl: SpotLight3D in _flash_lights:
		if is_instance_valid(sl):
			sl.light_energy = lit


func _set_status(col: Color) -> void:
	_status = col
	for m: StandardMaterial3D in _illum_mats:
		m.emission = col


# ---------- runtime (sim only) ----------
func _build_runtime() -> void:
	if _area != null and is_instance_valid(_area):
		return
	_area = Area3D.new()
	_area.name = "ReadGate"
	_area.collision_mask = 0xFFFFFFFF
	_area.monitoring = true
	var cs: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(READ_GATE_THICKNESS, gate_height, gate_width)
	cs.shape = box
	cs.position = Vector3(0.0, gate_height * 0.5, 0.0)
	_area.add_child(cs)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)
	if show_hmi:
		_hmi = Label3D.new()
		_hmi.name = "HMI"
		_hmi.pixel_size = 0.0024          # bigger in world space
		_hmi.font_size = 120              # higher resolution so it stays crisp when enlarged
		_hmi.modulate = COL_GOOD
		_hmi.outline_size = 40            # heavy outline = reads as BOLD, high contrast
		_hmi.outline_modulate = Color.BLACK
		_hmi.billboard = BaseMaterial3D.BILLBOARD_ENABLED   # faces the camera from any side
		_hmi.no_depth_test = true                           # draws on top / through geometry
		_hmi.fixed_size = false
		_hmi.position = Vector3(0.0, hmi_height, 0.0)        # floats above the tunnel
		add_child(_hmi)
	_build_illum_lights()
	if optical_read:
		_build_optical_rig()
	_reset_stats()


func _build_optical_rig() -> void:
	if _sv != null and is_instance_valid(_sv):
		return
	_sv = SubViewport.new()
	_sv.name = "OpticalRead"
	_sv.size = Vector2i(OPTICAL_VP_WIDTH, OPTICAL_VP_HEIGHT)
	_sv.transparent_bg = false
	_sv.own_world_3d = false
	_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sv.msaa_3d = Viewport.MSAA_DISABLED
	_sv.use_debanding = false
	_sv.physics_object_picking = false
	# Share the MAIN world so the SubViewport renders the real moving boxes, not an empty scene.
	var shared_world: World3D = get_world_3d()
	if shared_world != null:
		_sv.world_3d = shared_world
	add_child(_sv)
	_opt_cam = Camera3D.new()
	_opt_cam.name = "OpticalCam"
	_opt_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_opt_cam.size = optical_view_size
	_opt_cam.near = 0.05
	_opt_cam.far = optical_cam_height + 4.0
	# Look straight DOWN (-Y). Default Camera3D looks down its local -Z; rotate -90deg about X.
	_opt_cam.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	_sv.add_child(_opt_cam)
	_opt_cam.current = true


# Real illuminator lights aimed DOWN at the read gate — two SpotLights (entry + exit side) the
# tunnel flashes ON during each capture (dim steady level when lights_on), so the parcel is
# actually lit and visible even when the building is dark, like the real ICI890 strobes.
func _build_illum_lights() -> void:
	_flash_lights.clear()
	for i: int in 2:
		var sl: SpotLight3D = SpotLight3D.new()
		sl.name = "Illuminator%d" % i
		sl.spot_range = gate_height + 3.0
		sl.spot_angle = 60.0
		sl.spot_attenuation = 1.0
		sl.light_color = Color(1.0, 0.98, 0.92)
		sl.light_energy = 0.0
		sl.shadow_enabled = false
		var sx: float = 0.9 if i == 0 else -0.9   # entry / exit side of the gate
		sl.position = Vector3(sx, gate_height + 1.4, 0.0)
		sl.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # point straight DOWN at the gate
		add_child(sl)
		_flash_lights.append(sl)
	_set_illum_light_energy(false)


func _teardown_runtime() -> void:
	_optical_busy = false
	for sl: SpotLight3D in _flash_lights:
		if is_instance_valid(sl):
			sl.queue_free()
	_flash_lights.clear()
	if _opt_cam != null and is_instance_valid(_opt_cam):
		_opt_cam.queue_free()
	if _sv != null and is_instance_valid(_sv):
		_sv.queue_free()
	_opt_cam = null
	_sv = null
	if _area != null and is_instance_valid(_area):
		_area.queue_free()
	if _hmi != null and is_instance_valid(_hmi):
		_hmi.queue_free()
	_area = null
	_hmi = null
	_in_zone = 0
	_scanned.clear()
	_set_status(COL_READY)
	_set_flash(0.0)


func _reset_stats() -> void:
	_stat_total = 0
	_stat_good = 0
	_stat_noread = 0
	_stat_last = ""
	_run_time = 0.0
	_update_hmi()


func _update_hmi() -> void:
	if _hmi == null or not is_instance_valid(_hmi):
		return
	var rate: float = (100.0 * float(_stat_good) / float(_stat_total)) if _stat_total > 0 else 0.0
	var tph: float = (60.0 * float(_stat_total) / _run_time) if _run_time > 0.5 else 0.0
	_hmi.text = "ICR690 READ\nSCANNED %d\nGOOD %d (%.0f%%)\nNO-READ %d\n%.0f/min\n%s" % [
		_stat_total, _stat_good, rate, _stat_noread, tph,
		(_stat_last if _stat_last != "" else "-")]


func _on_body_entered(body: Node3D) -> void:
	if not scan_enabled:
		return
	# Only parcels (RigidBody3D) — the read-gate Area3D overlaps the belt/structure StaticBodies
	# it sits on, which otherwise fire as phantom "no-reads" the instant the sim starts.
	if not (body is RigidBody3D):
		return
	_in_zone += 1
	_write_bit(_trigger_tag, true)
	var id: int = body.get_instance_id()
	if _scanned.has(id):
		return
	_scanned[id] = true
	if optical_read and not _optical_busy and _sv != null and is_instance_valid(_sv) and _opt_cam != null and is_instance_valid(_opt_cam):
		_run_optical_capture(body)
	else:
		_capture_metadata(body)


func _on_body_exited(body: Node3D) -> void:
	if not (body is RigidBody3D):
		return
	_in_zone = max(0, _in_zone - 1)
	if _in_zone == 0:
		_write_bit(_trigger_tag, false)
	_scanned.erase(body.get_instance_id())


func _run_optical_capture(body: Node3D) -> void:
	_optical_busy = true
	# Flash now (visual); the decode follows the real render below.
	_flashes_left = FLASH_COUNT
	_flash_timer = 0.0
	_set_flash(FLASH_ENERGY)
	var codes: MeshInstance3D = _find_barcode_codes(body)
	if codes == null:
		_optical_busy = false
		_capture_metadata(body)   # no code node to image -> not a no-read; fall back.
		return
	if _sv == null or not is_instance_valid(_sv) or _opt_cam == null or not is_instance_valid(_opt_cam):
		_optical_busy = false
		_capture_metadata(body)
		return
	# Aim the orthographic camera straight down over the code at a fixed height above it.
	var code_origin: Vector3 = codes.global_transform.origin
	_opt_cam.global_position = Vector3(code_origin.x, code_origin.y + optical_cam_height, code_origin.z)
	_opt_cam.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	# Render EXACTLY one frame, synced to the renderer (UPDATE_ONCE renders on the next DRAW
	# frame, which is decoupled from physics ticks — this is the project's proven readback).
	await RenderingServer.frame_pre_draw
	_sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	# After the awaits the body / rig may be gone (sim stopped, parcel freed).
	if _sv != null and is_instance_valid(_sv):
		_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if body == null or not is_instance_valid(body):
		_optical_busy = false
		return
	var decoded: int = _decode_optical(codes)
	_optical_busy = false
	# A real ICR690 is a 6-camera + bottom-mirror tunnel that reads ANY face ~100%. This single
	# top-down decode only sees the TOP; when it can't decode, the OTHER cameras (modelled by the
	# orientation-independent stored value) still read the parcel — so a failed pixel decode is
	# NOT a no-read. Genuine no-reads come only from no_read_rate (damaged/unreadable labels).
	var value: int = decoded
	if value < 0:
		value = int(body.get_meta("barcode_value", -1))
	value = _apply_no_read_rate(value)
	_resolve_read(value, _label_for(body, value), true)


func _find_barcode_codes(body: Node3D) -> MeshInstance3D:
	if body == null or not is_instance_valid(body):
		return null
	var direct: Node = body.get_node_or_null(NodePath("BarcodeCodes"))
	if direct is MeshInstance3D:
		return direct as MeshInstance3D
	var found: Node = body.find_child("BarcodeCodes", true, false)
	if found is MeshInstance3D:
		return found as MeshInstance3D
	return null


# Returns >=0 decoded value, -1 genuine no-read (captured but unreadable/skewed),
# -2 unusable capture (off-screen / degenerate / no image -> caller falls back to metadata).
func _decode_optical(codes: MeshInstance3D) -> int:
	if codes == null or not is_instance_valid(codes):
		return -2
	if _sv == null or not is_instance_valid(_sv):
		return -2
	if _opt_cam == null or not is_instance_valid(_opt_cam):
		return -2
	var plane: PlaneMesh = codes.mesh as PlaneMesh
	if plane == null:
		return -2
	var half_x: float = plane.size.x * 0.5
	var half_z: float = plane.size.y * 0.5   # PlaneMesh.size.y is its local-Z extent
	var xform: Transform3D = codes.global_transform
	# Code 0 occupies texture-U [margin..margin+block]/TEX_W, V [margin..margin+block]/TEX_H.
	# PlaneMesh UV: U along local +X, V along local +Z; UV origin at the (-x/2,-z/2) corner.
	var u0: float = TEX_MARGIN / TEX_W
	var u1: float = (TEX_MARGIN + TEX_BLOCK) / TEX_W
	var v0: float = TEX_MARGIN / TEX_H
	var v1: float = (TEX_MARGIN + TEX_BLOCK) / TEX_H
	var x0: float = -half_x + u0 * (2.0 * half_x)
	var x1: float = -half_x + u1 * (2.0 * half_x)
	var z0: float = -half_z + v0 * (2.0 * half_z)
	var z1: float = -half_z + v1 * (2.0 * half_z)
	# Code-0 quad corners in world space (PlaneMesh lies in local XZ, y = 0).
	var w_tl: Vector3 = xform * Vector3(x0, 0.0, z0)
	var w_tr: Vector3 = xform * Vector3(x1, 0.0, z0)
	var w_bl: Vector3 = xform * Vector3(x0, 0.0, z1)
	var w_br: Vector3 = xform * Vector3(x1, 0.0, z1)
	var p_tl: Vector2 = _opt_cam.unproject_position(w_tl)
	var p_tr: Vector2 = _opt_cam.unproject_position(w_tr)
	var p_bl: Vector2 = _opt_cam.unproject_position(w_bl)
	var p_br: Vector2 = _opt_cam.unproject_position(w_br)
	if not _finite_pt(p_tl) or not _finite_pt(p_tr) or not _finite_pt(p_bl) or not _finite_pt(p_br):
		return -2
	var min_x: float = minf(minf(p_tl.x, p_tr.x), minf(p_bl.x, p_br.x))
	var max_x: float = maxf(maxf(p_tl.x, p_tr.x), maxf(p_bl.x, p_br.x))
	var min_y: float = minf(minf(p_tl.y, p_tr.y), minf(p_bl.y, p_br.y))
	var max_y: float = maxf(maxf(p_tl.y, p_tr.y), maxf(p_bl.y, p_br.y))
	var vp_w: float = float(OPTICAL_VP_WIDTH)
	var vp_h: float = float(OPTICAL_VP_HEIGHT)
	if min_x < 1.0 or min_y < 1.0 or max_x > vp_w - 1.0 or max_y > vp_h - 1.0:
		return -2
	var span_x: float = max_x - min_x
	var span_y: float = max_y - min_y
	if span_x < float(MODULES_OPT) or span_y < float(MODULES_OPT):
		return -2
	var cell: float = ((span_x + span_y) * 0.5) / float(MODULES_OPT)
	if cell < 1.0:
		return -2
	var tex: ViewportTexture = _sv.get_texture()
	if tex == null:
		return -2
	var img: Image = tex.get_image()
	if img == null:
		return -2
	var ox: int = roundi(min_x)
	var oy: int = roundi(min_y)
	if optical_debug:
		img.save_png("user://optical_capture.png")
		print("[CameraTunnel] capture ox=%d oy=%d cell=%.2f span=%.1fx%.1f vp=%dx%d" % [ox, oy, cell, span_x, span_y, OPTICAL_VP_WIDTH, OPTICAL_VP_HEIGHT])
	return _decode_grid_at(img, ox, oy, cell)


func _finite_pt(p: Vector2) -> bool:
	return is_finite(p.x) and is_finite(p.y)


# Robust decode: ADAPTIVE luminance threshold (computed from the code region itself, so the
# scene's lighting/exposure can't push white modules under a fixed 0.5 and turn a good code into
# a no-read) + a 3x3 oversample per module (tolerates sub-pixel framing drift and anti-aliasing).
# Returns the decoded value, or -1 if the finder/checksum still fails (a genuine no-read).
func _decode_grid_at(img: Image, ox: int, oy: int, cell: float) -> int:
	var lum: Array = []
	var lo: float = 1.0
	var hi: float = 0.0
	var off: int = maxi(1, int(cell * 0.22))
	for r: int in MODULES_OPT:
		var row: Array = []
		for c: int in MODULES_OPT:
			var cx: int = ox + int((float(c) + 0.5) * cell)
			var cy: int = oy + int((float(r) + 0.5) * cell)
			var s: float = 0.0
			for ky: int in 3:
				for kx: int in 3:
					s += _sample_lum(img, cx + (kx - 1) * off, cy + (ky - 1) * off)
			var v: float = s / 9.0
			row.append(v)
			lo = minf(lo, v)
			hi = maxf(hi, v)
		lum.append(row)
	if hi - lo < 0.12:
		return -1                          # no contrast in the framed region -> unreadable
	var thresh: float = (lo + hi) * 0.5
	var g: Array = []
	for r: int in MODULES_OPT:
		var grow: Array = []
		for c: int in MODULES_OPT:
			grow.append(float(lum[r][c]) < thresh)   # darker than midpoint = a set (black) module
		g.append(grow)
	return BarcodeLabel.decode_grid(g)


func _sample_lum(img: Image, px: int, py: int) -> float:
	if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
		return 1.0                          # off-image -> treat as white (won't be counted as set)
	return img.get_pixel(px, py).get_luminance()


# Rare, configurable GENUINE no-read (a damaged / unreadable label). Default rate 0 = never,
# so the tunnel reads every labelled parcel like a real 6-camera ICR690.
func _apply_no_read_rate(value: int) -> int:
	if value >= 0 and no_read_rate > 0.0 and randf() < no_read_rate:
		return -1
	return value


# The code string for a result: the parcel's real label when read, else the NoRead sentinel.
func _label_for(body: Node3D, value: int) -> String:
	if value < 0:
		return no_read_string
	if body != null and is_instance_valid(body) and body.has_meta("barcode_string"):
		return String(body.get_meta("barcode_string"))
	return BarcodeLabel.value_to_string(value)


func _capture_metadata(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	# Flash for the metadata path too (the optical path already flashed before its awaits).
	if _flashes_left <= 0 and _flash_timer <= 0.0:
		_flashes_left = FLASH_COUNT
		_flash_timer = 0.0
		_set_flash(FLASH_ENERGY)
	var value: int = _apply_no_read_rate(int(body.get_meta("barcode_value", -1)))
	_resolve_read(value, _label_for(body, value), false)


func _resolve_read(value: int, label_string: String, optical: bool) -> void:
	_stat_total += 1
	if value >= 0:
		if _barcode_tag.is_ready():
			_barcode_tag.write_int32(value)
		_write_bit(_good_read_tag, true)
		_good_read_hold = 0.4
		_stat_good += 1
		_stat_last = label_string if label_string != "" else str(value)
		_set_status(COL_GOOD)
		barcode_read.emit(_stat_last, value, optical)
	else:
		if _barcode_tag.is_ready():
			_barcode_tag.write_int32(-1)          # explicit host-visible no-read marker
		_write_bit(_no_read_tag, true)
		_good_read_hold = 0.4
		_stat_noread += 1
		_stat_last = label_string if label_string != "" else no_read_string
		_set_status(COL_NOREAD)
		barcode_read.emit(_stat_last, -1, optical)
	_update_hmi()


func _physics_process(delta: float) -> void:
	if not Simulation.is_running():
		return
	_run_time += delta
	if _flashes_left > 0 or _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			if _flashes_left > 0:
				_flashes_left -= 1
				_set_flash(FLASH_ENERGY)
				_flash_timer = FLASH_INTERVAL
			else:
				_set_flash(0.0)
		elif _flash_timer < FLASH_INTERVAL * 0.5:
			_set_flash(0.0)
	if _good_read_hold > 0.0:
		_good_read_hold -= delta
		if _good_read_hold <= 0.0:
			_write_bit(_good_read_tag, false)
			_write_bit(_no_read_tag, false)
			if _in_zone == 0:
				_set_status(COL_READY)
				_set_flash(0.0)


#region PLC
@export_category("Communications")
## Enable communication with external PLC/control systems.
@export var enable_comms: bool = false
@export var lights_tag_group_name: String
## Tag group for the lights command.
@export_custom(0, "tag_group_enum") var lights_tag_groups: String:
	set(value):
		lights_tag_group_name = value
		lights_tag_groups = value
## Command tag (READ): TRUE forces scan illumination on.[br]Datatype: [code]BOOL[/code]
@export var lights_tag_name: String = ""
@export var trigger_tag_group_name: String
## Tag group for the trigger/photoeye status.
@export_custom(0, "tag_group_enum") var trigger_tag_groups: String:
	set(value):
		trigger_tag_group_name = value
		trigger_tag_groups = value
## Status tag (WRITE): TRUE while a parcel is in the read gate.[br]Datatype: [code]BOOL[/code]
@export var trigger_tag_name: String = ""
@export var good_read_tag_group_name: String
## Tag group for the good-read pulse.
@export_custom(0, "tag_group_enum") var good_read_tag_groups: String:
	set(value):
		good_read_tag_group_name = value
		good_read_tag_groups = value
## Status tag (WRITE): pulses TRUE on a successful read.[br]Datatype: [code]BOOL[/code]
@export var good_read_tag_name: String = ""
@export var no_read_tag_group_name: String
## Tag group for the no-read pulse.
@export_custom(0, "tag_group_enum") var no_read_tag_groups: String:
	set(value):
		no_read_tag_group_name = value
		no_read_tag_groups = value
## Status tag (WRITE): pulses TRUE when a parcel passes with no code.[br]Datatype: [code]BOOL[/code]
@export var no_read_tag_name: String = ""
@export var barcode_tag_group_name: String
## Tag group for the decoded barcode value.
@export_custom(0, "tag_group_enum") var barcode_tag_groups: String:
	set(value):
		barcode_tag_group_name = value
		barcode_tag_groups = value
## Data tag (WRITE): numeric value of the last good read.[br]Datatype: [code]INT32[/code]
@export var barcode_tag_name: String = ""

var _lights_tag: OIPCommsTag = OIPCommsTag.new()
var _trigger_tag: OIPCommsTag = OIPCommsTag.new()
var _good_read_tag: OIPCommsTag = OIPCommsTag.new()
var _no_read_tag: OIPCommsTag = OIPCommsTag.new()
var _barcode_tag: OIPCommsTag = OIPCommsTag.new()


func _validate_property(property: Dictionary) -> void:
	if OIPCommsSetup.validate_tag_property(property, "lights_tag_group_name", "lights_tag_groups", "lights_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "trigger_tag_group_name", "trigger_tag_groups", "trigger_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "good_read_tag_group_name", "good_read_tag_groups", "good_read_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "no_read_tag_group_name", "no_read_tag_groups", "no_read_tag_name"):
		return
	if OIPCommsSetup.validate_tag_property(property, "barcode_tag_group_name", "barcode_tag_groups", "barcode_tag_name"):
		return


func _enter_tree() -> void:
	lights_tag_group_name = OIPCommsSetup.default_tag_group(lights_tag_group_name)
	trigger_tag_group_name = OIPCommsSetup.default_tag_group(trigger_tag_group_name)
	good_read_tag_group_name = OIPCommsSetup.default_tag_group(good_read_tag_group_name)
	no_read_tag_group_name = OIPCommsSetup.default_tag_group(no_read_tag_group_name)
	barcode_tag_group_name = OIPCommsSetup.default_tag_group(barcode_tag_group_name)
	if not Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.connect(_on_simulation_started)
	if not Simulation.stopped.is_connected(_on_simulation_stopped):
		Simulation.stopped.connect(_on_simulation_stopped)
	OIPCommsSetup.connect_comms(self, _tag_group_initialized, _tag_group_polled)


func _exit_tree() -> void:
	if Simulation.started.is_connected(_on_simulation_started):
		Simulation.started.disconnect(_on_simulation_started)
	if Simulation.stopped.is_connected(_on_simulation_stopped):
		Simulation.stopped.disconnect(_on_simulation_stopped)
	OIPCommsSetup.disconnect_comms(self, _tag_group_initialized, _tag_group_polled)


func _write_bit(tag: OIPCommsTag, value: bool) -> void:
	if enable_comms and tag.is_ready():
		tag.write_bit(value)


func _on_simulation_started() -> void:
	_build_runtime()
	if enable_comms:
		_lights_tag.register(lights_tag_group_name, lights_tag_name, OIPCommsTag.TYPE_BOOL)
		_trigger_tag.register(trigger_tag_group_name, trigger_tag_name, OIPCommsTag.TYPE_BOOL)
		_good_read_tag.register(good_read_tag_group_name, good_read_tag_name, OIPCommsTag.TYPE_BOOL)
		_no_read_tag.register(no_read_tag_group_name, no_read_tag_name, OIPCommsTag.TYPE_BOOL)
		_barcode_tag.register(barcode_tag_group_name, barcode_tag_name, OIPCommsTag.TYPE_INT32)


func _on_simulation_stopped() -> void:
	_teardown_runtime()


func _tag_group_initialized(tag_group_name_param: String) -> void:
	_lights_tag.on_group_initialized(tag_group_name_param)
	_trigger_tag.on_group_initialized(tag_group_name_param)
	_good_read_tag.on_group_initialized(tag_group_name_param)
	_no_read_tag.on_group_initialized(tag_group_name_param)
	_barcode_tag.on_group_initialized(tag_group_name_param)


func _tag_group_polled(tag_group_name_param: String) -> void:
	if not enable_comms:
		return
	if _lights_tag.matches_group(tag_group_name_param) and _lights_tag.is_ready():
		var v: bool = _lights_tag.read_bit()
		if v != lights_on:
			lights_on = v
#endregion # PLC
