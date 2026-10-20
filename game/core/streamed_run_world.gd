class_name StreamedRunWorld
extends RefCounted
# NEW 2026-10-10 adapter, not a reconstruction of the missing latest helper.
# Owns only replaceable derived caches. Every persistent change is a proposal.
const Mobility = preload("res://game/core/player_mobility.gd")
const LegacyMobility = preload("res://game/core/legacy_player_mobility_v1.gd")
const Address = preload("res://game/world/world_address.gd")
const Population = preload("res://game/core/city_population.gd")
const Generator = preload("res://game/world/city_generator.gd")
const Props = preload("res://game/world/world_prop_catalog.gd")
const Stream = preload("res://game/world/cached_streamed_world.gd")
const Navigation = preload("res://game/world/precise_city_navigation.gd")
const NavigationView = preload("res://game/world/streamed_navigation_view.gd")
const Interactions = preload("res://game/world/world_interactions.gd")
const Evacuation = preload("res://game/world/evacuation_route.gd")
const Codec = preload("res://game/world/world_delta_codec.gd")
const FiniteGeometry = preload("res://game/combat/world_geometry.gd")
const Checkpoint = preload("res://game/app/world_checkpoint_adapter.gd")
const CONTENT_REVISION := "ch01.3-rebuild.7-grabber-hand"
const CITY_INACTIVE_EXIT := [0.0,0.0,0.0,0.0]
const VIEW_MARGIN := 896.0
const MAX_LOCAL := 49152.0
const LIMITS := {"entities":512,"projectiles":256,"drops":256,"telegraphs":512,"player_attack_instances":64,"enemy_attack_instances":64}
const POSITION_FIELDS := ["position","previous_position","origin","target","locked_origin","locked_target","landing_target"]
const GEOMETRY_POSITIONS := ["position","origin","target","center"]
const WORLD_FIELDS := ["schema_version","mode","stage","scene_id","generator_revision","template_revision","content_fingerprint","origin_chunk","origin_revision","world_revision","delta_root","dirty_chunks","next_structure_strike_tick","evacuation"]
class LiveDefinitions:
	extends RefCounted
	var _owner: WeakRef
	var _nonce: RefCounted
	var _data: Dictionary
	var owner: WeakRef:
		get: return _owner
		set(_value): pass
	var nonce: RefCounted:
		get: return _nonce
		set(_value): pass
	var data: Dictionary:
		get: return _data
		set(_value): pass
	func _init(issuer, key: RefCounted, values: Dictionary) -> void:
		_owner = weakref(issuer); _nonce = key; _data = values
var _definition_nonce := RefCounted.new()
var _definition_proof
var _issued_definition_proof: LiveDefinitions
var _definitions: Dictionary
var _generator
var _world
var _navigation
var _native_pursuit
var _hydration: Dictionary = {}
var _stamp := "" # Diagnostic serialization only; numeric forms are not identity.
var _prepared_identity: Dictionary = {}
var _valid := false
var _last_status: Dictionary = {}
var _query_failure: Dictionary = {}
var _stage := ""
const BLOCKED_RETRY_TICKS := 12
var _blocked_routes := {}

func _init(definitions: Dictionary = {}) -> void:
	_definitions = definitions.duplicate(true)
	if not _definitions_shape(_definitions): return
	if not Props.validate(_definitions.props,_definitions.asset_manifest).is_empty(): return
	_generator = Generator.new(_definitions.templates,_definitions.props)
	_valid = _generator.validate().is_empty()
	if _valid and get_script() == load("res://game/core/streamed_run_world.gd"):
		var data := _definitions.duplicate(true)
		_freeze_live_definitions(data)
		_definition_proof = LiveDefinitions.new(self,_definition_nonce,data)
		_issued_definition_proof = _definition_proof
static func _freeze_live_definitions(value: Variant) -> void:
	if value is Dictionary:
		for key in value: _freeze_live_definitions(value[key])
		value.make_read_only()
	elif value is Array:
		for item in value: _freeze_live_definitions(item)
		value.make_read_only()
func _fork_live_configuration():
	if get_script() != load("res://game/core/streamed_run_world.gd") or not _valid or not _definition_proof is LiveDefinitions: return null
	if _definition_proof != _issued_definition_proof or _definition_proof.owner == null or _definition_proof.owner.get_ref() != self or _definition_proof.nonce != _definition_nonce or not _definition_proof.data.is_read_only(): return null
	var result = get_script().new()
	result._definitions = _definition_proof.data.duplicate(true)
	result._generator = Generator.new(result._definitions.templates,result._definitions.props)
	result._valid = true
	result._definition_proof = LiveDefinitions.new(result,result._definition_nonce,_definition_proof.data)
	result._issued_definition_proof = result._definition_proof
	return result
func _prepare_live(state: Dictionary, hydration: Dictionary, commands: Array, source) -> Dictionary:
	# Only a new unpublished helper can prepare in place; failed callers discard it.
	if _world != null or not _prepared_identity.is_empty() or not _definition_proof is LiveDefinitions: return failure("world_not_ready")
	return _prepare_candidate(state,hydration,commands,source)
# An ordinary Core rebase changes only localization, never absolute terrain.
# Bind retention to the real pre-step witness; generic matches remains exact.
func _rebase_eligible(previous: Dictionary, proposed: Dictionary, hydration: Dictionary) -> bool:
	if get_script() != load("res://game/core/streamed_run_world.gd") or not _valid or _stage != "city" or _world == null or _world.get_script() != Stream: return false
	if not _query_failure.is_empty() or not _world._last_error.is_empty() or not _definition_proof is LiveDefinitions: return false
	if _definition_proof != _issued_definition_proof or _definition_proof.owner == null or _definition_proof.owner.get_ref() != self or _definition_proof.nonce != _definition_nonce or not _definition_proof.data.is_read_only(): return false
	if _generator == null or _generator.get_script() != Generator or _world._generator != _generator: return false
	if not _same_json(_definitions,_definition_proof.data): return false
	if not validate_world(previous).get("ok",false) or not validate_world(proposed).get("ok",false): return false
	if previous.world.stage != "city" or proposed.world.stage != "city" or not matches(previous): return false
	if not _same_json(previous.get("run_id"),proposed.get("run_id")) or not _same_json(previous.get("seed"),proposed.get("seed")) or not _same_json(previous.get("run_config"),proposed.get("run_config")): return false
	if _world._seed != int(previous.seed) or _world._world_revision != int(previous.world.world_revision) or not _same_json(_world._origin,previous.world.origin_chunk): return false
	for value in [previous,proposed]:
		if value.has("player_mobility") and (not value.player_mobility is Dictionary or not value.player_mobility.get("schema_version") is int or value.player_mobility.schema_version != 2): return false
	if not previous.get("player") is Dictionary or not point_valid(previous.player.get("position")): return false
	var normalized: Dictionary = Address.normalize(previous.world.origin_chunk,vec(previous.player.position))
	if not normalized.get("ok",false) or normalized.offset == Vector2.ZERO or previous.world.origin_revision >= Codec.MAX_JSON_INTEGER: return false
	var expected: Dictionary = _geometry_identity(previous.world).duplicate()
	expected.origin_chunk = normalized.chunk
	expected.origin_revision = int(previous.world.origin_revision)+1
	if not _same_json(expected,_geometry_identity(proposed.world)): return false
	for key in _hydration:
		if not hydration.has(key) or not _same_json(_hydration[key],hydration[key]): return false
	return true
func _prepare_rebased(previous: Dictionary, proposed: Dictionary, hydration: Dictionary, commands: Array = []) -> Dictionary:
	var result = _fork_live_configuration()
	if result == null: return failure("world_not_ready")
	var prepared: Dictionary = result._prepare_candidate(proposed,hydration,commands,self,previous)
	if not prepared.get("ok",false): return prepared
	return {"ok":true,"helper":result}
func valid() -> bool: return _valid
func fresh(): return get_script().new(_definitions)
static func enabled(state: Dictionary) -> bool:
	# Dispatchers must reject a present malformed world, never fall back to finite.
	return state.get("world") is Dictionary and state.world.get("mode") is String and state.world.mode == "streamed_city"
static func initial_world(content_fingerprint: String) -> Dictionary:
	if not Codec.valid_hash(content_fingerprint): return failure("content_mismatch")
	return {"schema_version":1,"mode":"streamed_city","stage":"city","scene_id":"city","generator_revision":"city_v1","template_revision":"ch01_city_1","content_fingerprint":content_fingerprint,"origin_chunk":["0","0"],"origin_revision":0,"world_revision":0,"delta_root":Codec.empty_root(),"dirty_chunks":[],"next_structure_strike_tick":0,"evacuation":{}}
static func validate_world(state: Dictionary) -> Dictionary:
	if not state.get("world") is Dictionary: return failure("invalid_snapshot")
	var world: Dictionary = state.world
	if not Codec.integer(world.get("schema_version")): return failure("invalid_snapshot")
	if world.schema_version > 2: return failure("unsupported_schema")
	if not int(world.schema_version) in [1,2]: return failure("invalid_snapshot")
	if not Codec.integer(state.get("schema_version")): return failure("invalid_snapshot")
	if state.schema_version > 2: return failure("unsupported_schema")
	if state.schema_version != 2: return failure("invalid_snapshot")
	# Variant equality is not type-safe in GDScript. Check saved identities before
	# comparison so malformed data cannot abort with an empty Dictionary.
	for field in ["mode","stage","scene_id","generator_revision","template_revision","content_fingerprint"]:
		if not world.get(field) is String: return failure("invalid_snapshot")
	if not state.get("content_revision") is String: return failure("invalid_snapshot")
	if world.get("mode") != "streamed_city" or world.get("generator_revision") != "city_v1" or world.get("template_revision") != "ch01_city_1" or state.get("content_revision") != CONTENT_REVISION: return failure("content_mismatch")
	if not state.get("rules") is Dictionary or not Codec.valid_hash(state.rules.get("content_fingerprint")): return failure("invalid_snapshot")
	if world.get("content_fingerprint") != state.rules.content_fingerprint: return failure("content_mismatch")
	if not world.get("stage") in ["city","dock"]: return failure("content_mismatch")
	if not Codec.exact_keys(world,WORLD_FIELDS+(["escape_rect"] if world.stage == "dock" else [])+(["dormant"] if world.schema_version == 2 else [])): return failure("invalid_snapshot")
	if world.schema_version == 2:
		if not Population.dormant_shape(world.dormant): return failure("invalid_snapshot")
		if world.stage == "dock" and (not world.dormant.entities.is_empty() or not world.dormant.drops.is_empty()): return failure("invalid_snapshot")
		if (state.get("final_started_tick") is int or state.get("final_started_tick") is float) and state.final_started_tick >= 0:
			# The final physical actor alone may use existing absolute parking,
			# only after its complete attack chain has reached quiescent move.
			if not world.dormant.drops.is_empty() or world.dormant.entities.size() > 1: return failure("invalid_snapshot")
			for entry in world.dormant.entities:
				if entry.record.get("enemy_id") != "armored_titan" or entry.record.get("boss_id") != "ch01_final_armored" or not Population.quiescent(state,entry.record): return failure("invalid_snapshot")
	if world.scene_id != ("city" if world.stage == "city" else "authored_dock"): return failure("invalid_snapshot")
	if not world.origin_chunk is Array: return failure("invalid_snapshot")
	var address := Address.parse(world.origin_chunk)
	if not address.ok: return address
	if not world.delta_root is Dictionary: return failure("invalid_snapshot")
	var root := Codec.valid_root(world.delta_root)
	if not root.ok: return root
	for key in ["origin_revision","world_revision","next_structure_strike_tick"]:
		if not Codec.integer(world[key]) or world[key] > Codec.MAX_JSON_INTEGER: return failure("invalid_snapshot")
	var dirty := Codec.normalize_records(world.dirty_chunks)
	if not dirty.ok: return dirty
	if not _same_json(dirty.records,world.dirty_chunks) or (not dirty.records.is_empty() and world.world_revision == 0): return failure("invalid_snapshot")
	if not world.evacuation is Dictionary: return failure("invalid_snapshot")
	var evacuation: Dictionary = world.evacuation
	if not evacuation.is_empty():
		if not state.get("phase") in ["evacuation","dead","won","abandoned"] or not _tick(state.get("final_started_tick")) or not _tick(evacuation.get("selected_tick")) or state.final_started_tick > evacuation.selected_tick: return failure("invalid_snapshot")
		var fields := ["passage_id","chunk","selected_tick"]+(["transition_command_id","transition_tick"] if world.stage == "dock" else [])
		if not Codec.exact_keys(evacuation,fields) or not evacuation.chunk is Array or not Address.parse(evacuation.chunk).ok: return failure("invalid_snapshot")
		if not evacuation.passage_id is String or evacuation.passage_id != "passage:city_v1:%s:%s" % [evacuation.chunk[0],evacuation.chunk[1]]: return failure("invalid_snapshot")
		if not _tick(evacuation.selected_tick) or not _tick(state.get("active_tick")) or evacuation.selected_tick > state.active_tick: return failure("invalid_snapshot")
	if world.stage == "dock":
		if evacuation.is_empty() or not evacuation.transition_command_id is String or evacuation.transition_command_id.is_empty() or not _tick(evacuation.transition_tick) or evacuation.transition_tick < evacuation.selected_tick or evacuation.transition_tick > state.active_tick: return failure("invalid_snapshot")
		if not _dock_escape_rect(world.escape_rect) or world.origin_chunk != ["0","0"] or world.origin_revision < 1: return failure("invalid_snapshot")
	return {"ok":true}
static func requirements(state: Dictionary, commands: Array = []) -> Dictionary:
	var checked := validate_world(state)
	if not checked.ok: return checked
	if not state.get("player") is Dictionary or not point_valid(state.player.get("position")) or not number(state.player.get("radius")) or state.player.radius > 32: return failure("invalid_snapshot")
	if not state.get("run_id") is String or state.run_id.is_empty() or not _tick(state.get("seed")): return failure("invalid_snapshot")
	var command_check := _validate_commands(state,commands)
	if not command_check.ok: return command_check
	# This spatial boundary also runs after Core increments the active clock,
	# before movement. Save admission separately enforces exact mobility clocks.
	if state.has("player_mobility") and not Mobility.validate(state,false).is_empty(): return failure("invalid_player_mobility")
	# Dock queries belong exclusively to its authored finite geometry, never to a
	# city distance window or hydrated city chunk. Core selects that backend.
	if state.world.stage == "dock": return {"ok":true,"chunks":[],"stage":"dock","origin_chunk":state.world.origin_chunk.duplicate(),"offset":[0,0]}
	var population := Population.plan(state)
	if not population.get("ok",false): return population
	var origin: Array = state.world.origin_chunk
	var player := vec(state.player.position)
	var normalized := Address.normalize(origin,player)
	if not normalized.ok: return normalized
	var rectangles: Array[Rect2] = [Rect2(player-Vector2.ONE*VIEW_MARGIN,Vector2.ONE*VIEW_MARGIN*2)]
	if state.has("player_mobility"):
		if state.player_mobility.phase != "ground":
			var mobility_route := Mobility.route_sample(state.player_mobility,origin)
			if not mobility_route.get("ok",false): return mobility_route
			for index in range(1,mobility_route.points.size()): rectangles.append(segment_rect(mobility_route.points[index-1],mobility_route.points[index],float(state.player.radius)))
	for collection in LIMITS:
		if not state.get(collection) is Array or state[collection].size() > LIMITS[collection]: return failure("invalid_snapshot")
		for index in state[collection].size():
			var record = state[collection][index]
			if not record is Dictionary: return failure("invalid_snapshot")
			var suspended: bool = (collection == "entities" and (index in population.retire or index in population.park_entities)) or (collection == "drops" and index in population.park_drops)
			var validated_only: Array[Rect2] = []
			var bounds := _record_bounds(record,validated_only if suspended else rectangles,collection == "entities" and record.get("action_state","") == "move")
			if not bounds.ok: return bounds
			if collection == "entities" and (not point_valid(record.get("position")) or not number(record.get("radius")) or record.radius > 32 or not number(record.get("speed")) or record.speed > 960): return failure("invalid_snapshot")
			if suspended: continue
			if collection == "entities":
				if not point_valid(record.get("position")) or not number(record.get("radius")) or record.radius > 32 or not number(record.get("speed")) or record.speed > 960: return failure("invalid_snapshot")
				rectangles.append(segment_rect(vec(record.position),player,64))
			elif collection == "enemy_attack_instances" and record.get("role_id") in ["grabber","quadruped","stone_thrower"]:
				if not point_valid(record.get("locked_origin")) or not point_valid(record.get("locked_direction")) or not record.get("profile") is Dictionary or not number(record.profile.get("length")) or not number(record.profile.get("width")): return failure("invalid_snapshot")
				rectangles.append(segment_rect(vec(record.locked_origin),vec(record.locked_origin)+vec(record.locked_direction)*float(record.profile.length),float(record.profile.width)*0.5))
			elif collection == "projectiles":
				if not point_valid(record.get("position")) or not point_valid(record.get("velocity")) or not number(record.get("radius")) or record.radius > 32: return failure("invalid_snapshot")
				rectangles.append(segment_rect(vec(record.position),vec(record.position)+vec(record.velocity)/60.0,float(record.radius)))
	for collection in ["entities","drops"]:
		for index in population["wake_"+collection]:
			var entry: Dictionary = state.world.dormant[collection][index]
			var relative := Address.relative(entry.chunk,Vector2.ZERO,origin)
			if not relative.get("ok",false): return relative
			var localized := Population.translate_record(entry.record,relative.local)
			if not localized.get("ok",false): return localized
			var bounds := _record_bounds(localized.record,rectangles,collection == "entities")
			if not bounds.get("ok",false): return bounds
			if collection == "entities":
				if not number(localized.record.get("radius")) or localized.record.radius > 32 or not number(localized.record.get("speed")) or localized.record.speed > 960: return failure("invalid_snapshot")
				rectangles.append(segment_rect(vec(localized.record.position),player,64))
	for command in commands:
		if not spatial_command(command): continue
		var bounds := _record_bounds(command.payload,rectangles)
		if not bounds.ok: return bounds
		for field in POSITION_FIELDS:
			if command.payload.has(field): rectangles.append(segment_rect(player,vec(command.payload[field]),64))
	var unique := {}
	# Per-call only: every record/rectangle is still validated, but repeated
	# local cells share the same checked int64 address conversion.
	var admitted_cells := {}
	for rectangle in rectangles:
		var added := _add_rect(unique,rectangle,origin,normalized.chunk,admitted_cells)
		if not added.ok: return added
	for change in state.world.dirty_chunks:
		var relative := Address.relative(change.chunk,Vector2.ZERO,normalized.chunk)
		if not relative.ok or relative.local.abs().x > 2304 or relative.local.abs().y > 2304: return failure("delta_stage_required")
		unique[Address.key(change.chunk)] = change.chunk.duplicate()
	if unique.size() > 49: return failure("working_set_capacity")
	var chunks: Array = unique.values()
	chunks.sort_custom(Address.less)
	return {"ok":true,"chunks":chunks,"stage":"city","origin_chunk":normalized.chunk,"offset":[normalized.offset.x,normalized.offset.y]}
func prepare(state: Dictionary, hydration: Dictionary, commands: Array = []) -> Dictionary:
	return _prepare_candidate(state,hydration,commands)
func _prepare_candidate(state: Dictionary, hydration: Dictionary, commands: Array, source = null, rebase_previous: Dictionary = {}) -> Dictionary:
	if not _valid: return failure("invalid_generator")
	if not rebase_previous.is_empty():
		# Only a newly forked unpublished helper may consume this private witness.
		if get_script() != load("res://game/core/streamed_run_world.gd") or source == null or source == self or source.get_script() != get_script() or _world != null or not _prepared_identity.is_empty(): return failure("world_not_ready")
		if not _definition_proof is LiveDefinitions or _definition_proof != _issued_definition_proof or _definition_proof.owner == null or _definition_proof.owner.get_ref() != self or _definition_proof.nonce != _definition_nonce: return failure("world_not_ready")
		if not source._rebase_eligible(rebase_previous,state,hydration) or _definition_proof.data != source._definition_proof.data: return failure("world_not_ready")
	var needed := requirements(state,commands)
	if not needed.ok: return needed
	if needed.stage == "dock":
		_native_pursuit = null
		_world = null; _navigation = null; _hydration.clear(); _blocked_routes.clear(); _stage = "dock"
		_remember_identity(state); _query_failure.clear(); _last_status = {"ok":true,"stage":"dock"}
		return _last_status.duplicate(true)
	# Always build privately: failed hydration/dirty validation cannot partially
	# replace an existing run's cache. Call prepare only when coverage is needed.
	# The exact generator assumes a typed delta slot ID; validate each packet
	# before crossing that recovered boundary without changing its bytes.
	for chunk in needed.chunks:
		var key := Address.key(chunk)
		if not hydration.has(key): continue # Exact Stream preserves missing-key detail.
		if not hydration[key] is Array: return failure("invalid_hydration")
		var checked := Codec.normalize_records([{"chunk":chunk,"props":hydration[key]}])
		if not checked.ok: return checked
	var candidate
	if rebase_previous.is_empty():
		candidate = _retained_candidate(source,state,hydration,needed.chunks) if source != null else null
	else:
		candidate = source._world._fork_retained(_generator,needed.chunks)
	var retained: bool = candidate != null
	if candidate == null: candidate = Stream.new(_generator,int(state.seed))
	var prepared: Dictionary = candidate.prepare(needed.chunks,[],hydration,state.world.origin_chunk,needed.origin_chunk)
	if not prepared.ok: return prepared
	if retained: candidate._coverage_revision = 1
	if state.world.world_revision > 0:
		var applied: Dictionary = candidate.apply_props(state.world.dirty_chunks,int(state.world.world_revision))
		if not applied.ok: return applied
	if state.has("player_mobility") and state.player_mobility.phase != "ground":
		# Validate privately; failed preparation must preserve the installed cache.
		var probe = self if source != null else fresh()
		probe._world = candidate
		probe._stage = "city"
		probe._remember_identity(state)
		var clearance: Dictionary = probe.mobility_player_clearance(state)
		if not clearance.get("ok",false): return clearance
		if not clearance.get("walkable",false): return failure("blocked")
	elif not candidate.walkable(vec(state.player.position),float(state.player.radius)): return failure("blocked")
	var next_hydration := {}
	for chunk in needed.chunks:
		var key := Address.key(chunk)
		next_hydration[key] = hydration[key].duplicate(true)
	var native_reader = null
	if get_script() == load("res://game/core/streamed_run_world.gd") and ProjectSettings.get_setting("wings/native_pursuit",false):
		native_reader = load("res://game/core/native_pursuit_reader.gd").try_create(candidate)
	_world = candidate; _native_pursuit = native_reader
	_navigation = Navigation.new(NavigationView.new(_world)) if native_reader == null else native_reader.navigation_reader()
	_hydration = next_hydration
	_blocked_routes.clear()
	_remember_identity(state); _stage = "city"; _query_failure.clear(); _last_status = prepared.duplicate(true)
	return prepared
func _retained_candidate(source, state: Dictionary, hydration: Dictionary, required: Array):
	# A weak hint is never authority. Retain only exact, already prepared geometry
	# with the same source hydration; all admission and delta validation still run.
	if get_script() != load("res://game/core/streamed_run_world.gd") or source == null or source.get_script() != get_script() or source == self: return null
	if not _valid or not source._valid or source._stage != "city" or state.world.stage != "city" or source._world == null or source._world.get_script() != Stream: return null
	if not source._query_failure.is_empty() or not source.matches(state) or not _same_json(_definitions,source._definitions): return null
	if source._world._generator != source._generator or source._world._world_revision != int(state.world.world_revision): return null
	if source._generator.get_script() != Generator or _generator.get_script() != Generator or source._world._seed != int(state.seed) or not _same_json(source._world._origin,state.world.origin_chunk): return null
	if state.has("player_mobility") and state.player_mobility.schema_version != 2: return null
	for chunk in required:
		var key := Address.key(chunk)
		if source._world._chunks.has(key) and (not source._hydration.has(key) or not hydration.has(key) or not _same_json(source._hydration[key],hydration[key])): return null
	return source._world._fork_retained(_generator,required)
func _remember_identity(state: Dictionary) -> void:
	# One private snapshot at successful publication. No per-tick deep copy, and
	# callers cannot mutate the installed authority through shared dictionaries.
	_prepared_identity = {"run_id":state.run_id,"seed":state.seed,"world":_geometry_identity(state.world).duplicate(true)}
	_stamp = stamp(state)
func matches(state: Dictionary) -> bool:
	# Core restore normalizes integral JSON floats. Match their semantic values,
	# while retaining exact run, world fields, nested values and array ordering.
	return not _prepared_identity.is_empty() and _same_json(_prepared_identity.run_id,state.get("run_id")) and _same_json(_prepared_identity.seed,state.get("seed")) and _same_json(_prepared_identity.world,_geometry_identity(state.get("world",{})))
static func _geometry_identity(world: Variant) -> Variant:
	if not world is Dictionary: return world
	# Absolute dormant records own no active geometry. XP aggregation/parking
	# must not rebuild terrain; every pre-existing terrain identity stays exact.
	if not world.has("dormant"): return world
	var identity: Dictionary = world.duplicate()
	identity.erase("dormant")
	return identity
func _acknowledge_autosave_world(state: Dictionary, captured_snapshot: Dictionary, receipt: Dictionary, confirmed_world: Dictionary) -> Dictionary:
	# Called only by the main Core after controller authority confirmation. All
	# validation and allocation precede the first assignment; no callbacks/yields.
	var checked := validate_world(state)
	if not checked.ok: return checked
	checked = validate_world(captured_snapshot)
	if not checked.ok: return checked
	if _stage == "dock" and state.world.stage == "dock" and captured_snapshot.world.stage == "dock":
		return _acknowledge_dock_world(state,captured_snapshot.world,receipt,confirmed_world)
	if _stage != "city" or state.world.stage != "city" or captured_snapshot.world.stage != "city": return failure("world_ack_stage")
	if _world == null or _world.get_script() != Stream or not _query_failure.is_empty(): return failure("world_not_ready")
	if not readiness(state).get("ok",false): return failure("world_not_ready")
	var current: Dictionary = state.world
	var captured: Dictionary = captured_snapshot.world
	for field in ["mode","stage","scene_id","generator_revision","template_revision","content_fingerprint","origin_chunk","origin_revision"]:
		if not _same_json(current[field],captured[field]): return failure("world_ack_identity")
	if not _same_json(current.delta_root,captured.delta_root) or current.world_revision < captured.world_revision: return failure("world_ack_stale")
	if current.world_revision == captured.world_revision and not _same_json(current.dirty_chunks,captured.dirty_chunks): return failure("world_ack_stale")
	var accepted := Checkpoint.accept_receipt(captured,receipt)
	if not accepted.ok: return accepted
	if not _same_json(receipt.base_root,captured.delta_root) or not _same_json(accepted.world,confirmed_world): return failure("world_receipt_stale")
	if captured.dirty_chunks.is_empty() and not _same_json(receipt.base_root,receipt.candidate_root): return failure("world_receipt_stale")
	if not _same_json(_world._origin,current.origin_chunk): return failure("world_not_ready")
	var bookkeeping: Dictionary = _world._prepare_persisted_subset(current.dirty_chunks,captured.dirty_chunks,int(current.world_revision))
	if not bookkeeping.ok: return bookkeeping
	# The original A hydration is an additional completeness witness. Every
	# previously persisted modification must be included in each replacement C.
	var next_hydration := _hydration.duplicate(true)
	for record in captured.dirty_chunks:
		var key := Address.key(record.chunk)
		if not _hydration.get(key) is Array: return failure("world_ack_hydration")
		var base := Codec.normalize_records([{"chunk":record.chunk,"props":_hydration[key]}])
		if not base.ok or not _same_json(base.records[0].props,_hydration[key]): return failure("world_ack_hydration")
		var slots := {}
		for prop in record.props: slots[prop.slot_id] = prop
		for prop in _hydration[key]:
			if not slots.has(prop.slot_id) or slots[prop.slot_id].hp > prop.hp or (prop.destroyed and not slots[prop.slot_id].destroyed): return failure("world_ack_incomplete")
		next_hydration[key] = record.props.duplicate(true)
	var remaining := []
	for record in current.dirty_chunks:
		if bookkeeping.next_dirty.has(Address.key(record.chunk)): remaining.append(record.duplicate(true))
	var next_world := current.duplicate(true)
	next_world.delta_root = confirmed_world.delta_root.duplicate(true)
	next_world.dirty_chunks = remaining
	var next_identity := {"run_id":state.run_id,"seed":state.seed,"world":_geometry_identity(next_world).duplicate(true)}
	var next_stamp := stamp({"run_id":state.run_id,"seed":state.seed,"world":next_world})
	var result := {"ok":true,"cleared_chunks":current.dirty_chunks.size()-remaining.size(),"retained_chunks":remaining.size()}
	# Single non-yielding publication. Physical chunks/props, navigation,
	# coverage, geometry revisions and every live non-world field stay intact.
	state.world = next_world
	_hydration = next_hydration
	_prepared_identity = next_identity
	_stamp = next_stamp
	_world._apply_persisted_subset(bookkeeping.next_dirty)
	return result
func _acknowledge_dock_world(state: Dictionary, captured_world: Dictionary, receipt: Dictionary, confirmed_world: Dictionary) -> Dictionary:
	# Dock has no streamed physical chunks. Only an exactly unchanged world can
	# acknowledge its own receipt; a city capture must use the paused latest retry.
	if _world != null or _navigation != null or not _hydration.is_empty() or not _query_failure.is_empty() or not readiness(state).get("ok",false): return failure("world_not_ready")
	if not _same_json(state.world,captured_world): return failure("world_ack_stale")
	var accepted := Checkpoint.accept_receipt(captured_world,receipt)
	if not accepted.ok: return accepted
	if not _same_json(receipt.base_root,captured_world.delta_root) or not _same_json(accepted.world,confirmed_world): return failure("world_receipt_stale")
	if captured_world.dirty_chunks.is_empty() and not _same_json(receipt.base_root,receipt.candidate_root): return failure("world_receipt_stale")
	var next_world := confirmed_world.duplicate(true)
	var next_identity := {"run_id":state.run_id,"seed":state.seed,"world":_geometry_identity(next_world).duplicate(true)}
	var next_stamp := stamp({"run_id":state.run_id,"seed":state.seed,"world":next_world})
	state.world = next_world
	_prepared_identity = next_identity
	_stamp = next_stamp
	return {"ok":true,"cleared_chunks":captured_world.dirty_chunks.size(),"retained_chunks":0}
func readiness(state: Dictionary, commands: Array = []) -> Dictionary:
	var needed := requirements(state,commands)
	if not needed.ok: return needed
	var missing := []
	var matching := matches(state)
	var resident := {}
	if matching and _world != null:
		for key in _world.chunk_keys(): resident[key] = true
	for chunk in needed.chunks:
		var key := Address.key(chunk)
		if not matching or not resident.has(key): missing.append(key)
	if not matching: return {"ok":false,"error_code":"world_not_ready","missing_delta_keys":missing}
	return {"ok":missing.is_empty(),"error_code":"" if missing.is_empty() else "world_not_ready","missing_delta_keys":missing}
func begin_query_batch(state: Dictionary, commands: Array = []) -> Dictionary:
	var ready := readiness(state,commands)
	if not ready.ok: return ready
	_query_failure.clear()
	return {"ok":true}
# Core binds once after commands/player movement and before ordered actor actions.
# All public role, mobility, projectile and player physics stay on the real world.
func _bind_native_pursuit(state: Dictionary, counters: Dictionary) -> void:
	if _native_pursuit == null:
		if ProjectSettings.get_setting("wings/native_pursuit",false):
			counters.fallback_batches += 1
		return
	_native_pursuit.attach_counters(counters)
	_native_pursuit.bind_batch(int(state.active_tick) if matches(state) else -1,_prepared_identity)
func _begin_native_pursuit(tick: int):
	return null if _native_pursuit == null else _native_pursuit.begin_scope(tick,_prepared_identity)
func query_status() -> Dictionary:
	return {"ok":true} if _query_failure.is_empty() else _query_failure.duplicate(true)
func render_view(state: Dictionary) -> Dictionary:
	if not matches(state): return {"ok":false,"error_code":"world_not_ready","chunks":[]}
	if _stage == "dock": return {"ok":true,"stage":"dock","scene_id":"authored_dock","origin_chunk":["0","0"],"origin_revision":state.world.origin_revision,"chunks":[]}
	var result: Dictionary = _world.render_view()
	result.ok = true; result.scene_id = "city"; result.origin_revision = state.world.origin_revision
	return result
func status() -> Dictionary:
	var result := _last_status.duplicate(true)
	if _world != null: result.merge(_world.diagnostics(),true)
	result.stage = _stage; result.resident_chunks = 0 if _world == null else _world.chunk_keys().size()
	result.resident_hydration = _hydration.size(); result.query_status = query_status()
	return result
func walkable(position: Vector2, radius: float) -> Dictionary:
	var checked := _query_guard(position,Vector2.ZERO,radius)
	if not checked.ok: return checked
	if _native_pursuit != null and _native_pursuit.active(): return _query_result(_native_pursuit.read_walkable(position,radius))
	return {"ok":true,"walkable":_world.walkable(position,radius)}
func move(position: Vector2, delta: Vector2, radius: float) -> Dictionary:
	var checked := _query_guard(position,delta,radius)
	if not checked.ok: return checked
	if _native_pursuit != null and _native_pursuit.active(): return _query_result(_native_pursuit.read_move(position,delta,radius))
	return {"ok":true,"position":_world.move(position,delta,radius)}
func sweep(position: Vector2, delta: Vector2, radius: float) -> Dictionary:
	var checked := _query_guard(position,delta,radius)
	if not checked.ok: return checked
	if _native_pursuit != null and _native_pursuit.active(): return _query_result(_native_pursuit.read_sweep(position,delta,radius))
	return _query_result(_world.sweep(position,delta,radius))
func cover_query(origin: Vector2, target: Vector2, radius: float, mask: int) -> Dictionary:
	if mask < 0 or mask > 31: return _query_result(failure("invalid_query"))
	var checked := _query_guard(origin,target-origin,radius)
	return checked if not checked.ok else _query_result(_world.cover_sweep(origin,target-origin,radius,mask))
func direction(position: Vector2, target: Vector2, radius: float, tick: int, actor_id: String = "") -> Dictionary:
	if tick < 0: return _query_result(failure("invalid_query"))
	# Full 7x7-admissible rectangle is preflighted; the exact navigation owns
	# connected route/grid work, never a truncated legacy solids dictionary.
	var checked := _query_guard(position,target-position,radius)
	if not checked.ok: return checked
	var revision: int = _world.diagnostics().world_revision
	if not actor_id.is_empty() and _blocked_routes.has(actor_id):
		var prior: Dictionary = _blocked_routes[actor_id]
		# Reuse only the identical physical query. A shifted target can open a
		# route even within one grid cell; cold and warm motion must agree.
		if tick >= prior.tick and tick-prior.tick < BLOCKED_RETRY_TICKS and prior.position == position and prior.radius == radius and prior.revision == revision and target == prior.target:
			return {"ok":true,"direction":Vector2.ZERO,"blocked":true,"deferred":true,"wait_ticks":tick-prior.tick}
		_blocked_routes.erase(actor_id)
	_navigation._world.begin_navigation_queries()
	var result: Dictionary = _navigation.direction(position,target,radius,tick)
	var query: Dictionary = _navigation._world.navigation_query_status()
	if not query.get("ok",false): return _query_result(query)
	if result.get("error_code","") == "blocked" and _world.walkable(position,radius) and _world.walkable(target,radius):
		if not actor_id.is_empty():
			if _blocked_routes.size() >= 512: _blocked_routes.erase(_blocked_routes.keys()[0])
			_blocked_routes[actor_id] = {"tick":tick,"position":position,"target":target,"radius":radius,"revision":revision}
		return {"ok":true,"direction":Vector2.ZERO,"blocked":true,"deferred":false,"wait_ticks":0}
	return _query_result(result)
func props_query(rectangle: Rect2) -> Dictionary:
	if not _rect_finite(rectangle): return _query_result(failure("invalid_query"))
	if _world == null or not _world.covered(rectangle): return _query_result(failure("world_not_ready"))
	return {"ok":true,"props":_world.query_props(rectangle)}
# Mobility reads use the same prepared geometry and collision primitives. They
# return proposals only; Core owns accepted movement and all damage.
func mobility_geometry(state: Dictionary, rectangle: Rect2) -> Dictionary:
	if _stage != "city" or not matches(state): return _query_result(failure("world_not_ready"))
	var queried := props_query(rectangle)
	if not queried.ok: return queried
	var anchors := []
	for prop in queried.props:
		var anchor := _mobility_anchor_record(state,prop)
		if not anchor.is_empty(): anchors.append(anchor)
	return {"ok":true,"anchors":anchors}
func _mobility_anchor_record(state: Dictionary, prop: Dictionary) -> Dictionary:
	if prop.get("destroyed",true) or prop.get("hp",0) <= 0 or prop.get("hp") != prop.get("max_hp") or not prop.get("mobility_anchor") is Dictionary: return {}
	var data: Dictionary = prop.mobility_anchor
	if not data.get("kind") in ["roof","tree"] or (int(prop.get("collision_mask",0)) & Props.PLAYER) == 0: return {}
	var position: Vector2 = prop.position
	var placed := Address.normalize(state.world.origin_chunk,position)
	var connected := Address.normalize(state.world.origin_chunk,position+vec(data.connection))
	if not placed.ok or not connected.ok: return {}
	var ground: Rect2 = prop.ground_footprint
	var relative := ground.position-position
	var fingerprint: String = state.world.content_fingerprint
	# Stable physical data only. Cache/global/origin counters must not make an
	# unchanged roof stale after cold hydration, a save receipt or another hit.
	var identity := [prop.prop_id,prop.slot_id,prop.definition_id,fingerprint,placed.chunk,[placed.local.x,placed.local.y],[relative.x,relative.y,ground.size.x,ground.size.y],int(prop.collision_mask),int(prop.hp),int(prop.max_hp),data.kind,[float(data.connection[0]),float(data.connection[1])],float(data.roof_height),[float(data.pass_range[0]),float(data.pass_range[1]),float(data.pass_range[2]),float(data.pass_range[3])]]
	return {"prop_id":prop.prop_id,"slot_id":prop.slot_id,"definition_id":prop.definition_id,"kind":data.kind,"chunk":connected.chunk.duplicate(),"local":[connected.local.x,connected.local.y],"connection":[float(data.connection[0]),float(data.connection[1])],"roof_height":float(data.roof_height),"pass_range":[float(data.pass_range[0]),float(data.pass_range[1]),float(data.pass_range[2]),float(data.pass_range[3])],"content_fingerprint":fingerprint,"geometry_revision":JSON.stringify(identity).sha256_text()}
func mobility_pair_check(state: Dictionary, anchors: Array, admit_stale := false) -> Dictionary:
	if _stage != "city" or not matches(state): return _query_result(failure("world_not_ready"))
	if anchors.size() != 2: return failure("stale_mobility_anchor")
	for anchor in anchors:
		if not anchor is Dictionary or not anchor.get("prop_id") is String: return failure("stale_mobility_anchor")
		# Exact resident spatial identity lookup, never a world scan.
		var prop: Dictionary = _world._props.get(anchor.prop_id,{})
		if prop.is_empty(): return failure("stale_mobility_anchor")
		var actual := _mobility_anchor_record(state,prop)
		if admit_stale and actual.is_empty():
			# Save admission proves the original authored pair even after a real
			# damage/destruction delta. Runtime still detaches on the next tick.
			var original := Props.new(_definitions.props).place(prop.prop_id,prop.definition_id,prop.position,{})
			if original.is_empty() or prop.max_hp != original.max_hp or not _same_json(prop.get("mobility_anchor"),original.get("mobility_anchor")): return failure("stale_mobility_anchor")
			if not prop.destroyed and (prop.ground_footprint != original.ground_footprint or prop.collision_mask != original.collision_mask): return failure("stale_mobility_anchor")
			actual = _mobility_anchor_record(state,original)
		if actual.is_empty() or not _same_json(actual,anchor): return failure("stale_mobility_anchor")
	return {"ok":true}
# Legacy v1 admission only; v2 runtime never calls roof mask exemptions.
func mobility_sweep(state: Dictionary, position: Vector2, delta: Vector2, radius: float, anchor: Dictionary, height: float) -> Dictionary:
	return _mobility_sweep_checked(state,position,delta,radius,anchor,height,false)
func mobility_cancel_sweep(state: Dictionary, position: Vector2, delta: Vector2, radius: float, anchor: Dictionary, height: float) -> Dictionary:
	# Read-only emergency traversal. Never offers a new damaged-roof anchor.
	return _mobility_sweep_checked(state,position,delta,radius,anchor,height,true)
func _mobility_sweep_checked(state: Dictionary, position: Vector2, delta: Vector2, radius: float, anchor: Dictionary, height: float, cancellation: bool) -> Dictionary:
	if _stage != "city" or not matches(state): return _query_result(failure("world_not_ready"))
	if not is_finite(height) or height < 0: return failure("invalid_mobility_height")
	var guarded := _query_guard(position,delta,radius)
	if not guarded.ok: return guarded
	if not anchor.get("prop_id") is String or not anchor.get("chunk") is Array or not point_valid(anchor.get("local")): return failure("invalid_mobility_anchor")
	var connected := Address.relative(anchor.chunk,vec(anchor.local),state.world.origin_chunk)
	if not connected.ok: return connected
	var queried := props_query(Rect2(connected.local-Vector2.ONE,Vector2.ONE*2))
	if not queried.ok: return queried
	var actual := {}
	var target := {}
	var candidates: Array = queried.props
	if cancellation:
		# Ruins may have zero footprint and disappear from spatial queries.
		# The exact resident identity map still contains the destroyed prop.
		var known: Dictionary = _world._props.get(anchor.prop_id,{})
		candidates = [] if known.is_empty() else [known]
	for prop in candidates:
		if prop.prop_id == anchor.prop_id:
			target = prop
			if cancellation:
				# Reconstruct only this known prop's original authored physical
				# identity. Actual world data/masks/hp are never changed.
				target = Props.new(_definitions.props).place(prop.prop_id,prop.definition_id,prop.position,{})
				if target.is_empty() or prop.max_hp != target.max_hp or not _same_json(prop.get("mobility_anchor"),target.get("mobility_anchor")): return failure("stale_mobility_anchor")
				if not prop.destroyed and (prop.ground_footprint != target.ground_footprint or prop.collision_mask != target.collision_mask): return failure("stale_mobility_anchor")
			actual = _mobility_anchor_record(state,target)
			break
	if actual.is_empty(): return failure("stale_mobility_anchor")
	for field in actual:
		if not anchor.has(field) or not _same_json(anchor[field],actual[field]): return failure("stale_mobility_anchor")
	# Candidate metadata alone cannot turn a collision mask off.
	if not Codec.exact_keys(anchor,actual.keys()+["pass_start","pass_end"]): return failure("invalid_roof_passage")
	var beginning := _mobility_point(anchor.pass_start,state.world.origin_chunk,actual.geometry_revision)
	var ending := _mobility_point(anchor.pass_end,state.world.origin_chunk,actual.geometry_revision)
	if not beginning.ok or not ending.ok: return failure("invalid_roof_passage")
	var from: Vector2 = beginning.position
	var to: Vector2 = ending.position
	var segment := to-from
	var length := segment.length()
	if length < 1 or length > 320 or float(anchor.pass_start.height) != float(actual.roof_height) or float(anchor.pass_end.height) != float(actual.roof_height): return failure("invalid_roof_passage")
	var passage := Props.rect(actual.pass_range)
	passage.position += connected.local-vec(actual.connection)
	var permitted := passage.grow(radius)
	var physical: Rect2 = target.ground_footprint.grow(radius)
	if physical.has_point(from) or physical.has_point(to): return failure("invalid_roof_passage")
	var entering: float = _world.slab_fraction(from,segment,physical)
	var leaving: float = _world.slab_fraction(to,-segment,physical)
	if entering >= 1.0 or leaving >= 1.0: return failure("invalid_roof_passage")
	# The entire physical intersection must lie inside the declared pass range,
	# rather than merely touching one permitted corner of a broader building.
	if absf(_world.slab_fraction(from,segment,permitted)-entering)*length > 0.0002 or absf(_world.slab_fraction(to,-segment,permitted)-leaving)*length > 0.0002: return failure("invalid_roof_passage")
	if height < float(actual.roof_height): return sweep(position,delta,radius)
	for point in [position,position+delta]:
		var fraction: float = (point-from).dot(segment)/segment.length_squared()
		if fraction < 0 or fraction > 1 or point.distance_to(from+segment*fraction) > 0.0002: return failure("invalid_roof_passage")
	queried = props_query(segment_rect(position,position+delta,radius))
	if not queried.ok: return queried
	var fraction := 1.0
	var hit_id := ""
	for prop in queried.props:
		if prop.prop_id == actual.prop_id or (int(prop.collision_mask) & Props.PLAYER) == 0: continue
		var hit: float = _world.slab_fraction(position,delta,prop.ground_footprint.grow(radius))
		if hit < fraction or (hit == fraction and hit < 1 and (hit_id.is_empty() or prop.prop_id < hit_id)):
			fraction = hit
			hit_id = prop.prop_id
	var accepted := position+delta*maxf(0,fraction-(0.0002/maxf(delta.length(),1.0) if fraction < 1 else 0.0))
	return {"ok":true,"error_code":"","position":accepted,"hit_prop_id":hit_id,"fraction":fraction}
func mobility_player_clearance(state: Dictionary, validate_contract := true) -> Dictionary:
	if validate_contract and not Mobility.validate(state).is_empty(): return failure("invalid_player_mobility")
	if not state.has("player_mobility") or state.player_mobility.phase == "ground": return walkable(vec(state.player.position),float(state.player.radius))
	var m: Dictionary = state.player_mobility
	var route := Mobility.route_sample(m,state.world.origin_chunk)
	if not route.get("ok",false): return route
	if m.schema_version == 2:
		var pair := mobility_pair_check(state,m.anchors,true)
		if not pair.get("ok",false): return pair
		var path := sweep(route.points[0],route.points[1]-route.points[0],8.0)
		if not path.get("ok",false): return path
		if path.fraction < 1.0: return failure("blocked_mobility_path")
		return walkable(vec(state.player.position),8.0)
	# Proof of the entire stored path, including descent and ground landing.
	var rise := sweep(route.points[0],route.points[1]-route.points[0],8.0)
	if not rise.get("ok",false): return rise
	var over := mobility_cancel_sweep(state,route.points[1],route.points[2]-route.points[1],8.0,m.anchor,float(m.anchor.roof_height))
	if not over.get("ok",false): return over
	var land := sweep(route.points[2],route.points[3]-route.points[2],8.0)
	if not land.get("ok",false): return land
	var final_point := walkable(route.points[3],8.0)
	if not final_point.get("ok",false): return final_point
	if rise.fraction < 1.0 or over.fraction < 1.0 or land.fraction < 1.0 or not final_point.walkable: return failure("blocked_mobility_path")
	var height := float(LegacyMobility.visual_sample(state).height)
	if float(m.progress) >= route.distances[1] and float(m.progress) <= route.distances[2] and height >= float(m.anchor.roof_height):
		var actual := mobility_cancel_sweep(state,vec(state.player.position),Vector2.ZERO,8.0,m.anchor,height)
		if not actual.get("ok",false): return actual
		return {"ok":true,"walkable":actual.fraction == 1.0}
	return walkable(vec(state.player.position),8.0)
static func _mobility_point(value: Variant, origin: Array, revision: String) -> Dictionary:
	if not value is Dictionary or not Codec.exact_keys(value,["chunk","local","height","geometry_revision"]) or not value.chunk is Array or not point_valid(value.local) or not number(value.height) or value.geometry_revision != revision: return failure("invalid_roof_passage")
	var checked := Address.normalize(value.chunk,vec(value.local))
	if not checked.ok or checked.chunk != value.chunk or checked.local != vec(value.local): return failure("invalid_roof_passage")
	var relative := Address.relative(value.chunk,vec(value.local),origin)
	return {"ok":true,"position":relative.local} if relative.ok else relative
func _query_guard(position: Vector2, delta: Vector2, radius: float) -> Dictionary:
	if not is_finite(radius) or radius < 0 or radius > 32: return _query_result(failure("unsupported_radius"))
	if not _vector_valid(position) or not _vector_valid(delta) or delta.length() > MAX_LOCAL: return _query_result(failure("invalid_query"))
	if _world == null or not _world.covered(segment_rect(position,position+delta,radius)): return _query_result(failure("world_not_ready"))
	return {"ok":true}
func _query_result(result: Dictionary) -> Dictionary:
	if not result.get("ok",false) and _query_failure.is_empty(): _query_failure = result.duplicate(true)
	return result
static func inactive_city_exit(value: Variant) -> bool:
	# An inactive future-scene exit has no city coordinate space.
	if not value is Array or value.size() != 4: return false
	for scalar in value:
		if not number(scalar) or float(scalar) != 0.0: return false
	return true
static func rebase_proposal(state: Dictionary, commands: Array = []) -> Dictionary:
	var checked := validate_world(state)
	if not checked.ok: return checked
	checked = _validate_commands(state,commands)
	if not checked.ok: return checked
	if not state.get("player") is Dictionary or not point_valid(state.player.get("position")): return failure("invalid_snapshot")
	if state.world.stage == "city":
		if state.has("escape_zone") and not inactive_city_exit(state.escape_zone): return failure("invalid_snapshot")
		for command in commands:
			if spatial_command(command) and command.payload.has("escape_zone") and not inactive_city_exit(command.payload.escape_zone): return failure("invalid_query")
	var candidate := state.duplicate(true)
	var next_commands := commands.duplicate(true)
	if state.world.stage == "dock": return {"ok":true,"changed":false,"state":candidate,"commands":next_commands,"offset":[0,0]}
	var normalized := Address.normalize(state.world.origin_chunk,vec(state.player.position))
	if not normalized.ok: return normalized
	var offset: Vector2 = normalized.offset
	if offset == Vector2.ZERO: return {"ok":true,"changed":false,"state":candidate,"commands":next_commands,"offset":[0,0]}
	if state.world.origin_revision >= Codec.MAX_JSON_INTEGER: return failure("counter_exhausted")
	if not _shift_record(candidate.player,["position"],offset): return failure("invalid_snapshot")
	for collection in LIMITS:
		if not candidate.get(collection) is Array: return failure("invalid_snapshot")
		for record in candidate[collection]:
			if not record is Dictionary or not _shift_record(record,POSITION_FIELDS,offset): return failure("invalid_snapshot")
			if record.has("geometry") and (not record.geometry is Dictionary or not _shift_record(record.geometry,GEOMETRY_POSITIONS,offset)): return failure("invalid_snapshot")
	# CITY_INACTIVE_EXIT is deliberately unchanged; dock never rebases.
	# Evacuation stores an absolute passage chunk only; rectangles/routes are
	# derived per query and therefore cannot be shifted a second time.
	candidate.world.origin_chunk = normalized.chunk.duplicate()
	candidate.world.origin_revision = int(candidate.world.origin_revision)+1
	for command in next_commands:
		if not spatial_command(command): continue
		if not _shift_record(command.payload,POSITION_FIELDS,offset): return failure("invalid_snapshot")
		if command.payload.has("geometry") and (not command.payload.geometry is Dictionary or not _shift_record(command.payload.geometry,GEOMETRY_POSITIONS,offset)): return failure("invalid_snapshot")
		command.origin_revision = candidate.world.origin_revision
	return {"ok":true,"changed":true,"state":candidate,"commands":next_commands,"offset":[offset.x,offset.y]}
func structure_candidate_proposal(state: Dictionary, actor: Dictionary, prop_id: String, rules: Dictionary, reservations: Dictionary) -> Dictionary:
	var checked := validate_world(state)
	if not checked.ok: return checked
	if state.world.stage != "city" or not matches(state) or _world == null: return failure("world_not_ready")
	if not _tick(state.get("active_tick")) or not point_valid(actor.get("position")): return failure("invalid_query")
	for field in ["remaining_strong_slots","in_flight","next_admit_tick"]:
		if not _tick(reservations.get(field)): return failure("invalid_query")
	var prop := _find_prop(prop_id)
	if prop.is_empty(): return failure("world_not_ready")
	if not actor.get("source_team") is String or not actor.get("structure_capable",false) is bool or not actor.get("cancelled",false) is bool: return failure("source_policy")
	# Bound integer conversions before exact admission adds clocks.
	for field in ["structure_admission_interval_ticks","max_structure_attacks","warning_ticks","recovery_ticks","structure_damage","structure_reach"]:
		if not Codec.integer(rules.get(field)) or rules[field] <= 0 or rules[field] > Codec.MAX_JSON_INTEGER: return failure("invalid_structure_rules")
	for field in ["structure_admission_interval_ticks","warning_ticks","recovery_ticks"]:
		if not _tick(rules[field]): return failure("counter_exhausted")
	var budget := reservations.duplicate(true)
	budget.next_admit_tick = maxi(int(budget.next_admit_tick),int(state.world.next_structure_strike_tick))
	var admitted := Interactions.structure_candidate(actor,prop,rules,int(state.active_tick),budget)
	if not admitted.ok: return admitted
	if not _tick(admitted.next_admit_tick) or not _tick(admitted.recovery_until): return failure("counter_exhausted")
	var world: Dictionary = state.world.duplicate(true)
	world.next_structure_strike_tick = admitted.next_admit_tick
	return {"ok":true,"world":world,"admission":admitted.duplicate(true)}
func destruction_proposal(state: Dictionary, attack: Dictionary, contact: Dictionary) -> Dictionary:
	var checked := validate_world(state)
	if not checked.ok: return checked
	if state.world.stage != "city" or not matches(state) or _world == null: return failure("world_not_ready")
	if not attack.get("kind") is String or not attack.get("source_team") is String or not attack.get("cancelled",false) is bool: return failure("source_policy")
	if not attack.get("target_prop_id") is String or not attack.get("attack_instance_id") is String or attack.attack_instance_id.is_empty() or not attack.get("hit_target_ids") is Array: return failure("invalid_attack")
	for id in attack.hit_target_ids:
		if not id is String or id.is_empty(): return failure("invalid_attack")
	if not _tick(attack.get("active_from_tick")) or not _tick(attack.get("expires_tick")) or attack.expires_tick < attack.active_from_tick: return failure("invalid_attack")
	if not contact.get("prop_id") is String or not contact.get("reached") is bool: return failure("invalid_contact")
	if not _tick(contact.get("tick")) or not number(contact.get("fraction")) or contact.fraction > 1 or not Codec.integer(attack.get("structure_damage")) or attack.structure_damage <= 0 or attack.structure_damage > Codec.MAX_JSON_INTEGER: return failure("invalid_contact")
	var prop := _find_prop(attack.target_prop_id)
	if prop.is_empty(): return failure("world_not_ready")
	var resolved := Interactions.resolve_structure_hit(attack,prop,contact)
	if not resolved.ok: return resolved
	if state.world.world_revision >= Codec.MAX_JSON_INTEGER: return failure("counter_exhausted")
	var chunk: Dictionary = _world.localized_chunk(prop.chunk_id)
	var deltas := []
	# Persist every modification in this chunk, including previously hydrated
	# damage, because immutable store records replace rather than patch a chunk.
	for item in chunk.props:
		if item.prop_id == prop.prop_id: deltas.append(resolved.delta.duplicate(true))
		elif item.destructible and (item.destroyed or item.hp != item.max_hp): deltas.append({"slot_id":item.slot_id,"hp":item.hp,"destroyed":item.destroyed})
	var changes: Array = state.world.dirty_chunks.duplicate(true)
	var found := false
	for record in changes:
		if record.chunk == chunk.chunk: record.props = deltas; found = true; break
	if not found: changes.append({"chunk":chunk.chunk.duplicate(),"props":deltas})
	var normalized := Codec.normalize_records(changes)
	if not normalized.ok: return normalized
	var world: Dictionary = state.world.duplicate(true)
	world.world_revision = int(world.world_revision)+1; world.dirty_chunks = normalized.records
	return {"ok":true,"world":world,"hit_target_id":resolved.hit_target_id,"event":resolved.event.duplicate(true)}
func passage_proposal(state: Dictionary) -> Dictionary:
	var checked := validate_world(state)
	if not checked.ok: return checked
	if state.world.stage != "city" or not matches(state) or _world == null: return failure("world_not_ready")
	checked = _evacuation_input(state)
	if not checked.ok: return checked
	if state.get("phase") != "evacuation" or not _tick(state.get("final_started_tick")) or state.final_started_tick > state.active_tick: return failure("invalid_transition_phase")
	var route = Evacuation.new(state.world.evacuation)
	var passage: Dictionary = route.select(_world,state.player,state.world.origin_chunk,int(state.active_tick))
	if not passage.ok: return passage
	var world: Dictionary = state.world.duplicate(true)
	world.evacuation = {"passage_id":passage.passage_id,"chunk":passage.chunk.duplicate(),"selected_tick":passage.selected_tick}
	return {"ok":true,"world":world,"passage":passage}
func dock_transition_proposal(state: Dictionary, command: Dictionary, dock_definition: Dictionary) -> Dictionary:
	if not _dock_valid(dock_definition): return failure("invalid_dock_definition")
	var checked := validate_world(state)
	if not checked.ok: return checked
	checked = _evacuation_input(state)
	if not checked.ok: return checked
	if not command.get("command_id") is String or command.command_id.is_empty() or not command.get("kind") is String or command.kind != "dock_transition" or not command.get("payload") is Dictionary: return failure("invalid_query")
	# Exact same completed command remains a no-op even after origin changes.
	if state.world.stage == "dock": return Evacuation.dock_transition(state,{"command_id":command.command_id},dock_definition)
	checked = _validate_commands(state,[command])
	if not checked.ok: return checked
	if state.has("player_mobility") and state.player_mobility.get("phase") != "ground": return failure("mobility_airborne")
	var evacuation: Dictionary = state.world.evacuation
	if evacuation.is_empty() or not command.payload.get("passage_id") is String or command.payload.passage_id != evacuation.passage_id: return failure("wrong_passage")
	var local := Address.relative(evacuation.chunk,Vector2(336,336),state.world.origin_chunk)
	if not local.ok: return local
	if state.world.origin_revision >= Codec.MAX_JSON_INTEGER: return failure("counter_exhausted")
	for collection in ["entities","projectiles","telegraphs","drops","pending_attacks","pending_evolutions","player_attack_instances","enemy_attack_instances"]:
		if not state.get(collection,[]) is Array or state.get(collection,[]).size() > LIMITS.get(collection,512): return failure("invalid_snapshot")
		for item in state.get(collection,[]):
			if not item is Dictionary: return failure("invalid_snapshot")
	return Evacuation.dock_transition(state,{"passage_id":evacuation.passage_id,"command_id":command.command_id,"rect":Rect2(local.local,Vector2(96,96))},dock_definition)
static func escape_status(state: Dictionary, dock_definition: Dictionary) -> Dictionary:
	if not _dock_valid(dock_definition): return failure("invalid_dock_definition")
	var checked := validate_world(state)
	if not checked.ok: return checked
	checked = _evacuation_input(state)
	if not checked.ok: return checked
	return Evacuation.escape_status(state,dock_definition)
static func receipt_proposal(world: Dictionary, receipt: Dictionary) -> Dictionary:
	# Exact adapter remains sole receipt authority; no live cache acknowledge.
	return Checkpoint.accept_receipt(world,receipt)
func _find_prop(id: String) -> Dictionary:
	for chunk in _world.render_view().chunks:
		for prop in chunk.props:
			if prop.prop_id == id: return prop
	return {}
static func _record_bounds(record: Dictionary, rectangles: Array[Rect2], inactive_move_anchors: bool = false) -> Dictionary:
	var radius := 32.0
	for field in ["radius","length","range","width","splash_radius"]:
		if record.has(field):
			if not number(record[field]) or record[field] > MAX_LOCAL: return failure("invalid_snapshot")
			radius = maxf(radius,float(record[field]))
	for field in POSITION_FIELDS:
		if record.has(field):
			if not point_valid(record[field]): return failure("invalid_snapshot")
			# NEW: move-state FSM never consumes previous attack anchors. Their
			# saved numbers remain validated; active attack anchors stay covered.
			if inactive_move_anchors and field in ["locked_origin","locked_target"]: continue
			rectangles.append(segment_rect(vec(record[field]),vec(record[field]),radius))
	if record.has("geometry"):
		if not record.geometry is Dictionary: return failure("invalid_snapshot")
		var geometry: Dictionary = record.geometry
		var geometry_radius := radius
		for field in ["radius","length","range","width"]:
			if geometry.has(field):
				if not number(geometry[field]) or geometry[field] > MAX_LOCAL: return failure("invalid_snapshot")
				geometry_radius = maxf(geometry_radius,float(geometry[field]))
		for field in GEOMETRY_POSITIONS:
			if geometry.has(field):
				if not point_valid(geometry[field]): return failure("invalid_snapshot")
				rectangles.append(segment_rect(vec(geometry[field]),vec(geometry[field]),geometry_radius))
	return {"ok":true}
static func _add_rect(unique: Dictionary, rectangle: Rect2, origin: Array, target_origin: Array, admitted_cells: Dictionary) -> Dictionary:
	if not _rect_finite(rectangle): return failure("invalid_query")
	var low := rectangle.position/768.0
	var high := (rectangle.end-Vector2(0.0001 if rectangle.size.x > 0 else 0,0.0001 if rectangle.size.y > 0 else 0))/768.0
	if high.x-low.x > 7 or high.y-low.y > 7: return failure("outside_working_set")
	for y in range(int(floor(low.y)),int(floor(high.y))+1):
		for x in range(int(floor(low.x)),int(floor(high.x))+1):
			var cell := Vector2i(x,y)
			if admitted_cells.has(cell): continue
			var absolute := Address.normalize(origin,Vector2(x*768,y*768))
			if not absolute.ok: return absolute
			var relative := Address.relative(absolute.chunk,Vector2.ZERO,target_origin)
			if not relative.ok or relative.local.abs().x > 2304 or relative.local.abs().y > 2304: return failure("outside_working_set")
			unique[Address.key(absolute.chunk)] = absolute.chunk
			if unique.size() > 49: return failure("working_set_capacity")
			admitted_cells[cell] = true
	return {"ok":true}
static func _validate_commands(state: Dictionary, commands: Array) -> Dictionary:
	if commands.size() > 512: return failure("working_set_capacity")
	for command in commands:
		if not command is Dictionary or not command.get("kind") is String: return failure("invalid_query")
		if not spatial_command(command): continue
		if not command.get("payload") is Dictionary: return failure("invalid_query")
		if not Codec.integer(command.get("origin_revision")) or command.origin_revision != state.world.origin_revision: return failure("stale_origin_revision")
	return {"ok":true}
static func spatial_command(command: Dictionary) -> bool:
	return command.get("kind") is String and command.kind in ["spawn_enemy","spawn_boss","telegraph_attack","begin_evacuation","dock_transition"]
static func stamp(state: Dictionary) -> String:
	return str(state.get("run_id",""))+":"+str(state.get("seed",-1))+":"+JSON.stringify(state.get("world",{}),"",true,true)
static func _shift_record(record: Dictionary, fields: Array, offset: Vector2) -> bool:
	for field in fields:
		if record.has(field):
			if not point_valid(record[field]): return false
			var shifted := _shift(record[field],offset)
			if not point_valid(shifted): return false
			record[field] = shifted
	return true
static func _shift(value: Array, offset: Vector2) -> Array:
	var result := value.duplicate()
	result[0] = float(value[0])-offset.x; result[1] = float(value[1])-offset.y
	return result
static func _definitions_shape(definitions: Dictionary) -> bool:
	for field in ["templates","props","asset_manifest"]:
		if not definitions.get(field) is Dictionary: return false
	if not definitions.templates.get("templates") is Array or not definitions.props.get("definitions") is Dictionary or not definitions.props.get("mask_bits") is Dictionary or not definitions.asset_manifest.get("assets") is Dictionary: return false
	for field in ["generator_revision","template_revision"]:
		if not definitions.templates.get(field) is String: return false
	for field in ["chunk_size","navigation_cell"]:
		if not number(definitions.templates.get(field)): return false
	if not point_valid(definitions.templates.get("street_interval")) or not rect_valid(definitions.templates.get("passage_rect")): return false
	for field in ["player","grounded_titan","physical_attack","straight_projectile","overhead"]:
		if not number(definitions.props.mask_bits.get(field)): return false
	for template in definitions.templates.templates:
		if not template is Dictionary or not template.get("template_id") is String or not template.get("slots") is Array: return false
		for slot in template.slots:
			if not slot is Dictionary or not slot.get("slot_id") is String or not slot.get("definition_id") is String or not point_valid(slot.get("position")) or not number(slot.get("rotation_degrees",0)): return false
	for id in definitions.props.definitions:
		if not id is String: return false
		var definition = definitions.props.definitions[id]
		if not definition is Dictionary: return false
		for field in ["asset_id","ruin_asset_id"]:
			if not definition.get(field) is String: return false
		for field in ["ground_footprint","render_bounds","ruin_footprint","ruin_render_bounds"]:
			if not rect_valid(definition.get(field)): return false
		if not point_valid(definition.get("anchor_px")) or not number(definition.get("depth_origin"),-MAX_LOCAL) or not definition.get("destructible") is bool: return false
		if not Codec.integer(definition.get("structure_hp")) or definition.structure_hp > Codec.MAX_JSON_INTEGER: return false
		if not number(definition.get("rotation_degrees",0)) or not number(definition.get("contact_damage",0)): return false
		var art = definitions.asset_manifest.assets.get(definition.asset_id)
		if art is Dictionary:
			if not point_valid(art.get("anchor_px")) or not number(art.get("cell_w")) or not number(art.get("cell_h")): return false
		for field in ["collision_mask","cover_mask"]:
			if not Codec.integer(definition.get(field)) or definition[field] > 31: return false
	for asset in definitions.asset_manifest.assets.values():
		if not asset is Dictionary: return false
		if asset.has("anchor_px") and not point_valid(asset.anchor_px): return false
	return true
static func _same_json(left: Variant, right: Variant) -> bool:
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size(): return false
		for key in left:
			if not right.has(key) or not _same_json(left[key],right[key]): return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size(): return false
		for index in left.size():
			if not _same_json(left[index],right[index]): return false
		return true
	if (left is int or left is float) and (right is int or right is float): return left == right
	return typeof(left) == typeof(right) and left == right
static func _evacuation_input(state: Dictionary) -> Dictionary:
	# World validation intentionally is not full RunState validation. These are
	# only the values the exact pure evacuation module reads unsafely.
	if not state.get("phase") is String or not _tick(state.get("active_tick")): return failure("invalid_snapshot")
	var final_tick = state.get("final_started_tick")
	if not _tick(final_tick) and not (number(final_tick,-1) and final_tick == -1): return failure("invalid_snapshot")
	if not state.get("player") is Dictionary: return failure("invalid_snapshot")
	var player: Dictionary = state.player
	if not point_valid(player.get("position")) or not number(player.get("radius")) or player.radius > 32 or not number(player.get("hp"),-INF): return failure("invalid_snapshot")
	return {"ok":true}
static func _dock_escape_rect(value: Variant) -> bool:
	return rect_valid(value) and float(value[0]) == -56.0 and float(value[1]) == 320.0 and float(value[2]) == 112.0 and float(value[3]) == 80.0
static func _dock_valid(definition: Dictionary) -> bool:
	return definition.get("scene_id") is String and definition.scene_id == "authored_dock" and point_valid(definition.get("entry_position")) and vec(definition.entry_position) == Vector2.ZERO and _dock_escape_rect(definition.get("escape_rect")) and definition.get("geometry") is Dictionary and not definition.geometry.is_empty() and FiniteGeometry.valid(definition.geometry)
static func point_valid(value: Variant) -> bool:
	return value is Array and value.size() == 2 and number(value[0],-MAX_LOCAL) and number(value[1],-MAX_LOCAL) and absf(float(value[0])) <= MAX_LOCAL and absf(float(value[1])) <= MAX_LOCAL
static func rect_valid(value: Variant) -> bool:
	return value is Array and value.size() == 4 and point_valid([value[0],value[1]]) and number(value[2]) and number(value[3]) and value[2] <= MAX_LOCAL and value[3] <= MAX_LOCAL
static func number(value: Variant, minimum: float = 0.0) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum
static func _tick(value: Variant) -> bool: return Codec.integer(value) and value <= 2147483647
static func _vector_valid(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y) and value.abs().x <= MAX_LOCAL and value.abs().y <= MAX_LOCAL
static func _rect_finite(value: Rect2) -> bool:
	return _vector_valid(value.position) and _vector_valid(value.end) and value.size.x >= 0 and value.size.y >= 0
static func vec(value: Array) -> Vector2: return Vector2(float(value[0]),float(value[1]))
static func segment_rect(a: Vector2, b: Vector2, radius: float) -> Rect2:
	return Rect2(a.min(b)-Vector2.ONE*radius,(b-a).abs()+Vector2.ONE*radius*2)
static func failure(code: String) -> Dictionary: return {"ok":false,"error_code":code}
