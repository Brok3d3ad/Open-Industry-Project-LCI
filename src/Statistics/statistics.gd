@tool
extends Node

## Attach to the Simulation root (or any node that stays alive while the
## scene is open) to print a one-line-per-bucket performance report to
## the Output panel every [member report_interval] seconds. Runs in the
## editor so heavy edit-time scenes can be profiled without entering
## simulation. Toggle via [member enabled] in the inspector.

## Seconds between reports. Each report covers exactly this window.
@export_range(0.1, 10.0, 0.1, "suffix:s") var report_interval: float = 1.0
## Frame time above this counts as a "hitch" (visible stutter).
@export_range(10.0, 1000.0, 1.0, "suffix:ms") var hitch_threshold_ms: float = 50.0
## Master toggle. Disabled scripts skip work entirely.
@export var enabled: bool = true

const MB: float = 1048576.0

var _elapsed: float = 0.0
var _frame_count: int = 0
var _frame_ms_sum: float = 0.0
var _frame_ms_max: float = 0.0
var _hitches: int = 0
var _last_reads: int = 0
var _last_writes: int = 0


func _ready() -> void:
	_last_reads = OIPCommsTag.read_count
	_last_writes = OIPCommsTag.write_count


func _process(delta: float) -> void:
	if not enabled:
		return
	var frame_ms: float = delta * 1000.0
	_frame_ms_sum += frame_ms
	if frame_ms > _frame_ms_max:
		_frame_ms_max = frame_ms
	if frame_ms > hitch_threshold_ms:
		_hitches += 1
	_frame_count += 1
	_elapsed += delta
	if _elapsed < report_interval:
		return
	_emit_report()
	_reset_window()


func _emit_report() -> void:
	var reads_total: int = OIPCommsTag.read_count
	var writes_total: int = OIPCommsTag.write_count
	var reads_per_s: float = float(reads_total - _last_reads) / _elapsed
	var writes_per_s: float = float(writes_total - _last_writes) / _elapsed
	var fps: float = Engine.get_frames_per_second()
	var avg_ms: float = _frame_ms_sum / maxi(_frame_count, 1)
	var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var static_mem: float = Performance.get_monitor(Performance.MEMORY_STATIC) / MB
	var video_mem: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / MB
	var texture_mem: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / MB
	var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var phys_active: int = int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var phys_pairs: int = int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	print("[stats] fps=%.1f avg=%.1fms max=%.1fms hitches=%d | proc=%.2fms phys=%.2fms"
			% [fps, avg_ms, _frame_ms_max, _hitches, process_ms, physics_ms])
	print("[stats] comms r/s=%.0f w/s=%.0f (total r=%d w=%d) | nodes=%d orphans=%d phys-active=%d pairs=%d draws=%d prims=%d"
			% [reads_per_s, writes_per_s, reads_total, writes_total,
					nodes, orphans, phys_active, phys_pairs, draws, prims])
	print("[stats] mem static=%.1fMB video=%.1fMB tex=%.1fMB"
			% [static_mem, video_mem, texture_mem])


func _reset_window() -> void:
	_elapsed = 0.0
	_frame_count = 0
	_frame_ms_sum = 0.0
	_frame_ms_max = 0.0
	_hitches = 0
	_last_reads = OIPCommsTag.read_count
	_last_writes = OIPCommsTag.write_count
