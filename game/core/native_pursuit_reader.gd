class_name NativePursuitReader
extends RefCounted
# Disabled unless the reviewed comparison project opts in. Never loads a library.
const ExactWorld = preload("res://game/world/cached_streamed_world.gd")
const ExactGenerator = preload("res://game/world/city_generator.gd")
const Physics = preload("res://game/world/streamed_world.gd")
var _source
var _kernel
var _hit_ids: PackedStringArray
var _world_revision: int
var _coverage_revision: int
var _origin: Array
var _bound_identity: Dictionary = {}
var _bound_tick := -1
var _active := false
var _serial := 0
var _native_queries := 0
var _counters: Dictionary = {}
var _direction_queried := false

class PursuitScope:
	extends RefCounted
	var _reader
	var _serial: int
	func _init(reader, serial: int) -> void:
		_reader = reader
		_serial = serial
	func close() -> void:
		if _reader != null:
			_reader._end_scope(_serial)
			_reader = null
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE and _reader != null:
			_reader._end_scope(_serial)
			_reader = null

class QueryView:
	extends RefCounted
	var _query_failure: Dictionary = {}
	func begin_navigation_queries() -> void: _query_failure.clear()
	func navigation_query_status() -> Dictionary:
		return {"ok":true} if _query_failure.is_empty() else _query_failure.duplicate(true)

class NavigationReader:
	extends RefCounted
	var _reader
	var _world = QueryView.new()
	func _init(reader) -> void: _reader = reader
	func direction(position: Vector2, target: Vector2, radius: float, tick: int) -> Dictionary:
		var result: Dictionary = _reader.read_direction(position,target,radius,tick)
		var first: Dictionary = _reader.navigation_query_status()
		if not first.ok and _world._query_failure.is_empty(): _world._query_failure = first.duplicate(true)
		return result
	func diagnostics() -> Dictionary: return _reader.navigation_diagnostics()

static func try_create(world):
	# Native arenas and diagnostic globals are main-thread-owned.
	# Worker validators retain original script readers, before any native access.
	if not Thread.is_main_thread(): return null
	if world == null or world.get_script() != ExactWorld or world._generator == null or world._generator.get_script() != ExactGenerator: return null
	if not ClassDB.class_exists("WingsResidentContext"): return null
	if Engine.get_version_info().get("hash","") != "7d41c59c457bd5a245092b4e7eb2d833e3b3f8c3": return null
	var keys: Array = world.chunk_keys().duplicate()
	if keys.size() > 64: return null
	keys.sort()
	var props: Dictionary = {}
	var cells: Array[Vector2] = []
	var revisions: Array[int] = []
	var unique_cells: Dictionary = {}
	for cell_index in keys.size():
		var chunk: Dictionary = world.localized_chunk(keys[cell_index])
		if chunk.is_empty() or not chunk.get("local_origin") is Vector2 or not chunk.get("geometry_revision") is int or chunk.geometry_revision < 0: return null
		var cell: Vector2 = chunk.local_origin / 768.0
		if not is_finite(cell.x) or not is_finite(cell.y) or cell.x != int(cell.x) or cell.y != int(cell.y) or absf(cell.x) > 64 or absf(cell.y) > 64 or unique_cells.has(cell): return null
		unique_cells[cell] = true
		cells.append(cell)
		revisions.append(chunk.geometry_revision)
		for prop in chunk.props:
			if not prop is Dictionary or not prop.get("prop_id") is String or props.has(prop.prop_id) or not prop.get("ground_footprint") is Rect2 or not prop.get("collision_mask") is int: return null
			props[prop.prop_id] = {"footprint":prop.ground_footprint,"mask":prop.collision_mask,"owner":cell_index}
	if props.size() > 65536 or props.size() != world._props.size(): return null
	var ids: Array = props.keys()
	ids.sort()
	var kernel = ClassDB.instantiate("WingsResidentContext")
	if kernel == null or not kernel.begin_snapshot(ids.size(),cells.size(),1): return null
	for cell_index in cells.size():
		if not kernel.set_cell(cell_index,cells[cell_index]) or not kernel.set_cell_meta(cell_index,cell_index,revisions[cell_index]): return null
	for index in ids.size():
		var prop: Dictionary = props[ids[index]]
		if not kernel.set_prop(index,prop.footprint,prop.mask) or not kernel.set_prop_owner(index,prop.owner): return null
	if not kernel.commit_snapshot(): return null
	var reader = load("res://game/core/native_pursuit_reader.gd").new()
	reader._source = world
	reader._kernel = kernel
	reader._hit_ids = PackedStringArray(ids)
	reader._world_revision = world._world_revision
	reader._coverage_revision = world._coverage_revision
	reader._origin = world._origin.duplicate()
	return reader

func matches_source() -> bool:
	return _source != null and _source.get_script() == ExactWorld and _source._world_revision == _world_revision and _source._coverage_revision == _coverage_revision and _source._origin == _origin
func attach_counters(counters: Dictionary) -> void:
	if is_same(_counters,counters): return
	_counters = counters
	_counters.admissions += 1
func _count(key: String, amount: int = 1) -> void:
	if not _counters.is_empty(): _counters[key] += amount
func bind_batch(tick: int, identity: Dictionary) -> void:
	_count("batches")
	_bound_tick = tick if not _active and matches_source() else -1
	_bound_identity = identity
func begin_scope(tick: int, identity: Dictionary):
	if _active or tick < 0 or _bound_tick < 0 or tick != _bound_tick or not is_same(identity,_bound_identity) or not matches_source() or _serial >= 9223372036854775807:
		_count("scope_refusals")
		return null
	_count("scopes")
	_serial += 1
	_active = true
	return PursuitScope.new(self,_serial)
func _end_scope(serial: int) -> void:
	if serial == _serial: _active = false
func active() -> bool: return _active
func navigation_reader(): return NavigationReader.new(self)
func _failure() -> Dictionary: return {"ok":false,"error_code":"world_not_ready"}
func _before() -> int:
	var code := 0 if _source._last_error.is_empty() else (1 if _source._last_error == "world_not_ready" else 2)
	var synchronized: bool = _kernel.sync_world_error(code)
	if not synchronized: return -1
	return _kernel.terrain_stat(5)
func _after(before: int) -> void:
	# Real native candidate queries join the same authoritative diagnostic total.
	var actual: int = _kernel.terrain_stat(5)-before
	_native_queries += actual
	_count("query_count",actual)
	_source._query_count += actual
	var code: int = _kernel.terrain_stat(2)
	if code == 1: _source._last_error = "world_not_ready"
	elif code == 0: _source._last_error = ""
	# Code2 preserves the exact opaque script-owned error string.
func read_walkable(position: Vector2, radius: float) -> Dictionary:
	if not _active or not matches_source(): return _failure()
	_count("walkable_calls")
	var before := _before()
	if before < 0: return _failure()
	var result: bool = _kernel.terrain_walkable(position,radius)
	_after(before)
	return {"ok":true,"walkable":result}
func read_move(position: Vector2, delta: Vector2, radius: float) -> Dictionary:
	if not _active or not matches_source(): return _failure()
	_count("move_calls")
	var before := _before()
	if before < 0: return _failure()
	var result: Vector2 = _kernel.terrain_move(position,delta,radius)
	_after(before)
	return {"ok":true,"position":result}
func read_sweep(position: Vector2, delta: Vector2, radius: float) -> Dictionary:
	if not _active or not matches_source(): return _failure()
	_count("sweep_calls")
	var before := _before()
	if before < 0: return _failure()
	var point: Vector2 = _kernel.terrain_sweep(position,delta,radius)
	var ok: bool = _kernel.terrain_stat(3) == 1
	var hit: int = _kernel.terrain_stat(4)
	var fraction: float = _kernel.terrain_fraction()
	_after(before)
	return {"ok":ok,"error_code":"" if ok else ("invalid_query" if not Physics._valid_query(position,delta,radius) else "world_not_ready"),"position":point,"hit_prop_id":"" if hit < 0 else _hit_ids[hit],"fraction":fraction}
func read_direction(position: Vector2, target: Vector2, radius: float, tick: int) -> Dictionary:
	_direction_queried = false
	# This is the one shared navigation owner; role/public physical APIs stay script.
	if not matches_source(): return _failure()
	_count("direction_calls")
	var before := _before()
	if before < 0 or not _kernel.nav_set_tick(tick): return _failure()
	_direction_queried = true
	var direction: Vector2 = _kernel.nav_direction(position,target,radius)
	var ok: bool = _kernel.nav_stat(0) == 1
	var code: int = _kernel.nav_stat(1)
	var errors := ["","unsupported_radius","blocked","world_not_ready","world_not_ready"]
	var points: Array = []
	for index in _kernel.nav_stat(2): points.append(_kernel.nav_waypoint(index))
	var length: float = _kernel.nav_length()
	_after(before)
	return {"ok":ok,"direction":direction,"waypoints":points,"length":length,"error_code":errors[code]}
func navigation_query_status() -> Dictionary:
	if not _direction_queried: return _failure()
	var failure: int = _kernel.nav_stat(6)
	if failure <= 0: return {"ok":true}
	var result := {"ok":false,"error_code":"world_not_ready" if failure == 1 else "invalid_query"}
	if _kernel.nav_stat(12) == 1: result.merge({"position":_kernel.nav_failure_position(),"hit_prop_id":"","fraction":0.0})
	return result
func navigation_diagnostics() -> Dictionary:
	return {"grid_count":_kernel.nav_stat(3),"grid_builds":_kernel.nav_stat(4),"route_builds":_kernel.nav_stat(5)}
