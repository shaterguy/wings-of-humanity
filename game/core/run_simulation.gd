class_name RunSimulation
extends RefCounted
const Loot = preload("res://game/loot/loot_rules.gd")
const Characters = preload("res://game/progression/character_catalog.gd")
const Contracts = preload("res://game/contracts/game_contracts.gd")
const SpatialHash = preload("res://game/combat/spatial_hash.gd")
const World = preload("res://game/combat/world_geometry.gd")
const Geometry = preload("res://game/combat/attack_geometry.gd")
const RoleCatalog = preload("res://game/combat/enemy_role_catalog.gd")
const RoleModel = preload("res://game/combat/enemy_attack_model.gd")
const RoleBudget = preload("res://game/combat/enemy_threat_budget.gd")
const RoleQuery = preload("res://game/combat/enemy_world_query.gd")
# Out-of-band implementation evidence, never serialized into gameplay state.
var _native_pursuit_counts := {"admissions":0,"batches":0,"scopes":0,"scope_refusals":0,"fallback_batches":0,"walkable_calls":0,"sweep_calls":0,"move_calls":0,"direction_calls":0,"query_count":0}
func native_pursuit_diagnostics() -> Dictionary:
	var result := _native_pursuit_counts.duplicate(true)
	result.enabled = bool(ProjectSettings.get_setting("wings/native_pursuit",false))
	result.backend = "resident-r5"
	result.native_source_freeze = "774e3c75cfd772a90834573f2ecee9f2a0f4475bf4e8b7472b8d41f443e529d8"
	result.reader_present = _streamed != null and _streamed.get_script() == Streamed and _streamed._native_pursuit != null
	return result
const LIVE_ROLE_IDS := ["grabber","quadruped","stone_thrower"]
const ROLE_RETRY_TICKS := 15
const Behaviors = preload("res://game/combat/enemy_behaviors.gd")
const Catalog = preload("res://game/progression/upgrade_catalog.gd")
const Chapters = preload("res://game/director/chapter_catalog.gd")
const Supplies = preload("res://game/economy/supply_catalog.gd")
const Growth = preload("res://game/progression/growth_offer_service.gd")
const Signature = preload("res://game/combat/character_skill_resolver.gd")
const Fantasy = preload("res://game/combat/fantasy_attack_resolver.gd")
const Evolved = preload("res://game/combat/evolved_attack_resolver.gd")
const Streamed = preload("res://game/core/streamed_run_world.gd")
const Mobility = preload("res://game/core/player_mobility.gd")
const Population = preload("res://game/core/city_population.gd")
const WorldCodec = preload("res://game/world/world_delta_codec.gd")
const ArmoredContact = preload("res://game/combat/armored_contact.gd")
const CONTENT_REVISION := "ch01.3-rebuild.7-grabber-hand"
const FINAL_ENEMY_ID := "armored_titan"
const FINAL_BOSS_ID := "ch01_final_armored"
const FINAL_ACTOR_SPAWN_ID := "final:armored_actor"
const MAX_COUNTER := 2147483647
const REAL_BOSS_IDS := ["ch01_b05","ch01_b10","ch01_b15","ch01_b20","ch01_b25"]
const TICKS_PER_SECOND := 60.0
const FINAL_TICK := 108000
const PAUSE_REASONS := ["user","upgrade","rotation","background","controller_lost","slow_frame"]
const MAX_ENTITIES := 512
const MAX_PROJECTILES := 256
const MAX_DROPS := 256
const COMMAND_HISTORY_COMPACT_AT := 1024
const GAMEPLAY_PATHS := ["data/equipment.json","data/passives.json","data/evolutions.json","data/doctrines.json","data/supply_shop.json"]
# Static provenance is issued by this exact Core, never by a snapshot flag.
# Data is frozen at constructor validation; admission is published separately.
class LiveConfiguration:
	extends RefCounted
	var _owner: WeakRef
	var _nonce: RefCounted
	var _data: Dictionary
	var _provider_owner: WeakRef
	var _helper_owner: WeakRef
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
		_provider_owner = weakref(issuer._chapter_provider)
		_helper_owner = weakref(issuer._world_template)
	func owns(issuer, key: RefCounted) -> bool:
		return _owner != null and _owner.get_ref() == issuer and _nonce == key and issuer._issued_configuration_proof == self and _provider_owner != null and _provider_owner.get_ref() == issuer._chapter_provider and _helper_owner != null and _helper_owner.get_ref() == issuer._world_template
var _configuration_nonce := RefCounted.new()
var _configuration_proof
var _issued_configuration_proof: LiveConfiguration
var _configuration_admitted := false
var _live_parent: WeakRef
var _catalog: UpgradeCatalog
var _supplies: SupplyCatalog
var _evolved
var _signature
var _chapter_provider
var _chapter: Dictionary = {}
var _definition_hashes: Dictionary = {}
var _gameplay_definitions: Dictionary = {}
var _content_error := ""
var _world_template
var _streamed
var _last_step_status: Dictionary = {"ok":true}
var _tick_navigation: Dictionary = {}
# Per-tick travelled shoulder segments; never saved or replayed after a pause.
var _final_sweeps: Array[Dictionary] = []
var _mobility_sweeps: Array = []
var _mobility_cast: Dictionary = {}
var _role_samples: Dictionary = {}
var _role_error: Dictionary = {}
var _role_admission: Dictionary = {}
var _attack_view_cache: Dictionary = {}
var _role_tick_query
var _role_tick_state: Dictionary = {}
# One-call admission from _step_streamed; never part of a saved state.
var _role_batch_tick := -1
var _role_batch_helper_id := 0
func _init(chapter_provider = null, world_helper = null, immutable_inputs: Dictionary = {}, configuration_source = null) -> void:
	if configuration_source != null:
		_content_error = "content_mismatch"
		_clone_live_configuration(configuration_source)
		return
	_chapter_provider = Chapters.new() if chapter_provider == null else chapter_provider
	var definitions := {}
	for path in GAMEPLAY_PATHS:
		var value: Variant
		if not immutable_inputs.is_empty():
			value = immutable_inputs.get(path,{}).duplicate(true)
		else:
			var file := FileAccess.open("res://"+path,FileAccess.READ)
			if file == null or file.get_length() > Chapters.MAX_DEFINITION_BYTES:
				_content_error = "content_mismatch"
				continue
			value = JSON.parse_string(file.get_as_text())
		var digest := Chapters.new().definition_digest(value)
		if not value is Dictionary or digest.is_empty():
			_content_error = "content_mismatch"
			continue
		definitions[path] = value
		_definition_hashes[path] = digest
	_gameplay_definitions = definitions.duplicate(true)
	_catalog = Catalog.new(definitions.get(GAMEPLAY_PATHS[0],{}),definitions.get(GAMEPLAY_PATHS[1],{}),definitions.get(GAMEPLAY_PATHS[2],{}))
	if immutable_inputs.is_empty():
		_supplies = Supplies.new(definitions.get(GAMEPLAY_PATHS[4],{}),definitions.get(GAMEPLAY_PATHS[3],{}))
	else:
		_supplies = Supplies.new(definitions.get(GAMEPLAY_PATHS[4],{}),definitions.get(GAMEPLAY_PATHS[3],{}),definitions.get(GAMEPLAY_PATHS[0],{}),definitions.get(GAMEPLAY_PATHS[1],{}))
	_evolved = Evolved.new(_catalog)
	_signature = Signature.new(_catalog)
	var loaded := _load_provider_chapter()
	if not loaded.get("ok",false):
		_content_error = "content_mismatch"
		return
	_chapter = loaded.chapter.duplicate(true)
	# Validated live profiles are immutable private inputs. Prepare their clocks
	# once; derived Core callbacks keep the original per-call normalization.
	if get_script() == load("res://game/core/run_simulation.gd"):
		for enemy_id in LIVE_ROLE_IDS:
			if _chapter.enemy_role_catalog.roles.has(enemy_id):
				_normalize_saved_numbers(_chapter.enemy_role_catalog.roles[enemy_id].profile)
	if _chapter.get("world_mode","") == "streamed_city":
		var supplied = Streamed.new(_chapter.world_definitions) if world_helper == null else world_helper
		if not _helper_matches(supplied,_chapter):
			_content_error = "content_mismatch"
			return
		_world_template = supplied.fresh()
		if not _helper_matches(_world_template,_chapter) or _world_template == supplied: _content_error = "content_mismatch"
	_capture_constructor_configuration()
func _capture_constructor_configuration() -> void:
	if _issued_configuration_proof != null: return
	# Catalog validate() returns cached errors, so only call here immediately
	# after the original constructor validated the input rows, never at refresh.
	if get_script() != load("res://game/core/run_simulation.gd") or not _content_error.is_empty() or not _catalog.validate().is_empty() or not _supplies.validate().is_empty(): return
	if not _chapter_provider is Object or _chapter_provider.get_script() != load("res://game/director/streamed_chapter_provider.gd") or _world_template == null or _world_template.get_script() != Streamed: return
	var data := {"domain":ProjectSettings.globalize_path("res://"),"version":_chapter_provider.rules_version(),"definitions":_gameplay_definitions,"hashes":_definition_hashes,"chapter":_chapter,"equipment":_catalog._equipment,"passives":_catalog._passives,"progression":_catalog._progression,"evolutions":_catalog.evolutions._items,"evolution_schema":_catalog.evolutions._schema_version,"supplies":_supplies._items,"doctrines":_supplies._doctrines}
	data = data.duplicate(true)
	_freeze_configuration(data)
	_configuration_proof = LiveConfiguration.new(self,_configuration_nonce,data)
	_issued_configuration_proof = _configuration_proof
static func _freeze_configuration(value: Variant) -> void:
	if value is Dictionary:
		for key in value: _freeze_configuration(value[key])
		value.make_read_only()
	elif value is Array:
		for item in value: _freeze_configuration(item)
		value.make_read_only()
func _has_live_configuration(require_admitted: bool = true) -> bool:
	if get_script() != load("res://game/core/run_simulation.gd") or not _configuration_proof is LiveConfiguration or (require_admitted and not _configuration_admitted): return false
	if not _configuration_proof.owns(self,_configuration_nonce) or not _configuration_proof.data.is_read_only(): return false
	if not _chapter_provider is Object or _chapter_provider.get_script() != load("res://game/director/streamed_chapter_provider.gd"): return false
	return _content_error.is_empty() and _configuration_proof.data.domain == ProjectSettings.globalize_path("res://") and _configuration_proof.data.version == _chapter_provider.rules_version()
func _can_prepare_live_coverage(state: Dictionary) -> bool:
	if not _has_live_configuration() or _streamed == null or _streamed.get_script() != Streamed or _world_template == null or _world_template.get_script() != Streamed: return false
	if _configuration_proof.data.version != "dev5": return false
	if not Streamed.validate_world(state).get("ok",false) or state.world.stage != "city": return false
	if state.has("player_mobility") and (not state.player_mobility is Dictionary or not state.player_mobility.get("schema_version") is int or state.player_mobility.schema_version != 2): return false
	return _streamed._query_failure.is_empty() and _streamed.matches(state) and _streamed._world != null and _streamed._world.get_script() == Streamed.Stream and _streamed._generator.get_script() == Streamed.Generator
func _fork_live_configuration():
	if not _has_live_configuration(): return null
	var result = get_script().new(null,null,{},self)
	return result if result._has_live_configuration(false) else null
func _clone_live_configuration(source) -> void:
	if get_script() != load("res://game/core/run_simulation.gd") or not source is Object or source.get_script() != get_script() or not source._has_live_configuration(): return
	var proof: LiveConfiguration = source._configuration_proof
	var data: Dictionary = proof.data
	# This branch creates fresh services, not a serialized constructor cache.
	_chapter_provider = source._chapter_provider
	_gameplay_definitions = data.definitions.duplicate(true)
	_definition_hashes = data.hashes.duplicate(true)
	_chapter = data.chapter.duplicate(true)
	_catalog = Catalog.new({},{},{})
	_catalog._equipment = data.equipment.duplicate(true)
	_catalog._passives = data.passives.duplicate(true)
	_catalog._progression = data.progression.duplicate(true)
	_catalog._base_errors.clear()
	_catalog.evolutions._items = data.evolutions.duplicate(true)
	_catalog.evolutions._schema_version = int(data.evolution_schema)
	_catalog.evolutions._errors.clear()
	_catalog.evolutions._owner = weakref(_catalog)
	_supplies = Supplies.new({},{},{},{})
	_supplies._items = data.supplies.duplicate(true)
	_supplies._doctrines = data.doctrines.duplicate(true)
	_supplies._errors.clear()
	_evolved = Evolved.new(_catalog); _signature = Signature.new(_catalog)
	_world_template = source._world_template._fork_live_configuration()
	if _world_template == null: return
	_configuration_proof = LiveConfiguration.new(self,_configuration_nonce,data)
	_issued_configuration_proof = _configuration_proof
	_live_parent = weakref(source)
	_content_error = ""
func _prepare_live_world(value: Dictionary, hydration: Dictionary, commands: Array, source_helper) -> Dictionary:
	if not _has_live_configuration(false) or _configuration_admitted or _live_parent == null or _live_parent.get_ref() == null or _streamed != null: return _failure("world_not_ready")
	var preamble := _restore_preamble(value)
	if not preamble.get("ok",false): return preamble
	var prepared := []
	var current := {"ok":true,"chapter":_chapter}
	var checked := _restore_admitted_body(value,hydration,commands,prepared,current,source_helper)
	if not checked.get("ok",false): return checked
	if prepared.is_empty(): return _failure("world_not_ready")
	_streamed = prepared[0]
	_attack_view_cache = checked.attack_view.duplicate(true)
	_configuration_admitted = true
	_live_parent = null
	return {"ok":true,"state":checked.state}
# Internal ordinary-tick trust contract, not an external snapshot validator.
# Fresh owners and copied state retain failure atomicity without a rollback log.
func _prepare_controller_world(source, value: Dictionary, hydration: Dictionary, commands: Array) -> Dictionary:
	if not _has_live_configuration(false) or _configuration_admitted or _streamed != null or _live_parent == null or _live_parent.get_ref() != source or source == self: return _failure("world_not_ready")
	if not source is Object or source.get_script() != get_script() or not source._can_prepare_live_coverage(value): return _failure("world_not_ready")
	var restored: Dictionary = value.duplicate(true)
	# Autosave acknowledgements can carry JSON-derived world numeric forms.
	# Preserve the existing world canonicalization, not the full save graph walk.
	var dormant: Dictionary = restored.world.get("dormant",{})
	restored.world = Chapters.new()._canonical_numbers(restored.world)
	if int(restored.world.schema_version) == 2: restored.world.dormant = dormant
	var helper = _world_template._fork_live_configuration()
	if helper == null or helper == _world_template or helper == source._streamed: return _failure("world_not_ready")
	var ready: Dictionary = helper._prepare_live(restored,hydration,commands,source._streamed)
	if not ready.get("ok",false): return ready
	# Keep cast-time and vector normalization in its original post-prepare order.
	if float(restored.rules.get("permanent_damage_bonus",0.0)) > 0.0:
		if not _evolved.canonicalize_damage(_legacy_attack_state(restored)): return _failure("invalid_core_state")
		for projectile in restored.projectiles:
			var canonical_damage: Array[float] = []
			if not _projectile_valid(restored,projectile,canonical_damage): return _failure("invalid_core_state")
			projectile.damage = canonical_damage[0]
	if not Fantasy.canonicalize(restored,_catalog): return _failure("invalid_core_state")
	_signature.canonicalize(restored)
	_canonicalize_saved_vectors(restored)
	_streamed = helper
	_configuration_admitted = true
	_live_parent = null
	return {"ok":true,"state":restored}
func _load_provider_chapter() -> Dictionary:
	if not _chapter_provider is Object or not _chapter_provider.has_method("load_chapter"): return _failure("content_mismatch")
	var result = _chapter_provider.load_chapter("chapter_01_shiganshina")
	if not result is Dictionary or not result.get("ok") is bool or not result.ok or not result.get("chapter") is Dictionary: return _failure("content_mismatch")
	var definition: Dictionary = result.chapter
	if not Contracts.new()._json_safe(definition) or not definition.get("content_definition_hashes") is Dictionary or not WorldCodec.valid_hash(definition.get("content_fingerprint")): return _failure("content_mismatch")
	for path in GAMEPLAY_PATHS:
		if not _definition_hashes.has(path) or not definition.content_definition_hashes.get(path) is String or definition.content_definition_hashes[path] != _definition_hashes[path]: return _failure("content_mismatch")
	if not definition.get("world_mode","") is String or not definition.get("world_mode","") in ["","finite_test","streamed_city"]: return _failure("content_mismatch")
	if not _provider_shape_valid(definition): return _failure("content_mismatch")
	return {"ok":true,"chapter":definition}
func _provider_shape_valid(definition: Dictionary) -> bool:
	if not definition.get("enemy_catalog") is Dictionary or not definition.get("world_geometry") is Dictionary: return false
	if not definition.get("enemy_role_catalog") is Dictionary or not RoleCatalog.validate(definition.enemy_role_catalog).is_empty(): return false
	if Chapters.new().definition_digest(definition.enemy_role_catalog) != definition.content_definition_hashes.get("data/enemy_roles_ch01_3.json"): return false
	if not _same_json(definition.enemy_catalog.get("grabber"),definition.enemy_role_catalog.roles.grabber.definition): return false
	# Reuse the chapter owner's existing manifest/reference validation rather
	# than inventing a second doctrine/evolution/schedule rule set in Core.
	var references := _gameplay_definitions.duplicate()
	references["data/enemies.json"] = definition.enemy_catalog
	if not Chapters.new()._chapter_valid(definition,references): return false
	for id in definition.doctrine_ids:
		var doctrine: Dictionary = _supplies.doctrine(id)
		if doctrine.is_empty(): return false
		for weapon in doctrine.initial_equipment:
			if not weapon in definition.allowed_equipment_ids: return false
	for id in definition.evolution_ids:
		var recipe: Dictionary = _catalog.evolutions.definition(id)
		if recipe.is_empty() or not recipe.base_item_id in definition.allowed_equipment_ids: return false
	if not WorldCodec.valid_hash(definition.content_definition_hashes.get("data/enemies.json")) or Chapters.new().definition_digest(definition.enemy_catalog) != definition.content_definition_hashes["data/enemies.json"]: return false
	for enemy in definition.enemy_catalog.values():
		if not enemy is Dictionary: return false
		for key in ["hp","radius"]:
			if not Catalog.number_valid(enemy.get(key),0.0000001,10000000): return false
		for key in ["speed","damage"]:
			if not Catalog.number_valid(enemy.get(key),0,10000000): return false
		if not Catalog.integer_valid(enemy.get("xp")): return false
		for key in ["behavior","art_id"]:
			if not enemy.get(key) is String or enemy[key].is_empty(): return false
	if not Behaviors.final_definition_valid(definition.enemy_catalog.get(FINAL_ENEMY_ID)): return false
	if definition.get("world_mode","") == "streamed_city":
		if not definition.get("world_definitions") is Dictionary or not definition.get("authored_dock") is Dictionary or not definition.world_geometry.is_empty(): return false
		return Streamed._dock_valid(definition.authored_dock)
	return not definition.world_geometry.is_empty() and World.valid(definition.world_geometry) and World.walkable(_vec(definition.spawn_position),8.0,definition.world_geometry)
func _current_chapter() -> Dictionary:
	if not _content_error.is_empty(): return _failure(_content_error)
	var current := _load_provider_chapter()
	if not current.get("ok",false) or not _same_json(current.chapter,_chapter): return _failure("content_mismatch")
	if _chapter.get("world_mode","") == "streamed_city" and not _helper_matches(_world_template,_chapter): return _failure("content_mismatch")
	return current
func _helper_matches(helper, chapter: Dictionary) -> bool:
	return helper is Streamed and helper.valid() and _same_json(helper._definitions,chapter.world_definitions)
var _spatial = SpatialHash.new()
var _world = World.new()
func new_run(chapter: Dictionary, seed: Variant, run_config: Dictionary) -> Dictionary:
	if not Catalog.integer_valid(seed): return _failure("invalid_run_config")
	var current: Dictionary = _current_chapter()
	if not current.get("ok",false): return current
	if not Contracts.new()._json_safe(chapter) or not _same_json(chapter,current.chapter): return _failure("invalid_chapter")
	if not _config_valid(run_config,current.chapter): return _failure("invalid_run_config")
	if not _catalog.validate().is_empty() or not _supplies.validate().is_empty(): return _failure("invalid_item")
	var doctrine: Dictionary = _supplies.doctrine(run_config.doctrine_id)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed)
	var growth_rng := RandomNumberGenerator.new()
	growth_rng.seed = (int(seed) ^ 0x5EED1203) & 0x7fffffff
	var config := run_config.duplicate(true)
	config.run_serial = int(config.run_serial)
	var rules := _rules_for(current.chapter,doctrine,config)
	var state := {"schema_version":2,"content_revision":CONTENT_REVISION,"chapter_id":current.chapter.chapter_id,"character_id":config.get("character_id",Characters.DEFAULT_CHARACTER),"seed":int(seed),"rng_state":str(rng.state),"active_tick":0,"survival_tick":0,"next_entity_id":1,"event_seq":0,"phase":"survival","pause_reasons":[],"player":{"id":"player","position":_array(_vec(current.chapter.spawn_position)),"velocity":[0.0,0.0],"facing":[1.0,0.0],"radius":8.0,"hp":float(rules.base_hp),"max_hp":float(rules.base_hp),"invulnerable_until":0,"xp":0,"level":1,"attack_ready_ticks":{}},"equipment":doctrine.initial_equipment.duplicate(true),"passives":doctrine.initial_passives.duplicate(true),"entities":[],"projectiles":[],"drops":[],"telegraphs":[],"boss_ids_fired":[],"reward_ids_claimed":[],"command_ids_applied":[],"upgrade_offer":{},"pending_offers":[],"final_started_tick":-1,"evacuation_ready":false,"escape_zone":current.chapter.escape_zone.duplicate(),"stats":{"kills":0,"damage_dealt":0.0,"minibosses_defeated":0},"rules":rules,"run_id":config.run_id,"run_serial":config.run_serial,"run_config":config,"evolutions":{},"tactical_seals":0,"progression_rng_state":str(growth_rng.state),"attack_seq":0,"offer_seq":0,"view_revision":1,"player_attack_instances":[],"enemy_attack_instances":[],"evolution_runtime":{},"supply_used":false}
	if Loot.enabled(state): state.loot = Loot.initial(int(config.loot_rules_version))
	if Signature.enabled(state): state.character_skill = Signature.initial_state()
	if current.chapter.get("world_mode","") == "streamed_city":
		state.world = Streamed.initial_world(current.chapter.content_fingerprint)
		if _mobility_rules_enabled(): state.player_mobility = Mobility.initial()
		state.escape_zone = Streamed.CITY_INACTIVE_EXIT.duplicate()
	if not _normalize_saved_numbers(state): return _failure("invalid_core_state")
	return state
func _mobility_rules_enabled() -> bool:
	return _chapter_provider is Object and _chapter_provider.has_method("rules_version") and _chapter_provider.rules_version() == "dev5"
func _config_valid(config: Dictionary, chapter: Dictionary) -> bool:
	if not _supplies.run_upgrade_config_valid(config) or not config.has_all(["run_id","run_serial","doctrine_id","target_evolution_id","prepared_supply"]) or not Catalog.json_data_valid(config): return false
	if not Growth._run_id_valid(config.run_id) or not Catalog.integer_valid(config.run_serial,1) or config.run_id.get_slice(":",1) != str(int(config.run_serial)): return false
	for field in ["doctrine_id","target_evolution_id","prepared_supply"]:
		if not config[field] is String: return false
	if not config.doctrine_id in chapter.doctrine_ids or _supplies.doctrine(config.doctrine_id).is_empty(): return false
	if not config.target_evolution_id in chapter.evolution_ids or _catalog.evolutions.definition(config.target_evolution_id).is_empty(): return false
	return config.prepared_supply in ["","field_bandage"]
func _rules_for(chapter: Dictionary, doctrine: Dictionary, config: Dictionary = {}) -> Dictionary:
	var rules := {"world_geometry":World.canonical(chapter.world_geometry),"allowed_equipment_ids":chapter.allowed_equipment_ids.duplicate(),"enemy_catalog":chapter.enemy_catalog.duplicate(true),"move_speed":float(doctrine.base_move_speed),"pickup_radius":30.0,"evacuation_ticks":4500,"progression":_catalog.progression,"base_hp":float(doctrine.base_hp),"base_move_speed":float(doctrine.base_move_speed),"equipment_slots":4,"passive_slots":4,"content_fingerprint":chapter.content_fingerprint}
	if config.get("character_id",Characters.DEFAULT_CHARACTER) != Characters.DEFAULT_CHARACTER:
		var traits := Characters.new().run_traits(config.character_id)
		rules.move_speed *= float(traits.move_speed_multiplier)
		rules.base_move_speed *= float(traits.move_speed_multiplier)
		rules.character_blade_cooldown_multiplier = float(traits.blade_cooldown_multiplier)
	if config.has("permanent_upgrades"):
		var levels: Dictionary = config.permanent_upgrades
		rules.base_hp += _supplies.permanent_bonus(levels,"max_hp")
		rules.pickup_radius += _supplies.permanent_bonus(levels,"pickup_radius")
		rules.permanent_damage_bonus = _supplies.permanent_bonus(levels,"damage_multiplier")
	return rules
func _same_json(left: Variant, right: Variant) -> bool:
	# JSON integral floats and engine integers are the same semantic value.
	# Exact numeric comparison retains authored tuning without tolerance widening.
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
	if (left is int or left is float) and (right is int or right is float): return float(left) == float(right)
	return typeof(left) == typeof(right) and left == right
func _failure(code: String) -> Dictionary: return {"ok":false,"error_code":code}
func step(state: Dictionary, move: Vector2, commands: Array[Dictionary]) -> Array[Dictionary]:
	# Transient geometry belongs only to this successfully accepted public step.
	# Pauses and preflight/rebase refusals must not expose the preceding tick.
	_final_sweeps.clear()
	_mobility_sweeps.clear()
	_mobility_cast.clear()
	if commands.size() > 1024: return []
	# Preserve the approved atomic incoming-ID exhaustion boundary even when an
	# actor's own attack admission is deferred rather than partially scheduled.
	for command in commands:
		if command.get("kind") is String and command.kind in ["spawn_enemy","spawn_boss"] and command.get("payload") is Dictionary and _generated_identity_number(command.payload.get("entity_id")) >= MAX_COUNTER-1:
			_last_step_status = _failure("counter_exhausted")
			return []
	if state.has("world"): return _step_streamed(state,move,commands)
	if state.phase in ["won","dead","abandoned"] or not state.pause_reasons.is_empty() or not state.upgrade_offer.is_empty(): return []
	var role_transaction: bool = not state.enemy_attack_instances.is_empty()
	for entity in state.entities:
		if _is_live_role(entity): role_transaction = true
	for command in commands:
		if command.get("kind") == "spawn_enemy" and command.get("payload") is Dictionary and command.payload.get("enemy_id") in LIVE_ROLE_IDS: role_transaction = true
	var counter_transaction := _needs_counter_transaction(state,commands)
	var candidate: Dictionary = _tick_candidate(state) if role_transaction or counter_transaction or Loot.enabled(state) else state
	var staged := _step_running(candidate,move,commands)
	if not _role_error.is_empty():
		_last_step_status = _role_error.duplicate(true)
		return []
	if counter_transaction:
		var earned: int = int(candidate.player.level)-int(state.player.level)+(Loot.earned_offer_count(candidate)-Loot.earned_offer_count(state) if Loot.enabled(state) else int(candidate.stats.minibosses_defeated)-int(state.stats.minibosses_defeated))
		if int(candidate.offer_seq)-int(state.offer_seq) != earned:
			_final_sweeps.clear()
			_last_step_status = _failure("counter_exhausted")
			return []
		var checked := _restore_checked(candidate,{})
		if not checked.get("ok",false):
			_final_sweeps.clear()
			_last_step_status = checked
			return []
		candidate = checked.state
	if not is_same(state,candidate):
		state.clear()
		state.merge(candidate,true)
	_attack_view_cache = _role_view_packet(state,_role_samples)
	_last_step_status = {"ok":true,"role_admission":_role_admission.duplicate(true)}
	return staged
func _needs_counter_transaction(state: Dictionary, commands: Array[Dictionary]) -> bool:
	if state.reward_ids_claimed.size() >= 4096-256-5: return true
	for field in ["active_tick","event_seq","next_entity_id","attack_seq","offer_seq","view_revision"]:
		if int(state[field]) > MAX_COUNTER-65536: return true
	if int(state.stats.kills) > MAX_COUNTER-65536 or int(state.player.level) > MAX_COUNTER-65536 or int(state.player.xp) > MAX_COUNTER-65536: return true
	var possible_xp: int = int(state.player.xp)
	for drop in state.drops: possible_xp += int(drop.xp)
	if state.has("world") and state.world.get("schema_version") == 2:
		for collection in ["entities","drops"]:
			for entry in state.world.dormant[collection]: possible_xp += int(entry.record.xp)
	for entity in state.entities:
		possible_xp += int(entity.xp)
		if int(entity.get("pattern_index",0)) > MAX_COUNTER-65536: return true
	for command in commands:
		if not command.get("kind") is String or not command.kind in ["spawn_enemy","spawn_boss"] or not command.get("payload") is Dictionary: continue
		var incoming_id = command.payload.get("entity_id")
		if _generated_identity_number(incoming_id) > MAX_COUNTER-65536: return true
		var enemy_id = command.payload.get("enemy_id")
		if enemy_id is String and state.rules.enemy_catalog.has(enemy_id): possible_xp += int(state.rules.enemy_catalog[enemy_id].xp)
	return possible_xp > MAX_COUNTER-65536
func _step_running(state: Dictionary, move: Vector2, commands: Array[Dictionary]) -> Array[Dictionary]:
	var reuse_role_readiness: bool = _role_batch_tick >= 0 and state.get("active_tick") is int and _role_batch_tick == state.active_tick and _streamed != null and _role_batch_helper_id == _streamed.get_instance_id()
	_role_batch_tick = -1
	_role_batch_helper_id = 0
	var events: Array[Dictionary] = []
	if state.phase in ["won","dead","abandoned"] or not state.pause_reasons.is_empty() or not state.upgrade_offer.is_empty(): return events
	_role_samples = {}
	_role_tick_query = null
	_role_tick_state = state
	_role_error = {}
	_role_admission = {"evaluations":0,"accepted":false,"work_units":0}
	state.active_tick = int(state.active_tick)+1
	_compact_command_history(state)
	if state.phase == "survival": state.survival_tick = mini(FINAL_TICK,int(state.survival_tick)+1)
	_final_sweeps.clear()
	for command in commands: _apply_command(state,command,events)
	if state.phase == "evacuation" and not FINAL_ACTOR_SPAWN_ID in state.command_ids_applied and (int(state.active_tick)-int(state.final_started_tick)) % 30 == 0:
		_try_spawn_final_actor(state,events)
	# Bind the role query to the already prepared, pre-move tick coverage.
	# Movement may cross a view-window edge; individual sweeps still require
	# their exact resident geometry and retain the immutable identity guard.
	if state.has("world") and state.world.stage == "city":
		for entity in state.entities:
			if _is_live_role(entity):
				if reuse_role_readiness: _role_tick_query = RoleQuery._for_admitted_tick(_streamed,state,int(state.active_tick))
				else: _role_query(state)
				break
	_move_player(state,move)
	if not _role_error.is_empty(): return events
	var waiting_moves := _move_enemies(state,events)
	_spatial.rebuild(state.entities)
	_move_waiting_roles(state,waiting_moves)
	_admit_role_attacks(state,events)
	var boss_rewards: Array[Dictionary] = []
	var existing_projectiles := {}
	for projectile in state.projectiles: existing_projectiles[str(projectile.id)] = true
	_auto_attack(state,events,boss_rewards)
	_auto_signature(state,events)
	_execute_player_attacks(state,events,boss_rewards)
	_advance_projectiles(state,events,boss_rewards,existing_projectiles)
	_remove_dead(state)
	_attract_drops(state)
	_collect_drops(state,events,0 if Loot.enabled(state) else boss_rewards.size())
	for reward in boss_rewards: _claim_boss_reward(state,reward,events)
	if Loot.enabled(state): _update_loot(state,events)
	_player_damage(state,events)
	if state.player.hp <= 0.0:
		_end_run(state,"dead","damage",events)
		return events
	_apply_mobility_damage(state,events)
	_use_prepared_supply(state,events)
	_regenerate(state)
	if state.phase == "evacuation":
		if int(state.active_tick)-int(state.final_started_tick) >= int(state.rules.evacuation_ticks): state.evacuation_ready = true
		if state.evacuation_ready and _inside_escape(state): _end_run(state,"won","evacuated",events)
	if state.phase in ["survival","evacuation"]: _activate_next_offer(state,events)
	return events
func choose_upgrade(state: Dictionary, offer_id: String, option_id: String) -> Dictionary:
	# Semantic operation is transactional: validation, application and FIFO promotion
	# happen on one private candidate before the caller's authority is replaced.
	var hydration: Dictionary = {}
	if state.has("world"):
		if _streamed == null or not _streamed.readiness(state).get("ok",false): return _failure("world_not_ready")
		hydration = _streamed._hydration
	var checked := restore(state,hydration)
	if not checked.get("ok",false): return _failure("invalid_offer")
	var candidate: Dictionary = checked.state
	if not candidate.phase in ["survival","evacuation"] or candidate.upgrade_offer.is_empty() or candidate.upgrade_offer.offer_id != offer_id or "offer:"+offer_id in candidate.reward_ids_claimed: return _failure("invalid_offer")
	var selected: Dictionary = {}
	for option in candidate.upgrade_offer.options:
		if option.option_id == option_id: selected = option
	if selected.is_empty() or not _catalog.option_valid(candidate,selected): return _failure("invalid_option")
	var events: Array[Dictionary] = []
	if selected.kind == "evolution":
		var recipe: Dictionary = _catalog.evolutions.definition(selected.evolution_id)
		candidate.evolutions[selected.item_id] = selected.evolution_id
		candidate.tactical_seals = int(candidate.tactical_seals)-int(recipe.seal_cost)
	else:
		var owned: Dictionary = candidate.equipment if selected.kind == "equipment" else candidate.passives
		owned[selected.item_id] = int(selected.next_level)
		if selected.kind == "passive" and selected.item_id == "max_health":
			candidate.player.max_hp = _catalog.stat(candidate,"max_hp",float(candidate.rules.base_hp))
			candidate.player.hp = minf(float(candidate.player.max_hp),float(candidate.player.hp)+float(_catalog.passives.max_health.increment))
	_emit(candidate,events,"upgrade_applied",{"offer_id":offer_id,"option_id":option_id,"item_id":selected.item_id,"kind":selected.kind})
	if candidate.upgrade_offer.source == "chest":
		var chest: Dictionary = Loot.find_chest(candidate,candidate.upgrade_offer.chest_id)
		if chest.is_empty() or chest.status != "queued": return _failure("invalid_offer")
		chest.status = "claimed"
		chest.result = "skill"
	_claim_id(candidate.reward_ids_claimed,"offer:"+offer_id)
	candidate.upgrade_offer = {}
	candidate.pause_reasons.erase("upgrade")
	candidate.view_revision = int(candidate.view_revision)+1
	if not _activate_next_offer(candidate,events): return _failure("invalid_offer_queue")
	var validated := restore(candidate,hydration)
	if not validated.get("ok",false): return _failure("invalid_core_state")
	candidate = validated.state
	state.clear()
	state.merge(candidate,true)
	return {"ok":true,"events":events}
func set_pause(state: Dictionary, reason: String, enabled: bool) -> void:
	if not reason in PAUSE_REASONS or state.phase in ["won","dead","abandoned"]: return
	if reason == "upgrade" and state.upgrade_offer.is_empty(): return
	if enabled:
		_claim_id(state.pause_reasons,reason)
	elif reason != "upgrade" or state.upgrade_offer.is_empty():
		state.pause_reasons.erase(reason)
func set_offer_focus(state: Dictionary, option_id: String) -> void:
	if state.upgrade_offer.is_empty() or state.phase in ["won","dead","abandoned"] or int(state.view_revision) >= MAX_COUNTER: return
	for option in state.upgrade_offer.options:
		if option.option_id == option_id:
			if state.upgrade_offer.selected_option_id != option_id:
				state.upgrade_offer.selected_option_id = option_id
				state.view_revision = int(state.view_revision)+1
			return
func abandon_run(state: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if state.phase in ["won","dead","abandoned"] or int(state.event_seq) >= MAX_COUNTER or int(state.view_revision) >= MAX_COUNTER: return events
	_end_run(state,"abandoned","abandoned",events)
	return events
func snapshot(state: Dictionary) -> Dictionary:
	return state.duplicate(true)
func acknowledge_autosave_world(state: Dictionary, captured_snapshot: Dictionary, receipt: Dictionary, confirmed_world: Dictionary) -> Dictionary:
	# Main-thread acknowledgment after exact durable confirmation.
	# Never restore/adopt a worker Core or rewind any live gameplay field here.
	if OS.get_thread_caller_id() != OS.get_main_thread_id(): return _failure("world_ack_wrong_thread")
	if not _content_error.is_empty() or _chapter.get("world_mode") != "streamed_city": return _failure("content_mismatch")
	if _streamed == null or _streamed.get_script() != Streamed or not _last_step_status.get("ok",false): return _failure("world_not_ready")
	for value in [state,captured_snapshot]:
		if not value.get("run_id") is String or not Growth._run_id_valid(value.run_id) or not Catalog.integer_valid(value.get("run_serial"),1): return _failure("world_ack_identity")
		if value.run_id.get_slice(":",1) != str(int(value.run_serial)) or not Catalog.integer_valid(value.get("seed")) or not Catalog.integer_valid(value.get("active_tick")): return _failure("world_ack_identity")
		if not value.get("run_config") is Dictionary or not _config_valid(value.run_config,_chapter): return _failure("world_ack_identity")
		if value.run_config.run_id != value.run_id or value.run_config.run_serial != value.run_serial: return _failure("world_ack_identity")
		if not value.get("rules") is Dictionary or not value.rules.get("content_fingerprint") is String or value.rules.content_fingerprint != _chapter.content_fingerprint: return _failure("content_mismatch")
		if not value.get("chapter_id") is String or value.chapter_id != _chapter.chapter_id or not value.get("content_revision") is String or value.content_revision != CONTENT_REVISION: return _failure("content_mismatch")
	for field in ["run_id","run_serial","seed","run_config","chapter_id","content_revision"]:
		if not Streamed._same_json(state.get(field),captured_snapshot.get(field)): return _failure("world_ack_identity")
	if state.active_tick < captured_snapshot.active_tick: return _failure("world_ack_stale")
	# Bound hostile/cyclic packets before recursive world comparisons. No full
	# actor snapshot validation, provider capture or filesystem access is needed.
	if not Contracts.new()._json_safe([state.get("world"),captured_snapshot.get("world"),receipt,confirmed_world]): return _failure("world_ack_invalid")
	return _streamed._acknowledge_autosave_world(state,captured_snapshot,receipt,confirmed_world)
func restore(value: Dictionary, hydrated_deltas: Dictionary = {}) -> Dictionary:
	# Validation never installs geometry on the live Core. Adoption is explicit.
	return _restore_checked(value,hydrated_deltas)
func prepare_enemy_attack_view(state: Dictionary) -> Dictionary:
	# Explicit finite adoption, separate from read-only save validation.
	if state.has("world"): return _failure("world_not_ready")
	var checked := _restore_checked(state,{})
	if not checked.get("ok",false): return checked
	_attack_view_cache = checked.attack_view.duplicate(true)
	return {"ok":true}
func prepare_world(state: Dictionary, verified_hydration: Dictionary, commands: Array = []) -> Dictionary:
	var prepared := []
	var checked := _restore_checked(state,verified_hydration,commands,prepared)
	if not checked.get("ok",false): return checked
	if prepared.is_empty(): return _failure("world_not_ready")
	if state.has("player_mobility") and state.player_mobility.schema_version == 1: return _failure("mobility_migration_required")
	_streamed = prepared[0]
	_attack_view_cache = checked.attack_view.duplicate(true)
	if _has_live_configuration(false): _configuration_admitted = true
	return {"ok":true}
func world_status() -> Dictionary:
	return {"ok":false,"error_code":"world_not_ready","resident_chunks":0} if _streamed == null else _streamed.status()
func world_render_view(state: Dictionary) -> Dictionary:
	# Explicit derived-data boundary. Call only when terrain/origin/coverage
	# identity changes, not per actor/frame: helper localizes copied chunks.
	if _streamed == null or not Streamed.enabled(state): return _failure("world_not_ready")
	return _streamed.render_view(state)
func _restore_preamble(value: Dictionary) -> Dictionary:
	var errors: Array[String] = Contracts.new().validate_snapshot(value)
	if not errors.is_empty(): return {"ok":false,"error_code":"unsupported_schema" if "unsupported_schema" in errors else "invalid_snapshot","errors":errors}
	if value.has("player_mobility") and not _mobility_rules_enabled(): return _failure("content_mismatch")
	if value.content_revision != CONTENT_REVISION or value.chapter_id != "chapter_01_shiganshina" or not Characters.new().runtime_available(value.character_id): return _failure("content_mismatch")
	return {"ok":true}
func _restore_checked(value: Dictionary, hydrated_deltas: Dictionary, commands: Array = [], prepared: Array = []) -> Dictionary:
	var preamble := _restore_preamble(value)
	if not preamble.get("ok",false): return preamble
	var current: Dictionary = _current_chapter()
	if not current.get("ok",false): return current
	return _restore_admitted_body(value,hydrated_deltas,commands,prepared,current)
func _restore_admitted_body(value: Dictionary, hydrated_deltas: Dictionary, commands: Array, prepared: Array, current: Dictionary, source_helper = null) -> Dictionary:
	var city: bool = current.chapter.get("world_mode","") == "streamed_city"
	if city != value.has("world"): return _failure("world_not_ready")
	if not city and not hydrated_deltas.is_empty(): return _failure("invalid_hydration")
	if not value.rules.get("content_fingerprint") is String or value.rules.content_fingerprint != current.chapter.content_fingerprint: return _failure("content_mismatch")
	if value.character_id != value.run_config.get("character_id",Characters.DEFAULT_CHARACTER): return _failure("invalid_run_config")
	if not _config_valid(value.run_config,current.chapter) or value.run_config.run_id != value.run_id or value.run_config.run_serial != value.run_serial: return _failure("invalid_run_config")
	var doctrine: Dictionary = _supplies.doctrine(value.run_config.doctrine_id)
	if not _same_json(value.rules,_rules_for(current.chapter,doctrine,value.run_config)): return _failure("invalid_core_state")
	var restored: Dictionary = value.duplicate(true)
	if not _normalize_saved_numbers(restored): return _failure("invalid_core_state")
	if restored.has("player_mobility"):
		for field in ["schema_version","cast_id","started_tick","travel_ticks","cooldown_until","cancel_ticks","roll"]:
			restored.player_mobility[field] = int(restored.player_mobility[field])
	if not _catalog.evolutions.progression_state_valid(restored) or not _v2_relationships_valid(restored,current.chapter): return _failure("invalid_core_state")
	var validation_helper
	if city:
		var world_check := Streamed.validate_world(restored)
		if not world_check.get("ok",false): return world_check
		var dormant: Dictionary = restored.world.get("dormant",{})
		restored.world = Chapters.new()._canonical_numbers(restored.world)
		# Dormant bodies/drops retain Core's vector and scalar normalization,
		# rather than becoming generic integer-valued world-definition data.
		if int(restored.world.schema_version) == 2: restored.world.dormant = dormant
		if restored.world.stage == "dock" and not _same_json(restored.world.escape_rect,current.chapter.authored_dock.escape_rect): return _failure("invalid_core_state")
		validation_helper = _world_template._fork_live_configuration() if source_helper != null else _world_template.fresh()
		if validation_helper == null or validation_helper == _world_template or validation_helper == _streamed: return _failure("content_mismatch")
		if source_helper == null and not _helper_matches(validation_helper,current.chapter): return _failure("content_mismatch")
		var ready: Dictionary = validation_helper._prepare_live(restored,hydrated_deltas,commands,source_helper) if source_helper != null else validation_helper.prepare(restored,hydrated_deltas,commands)
		if not ready.get("ok",false): return ready
	if not _core_payload_valid(restored,current.chapter,validation_helper):
		if validation_helper != null and not validation_helper.query_status().get("ok",false): return validation_helper.query_status()
		return _failure("invalid_core_state")
	for key in ["id","position","velocity","facing","radius","hp","max_hp","invulnerable_until","xp","level","attack_ready_ticks"]:
		if not restored.player.has(key): return _failure("invalid_player")
	if not restored.player.id is String or restored.player.id != "player" or not _position_valid(restored.player.velocity) or not _position_valid(restored.player.facing) or not is_equal_approx(_vec(restored.player.facing).length_squared(),1.0): return _failure("invalid_player")
	if restored.player.radius != 8 or restored.player.max_hp != _catalog.stat(restored,"max_hp",float(restored.rules.base_hp)) or restored.player.hp > restored.player.max_hp or restored.player.level < 1: return _failure("invalid_player")
	for reason in restored.pause_reasons:
		if not reason in PAUSE_REASONS: return _failure("invalid_pause_reason")
	if not _offer_valid(restored,restored.upgrade_offer,true): return _failure("invalid_offer")
	if not restored.upgrade_offer.is_empty():
		# Identity/levels/focus were validated unchanged above. Reconstruct only
		# deterministic decoration scalar types from the pinned catalog, no RNG.
		var options: Array[Dictionary] = []
		for option in restored.upgrade_offer.options: options.append(_catalog.decorate_option(restored,option))
		restored.upgrade_offer.options = options
	for descriptor in restored.pending_offers:
		if not descriptor is Dictionary or not Growth.new(_catalog)._descriptor_valid(restored,descriptor): return _failure("invalid_offer_queue")
	if not _offer_queue_ids_valid(restored): return _failure("invalid_offer_queue")
	# Purchased damage introduces decimal products that JSON may parse one ULP
	# away. Reconstruct only uniquely validated cast-time values; legacy runs
	# retain their original representation and no current passive is reapplied.
	if float(restored.rules.get("permanent_damage_bonus",0.0)) > 0.0:
		if not _evolved.canonicalize_damage(_legacy_attack_state(restored)): return _failure("invalid_core_state")
		for projectile in restored.projectiles:
			var canonical_damage: Array[float] = []
			if not _projectile_valid(restored,projectile,canonical_damage): return _failure("invalid_core_state")
			projectile.damage = canonical_damage[0]
	if not Fantasy.canonicalize(restored,_catalog): return _failure("invalid_core_state")
	_signature.canonicalize(restored)
	_canonicalize_saved_vectors(restored)
	if restored.has("player_mobility") and restored.player_mobility.schema_version == 1:
		var legacy_roles := _role_samples_checked(restored,validation_helper)
		if not legacy_roles.get("ok",false): return legacy_roles
		var ground_query := Callable()
		if restored.world.stage == "dock":
			# The authored dock uses finite geometry; its helper intentionally
			# owns no streamed chunks. Keep the existing collision authority.
			ground_query = func(position: Vector2) -> Dictionary: return {"ok":true,"walkable":_validation_walkable(restored,position,8.0,validation_helper)}
		var migrated := Mobility.migrate_legacy(restored,validation_helper,ground_query)
		if not migrated.get("ok",false): return migrated
		if not Contracts.new().validate_snapshot(restored).is_empty(): return _failure("invalid_snapshot")
		var migrated_helper = _world_template.fresh()
		if not _helper_matches(migrated_helper,current.chapter) or migrated_helper == _world_template or migrated_helper == _streamed or migrated_helper == validation_helper: return _failure("content_mismatch")
		var ready: Dictionary = migrated_helper.prepare(restored,hydrated_deltas,commands)
		if not ready.get("ok",false): return ready
		if not _core_payload_valid(restored,current.chapter,migrated_helper): return _failure("invalid_core_state")
		validation_helper = migrated_helper
	if validation_helper != null:
		var status: Dictionary = validation_helper.query_status()
		if not status.get("ok",false): return status
		prepared.append(validation_helper)
	var role_check := _role_samples_checked(restored,validation_helper)
	if not role_check.get("ok",false): return role_check
	return {"ok":true,"state":restored,"attack_view":_role_view_packet(restored,role_check.samples)}
func _v2_relationships_valid(state: Dictionary, chapter: Dictionary) -> bool:
	var expected_exit: Array = chapter.escape_zone
	if chapter.get("world_mode","") == "streamed_city":
		if not state.get("world") is Dictionary or not state.world.get("stage") is String: return false
		expected_exit = Streamed.CITY_INACTIVE_EXIT if state.world.stage == "city" else chapter.authored_dock.escape_rect
	if not _same_json(state.escape_zone,expected_exit) or not state.supply_used is bool or (state.run_config.prepared_supply == "" and state.supply_used): return false
	if not Catalog.integer_valid(state.stats.get("minibosses_defeated"),0,5): return false
	var boss_rewards := 0
	for id in state.reward_ids_claimed:
		if not id is String: return false
		if id.begins_with("boss:"):
			var boss: String = id.trim_prefix("boss:")
			if not boss in REAL_BOSS_IDS or not boss in state.boss_ids_fired: return false
			boss_rewards += 1
	for id in state.boss_ids_fired:
		if id == "ch01_final_armored":
			if state.survival_tick != FINAL_TICK: return false
		elif not id in REAL_BOSS_IDS or state.survival_tick < (REAL_BOSS_IDS.find(id)+1)*18000: return false
	if boss_rewards != state.stats.minibosses_defeated or boss_rewards != int(state.tactical_seals)+_catalog.evolutions.spent_seals(state): return false
	var growth_rewards: int = Loot.earned_offer_count(state) if Loot.enabled(state) else boss_rewards
	if not Catalog.integer_valid(state.player.get("level"),1) or int(state.offer_seq) > int(state.player.level)-1+growth_rewards: return false
	if Loot.enabled(state) and int(state.offer_seq) != int(state.player.level)-1+growth_rewards: return false
	if not Catalog.integer_valid(state.stats.get("kills")) or state.stats.kills < boss_rewards: return false
	if not _number_valid(state.player.get("hp")): return false
	if state.phase == "dead" and state.player.hp != 0: return false
	if state.phase in ["survival","evacuation","won"] and not _number_valid(state.player.get("hp"),0.0000001): return false
	# Raw enemy records are validated with their prepared world below.
	if not _evolved.validate_records(_legacy_attack_state(state)) or not Fantasy.validate_records(state,_catalog) or not _signature.validate_records(state) or not state.evolution_runtime.is_empty(): return false
	return true
# Old production commands have durable monotonic owners already in RunState.
# Batch collection bounds work and preserves opaque historical IDs unchanged.
# Do not call this during restore: duplicate/corrupt ledger validation must run
# before any cleanup, and hydration must reproduce the saved authority exactly.
func _compact_command_history(state: Dictionary) -> void:
	if state.command_ids_applied.size() <= COMMAND_HISTORY_COMPACT_AT: return
	var owners := {}
	for entity in state.entities:
		var identity := _generated_identity_number(entity.id)
		if identity > 0: owners[identity] = int(entity.get("pattern_index",0))
	if state.has("world") and state.world.get("schema_version") == 2:
		for entry in state.world.dormant.entities:
			var identity := _generated_identity_number(entry.record.id)
			if identity > 0: owners[identity] = int(entry.record.get("pattern_index",0))
	var retained := []
	for command_id in state.command_ids_applied:
		var director_tick := _director_spawn_tick(command_id)
		if director_tick >= 0 and director_tick < int(state.active_tick): continue
		var pieces: PackedStringArray = command_id.split(":")
		if pieces.size() == 3 and pieces[0] in ["behavior","final-impact"]:
			var identity := _generated_identity_number(pieces[1])
			var pattern := _generated_identity_number(pieces[2])
			if identity > 0 and identity < int(state.next_entity_id) and pattern > 0:
				# Keep current markers even in move/recover, and keep future
				# claimed IDs so a hostile/corrupt preclaim is never forgiven.
				if not owners.has(identity) or pattern < int(owners[identity]): continue
		retained.append(command_id)
	state.command_ids_applied = retained
func _action_history_owner(command_id: String) -> int:
	var pieces: PackedStringArray = command_id.split(":")
	if pieces.size() != 3 or not pieces[0] in ["behavior","final-impact"] or _generated_identity_number(pieces[2]) == 0: return 0
	return _generated_identity_number(pieces[1])
func _director_spawn_tick(command_id: String) -> int:
	var pieces: PackedStringArray = command_id.split("_")
	if pieces.size() != 3 or pieces[0] != "enemy": return -1
	var tick := _generated_identity_number(pieces[1])
	if tick == 0 or not pieces[2].is_valid_int(): return -1
	var index: int = pieces[2].to_int()
	if index < 0 or index > 1023 or pieces[2] != str(index): return -1
	return tick
func _apply_command(state: Dictionary, command: Dictionary, events: Array[Dictionary], internal_behavior: bool = false) -> void:
	var spatial: bool = state.has("world") and Streamed.spatial_command(command)
	if command.size() != (4 if spatial else 3) or not command.has_all(["command_id","kind","payload"]) or not Catalog.json_data_valid(command): return
	if spatial and (not WorldCodec.integer(command.get("origin_revision")) or command.origin_revision > WorldCodec.MAX_JSON_INTEGER or command.origin_revision != state.world.origin_revision): return
	if not command.command_id is String or command.command_id.is_empty() or command.command_id.length() > 128 or not command.kind is String or not command.payload is Dictionary: return
	var command_id := str(command.command_id)
	# Reserved lifecycle IDs cannot be submitted as opaque external commands.
	if _action_history_owner(command_id) > 0:
		if not internal_behavior or command.kind != "telegraph_attack" or command.payload.get("behavior_attack") != true: return
	var director_tick := _director_spawn_tick(command_id)
	if director_tick >= 0:
		if command.kind != "spawn_enemy" or director_tick != int(state.active_tick) or not Catalog.integer_valid(command.payload.get("spawned_tick"),director_tick,director_tick) or _generated_identity_number(command.payload.get("entity_id")) == 0: return
	if state.command_ids_applied.size() >= 16384: return
	if command_id in state.command_ids_applied: return
	var payload: Dictionary = command.payload
	var applied := false
	match str(command.kind):
		"spawn_enemy", "spawn_boss":
			applied = _spawn(state,payload,str(command.kind)=="spawn_boss",events)
		"telegraph_attack":
			if _hazard_valid(payload) and state.telegraphs.size() < (512 if state.has("world") else 1024) and int(state.active_tick)+int(payload.warning_ticks)+int(payload.active_ticks) <= MAX_COUNTER and (internal_behavior or not payload.has("behavior_attack")):
				var hazard: Dictionary = payload.duplicate(true)
				hazard.origin = _array(_vec(payload.origin))
				if payload.has("direction"): hazard.direction = _array(_vec(payload.direction))
				hazard.id = _new_id(state)
				hazard.created_tick = int(state.active_tick)
				hazard.active_from_tick = int(state.active_tick)+int(payload.warning_ticks)
				hazard.expires_tick = int(hazard.active_from_tick)+int(payload.active_ticks)
				state.telegraphs.append(hazard)
				applied = true
		"begin_evacuation":
			if state.phase == "survival" and int(state.survival_tick) >= FINAL_TICK and payload.get("boss_id") is String and payload.boss_id == "ch01_final_armored" and _same_json(payload.get("escape_zone"),state.escape_zone) and Catalog.integer_valid(payload.get("evacuation_ticks"),4500,4500):
				state.phase = "evacuation"
				state.survival_tick = FINAL_TICK
				state.final_started_tick = int(state.active_tick)
				state.evacuation_ready = false
				state.escape_zone = payload.escape_zone.map(func(value): return float(value))
				var phase_payload := {"phase":"evacuation"}
				if state.has("world") and state.world.get("schema_version") == 2:
					var cleared := {"dormant_entities":state.world.dormant.entities.size(),"dormant_drops":state.world.dormant.drops.size(),"dormant_xp":0}
					for entry in state.world.dormant.drops: cleared.dormant_xp += int(entry.record.xp)
					phase_payload.population_cleared = cleared
					state.world = state.world.duplicate(true)
					state.world.dormant = {"entities":[],"drops":[]}
				state.entities.clear()
				state.drops.clear()
				state.projectiles.clear()
				state.telegraphs.clear()
				state.player_attack_instances.clear()
				if state.has("character_skill"): state.character_skill.pending_cast_id = ""
				state.enemy_attack_instances.clear()
				_claim_id(state.boss_ids_fired,"ch01_final_armored")
				_emit(state,events,"phase_changed",phase_payload)
				applied = true
		"evacuation_ready":
			if state.phase == "evacuation" and int(state.active_tick)-int(state.final_started_tick) >= int(state.rules.evacuation_ticks):
				state.evacuation_ready = true
				applied = true
	if applied: _claim_id(state.command_ids_applied,command_id)
func _spawn(state: Dictionary, payload: Dictionary, boss: bool, events: Array[Dictionary], final_actor: bool = false) -> bool:
	if state.phase != ("evacuation" if final_actor else "survival") or not _id_valid(payload.get("entity_id")) or not payload.get("enemy_id") is String or not _position_valid(payload.get("position",[])): return false
	var entity_id: Variant = payload.entity_id if payload.entity_id is String else int(payload.entity_id)
	# The allocator is also the tombstone for retired generated identities.
	var allocated_id := _generated_identity_number(entity_id)
	if allocated_id > 0 and allocated_id < int(state.next_entity_id): return false
	var enemy_id := str(payload.enemy_id)
	if not state.rules.enemy_catalog.has(enemy_id): return false
	if final_actor:
		if enemy_id != FINAL_ENEMY_ID or payload.get("boss_id") != FINAL_BOSS_ID or FINAL_ACTOR_SPAWN_ID in state.command_ids_applied: return false
	elif enemy_id == FINAL_ENEMY_ID: return false
	if not boss and (enemy_id.begins_with("boss_") or not Catalog.integer_valid(payload.get("spawned_tick",state.active_tick),0,int(state.active_tick)) or not str(payload.get("boss_id","")).is_empty()): return false
	if boss and not final_actor:
		if not payload.get("boss_id") is String or not payload.boss_id in REAL_BOSS_IDS or payload.boss_id in state.boss_ids_fired: return false
		if not Catalog.integer_valid(payload.get("scheduled_tick")): return false
		var current: Dictionary = {"ok":not _chapter.is_empty(),"chapter":_chapter}
		if not current.get("ok",false): return false
		var authored: Dictionary = current.chapter.boss_schedule[REAL_BOSS_IDS.find(payload.boss_id)]
		if enemy_id != authored.enemy_id or int(payload.scheduled_tick) != int(authored.tick) or state.survival_tick < authored.tick: return false
	for collection in ["entities","projectiles","drops","telegraphs"]:
		for record in state[collection]:
			if str(record.id) == str(entity_id): return false
	var dormant_bodies := 0
	if state.has("world") and state.world.get("schema_version") == 2:
		dormant_bodies = state.world.dormant.entities.size()
		for collection in ["entities","drops"]:
			for entry in state.world.dormant[collection]:
				if str(entry.record.id) == str(entity_id): return false
	if state.entities.size()+dormant_bodies >= MAX_ENTITIES: return false
	var definition: Dictionary = state.rules.enemy_catalog[enemy_id]
	var spawn := _spawn_position(state,_vec(payload.position),float(definition.radius))
	if not is_finite(spawn.x) or not is_finite(spawn.y) or not _walkable_world(state,spawn,float(definition.radius)): return false
	var entity := {"id":entity_id,"entity_id":entity_id,"enemy_id":enemy_id,"position":_array(spawn),"velocity":[0.0,0.0],"hp":float(definition.hp),"max_hp":float(definition.hp),"speed":float(definition.speed),"radius":float(definition.radius),"damage":float(definition.get("damage",definition.get("contact_damage",0.0))),"xp":int(definition.xp),"behavior":definition.get("behavior","chase"),"art_id":definition.get("art_id","titan_basic"),"spawned_tick":int(payload.get("scheduled_tick",payload.get("spawned_tick",state.active_tick))),"boss_id":payload.get("boss_id","")}
	state.entities.append(entity)
	var reserved_id := _generated_identity_number(entity_id)
	if reserved_id > 0: state.next_entity_id = maxi(int(state.next_entity_id),reserved_id+1)
	if boss:
		_claim_id(state.boss_ids_fired,str(payload.boss_id))
		_emit(state,events,"boss_spawned",{"boss_id":payload.boss_id,"entity_id":entity_id,"enemy_id":enemy_id})
	return true
func _try_spawn_final_actor(state: Dictionary, events: Array[Dictionary]) -> void:
	if not state.rules.enemy_catalog.has(FINAL_ENEMY_ID): return
	var radius := float(state.rules.enemy_catalog[FINAL_ENEMY_ID].radius)
	var player := _vec(state.player.position)
	# Exactly 24 verified candidates near the evacuation approach. No invented
	# walkability, population parking, identity consumption, or simulation pause.
	for distance in [260.0,320.0,380.0]:
		for index in 8:
			var point: Vector2 = player+Vector2.UP.rotated(TAU*index/8.0)*distance
			if not _walkable_world(state,point,radius): continue
			var ready := _final_contact_ready(state,point,point.direction_to(player),state.rules.enemy_catalog[FINAL_ENEMY_ID].action_profile,_streamed)
			if not ready.get("ok",false) or not ready.clear: continue
			var payload := {"entity_id":int(state.next_entity_id),"enemy_id":FINAL_ENEMY_ID,"boss_id":FINAL_BOSS_ID,"position":_array(point),"scheduled_tick":int(state.final_started_tick)}
			if _spawn(state,payload,true,events,true):
				_claim_id(state.command_ids_applied,FINAL_ACTOR_SPAWN_ID)
				return
	_emit(state,events,"final_actor_spawn_deferred",{"reason":"no_legal_space","retry_tick":int(state.active_tick)+30})
func _spawn_position(state: Dictionary, requested: Vector2, radius: float) -> Vector2:
	var world: Dictionary = _finite_geometry(state)
	if _walkable_world(state,requested,radius): return requested
	var player := _vec(state.player.position)
	var minimum := maxf(radius+float(state.player.radius)+16.0,minf(128.0,requested.distance_to(player)))
	var nearest := _nearest_world(state,requested,radius)
	if _walkable_world(state,nearest,radius) and nearest.distance_to(player) >= minimum: return nearest
	# Clamping an outward spawn beside a wall must not drop a new body onto the
	# player. Search the same ring in fixed angular order, with no RNG draws.
	var ring := maxf(160.0,requested.distance_to(player))
	var angle := (requested-player).angle()
	var best := Vector2(INF,INF)
	var cost := INF
	for index in 16:
		var candidate := _nearest_world(state,player+Vector2.from_angle(angle+TAU*index/16.0)*ring,radius)
		var distance := candidate.distance_squared_to(requested)
		if _walkable_world(state,candidate,radius) and candidate.distance_to(player) >= minimum and distance < cost:
			best = candidate
			cost = distance
	return best
func _move_player(state: Dictionary, input: Vector2) -> void:
	var move := input.limit_length(1.0) if is_finite(input.x) and is_finite(input.y) else Vector2.ZERO
	if state.has("player_mobility") and _mobility_rules_enabled() and state.has("world") and state.world.stage == "city":
		var proposed: Dictionary = Mobility.advance(state,move,_streamed)
		if proposed.status == "refused":
			_role_error = _failure(proposed.error_code)
			return
		state.player_mobility = proposed.mobility
		if proposed.status == "accepted":
			var previous := _vec(state.player.position)
			state.player.position = _array(proposed.proposed_position)
			state.player.velocity = _array((proposed.proposed_position-previous)*TICKS_PER_SECOND)
			_mobility_sweeps = proposed.sweeps
			_mobility_cast = proposed.mobility.duplicate(true)
			if not Mobility.vec(proposed.mobility.direction).is_zero_approx(): state.player.facing = proposed.mobility.direction.duplicate()
			if proposed.mobility.phase == "ground": state.player_mobility = Mobility.grounded(proposed.mobility)
			return
	var speed := float(state.rules.move_speed)*_catalog.stat(state,"move_multiplier",1.0)
	var velocity := move*speed
	var position := _move_world(state,_vec(state.player.position),velocity/TICKS_PER_SECOND,float(state.player.radius))
	state.player.position = _array(position)
	state.player.velocity = _array(velocity)
	if not move.is_zero_approx(): state.player.facing = _array(move.normalized())
func _apply_mobility_damage(state: Dictionary, events: Array[Dictionary]) -> void:
	if _mobility_sweeps.is_empty() or _mobility_cast.is_empty() or _mobility_cast.cancelled or float(state.player.hp) <= 0.0: return
	# Enemy movement can damage either side anchor after our proposal. A stale wire must
	# stop path damage in this same tick, not one tick later.
	var route := Mobility.route_sample(_mobility_cast,state.world.origin_chunk)
	if not route.get("ok",false):
		_role_error = _failure("invalid_mobility_path")
		return
	var fresh: Dictionary = _streamed.mobility_pair_check(state,_mobility_cast.anchors)
	if not fresh.get("ok",false):
		if fresh.get("error_code") == "stale_mobility_anchor":
			state.player_mobility = Mobility.grounded(state.player_mobility)
			state.player.velocity = [0.0,0.0]
		else: _role_error = fresh
		return
	var rewards: Array[Dictionary] = []
	# Earlier ordinary attacks may have removed array entries since the first
	# rebuild. Path queries must index the current live array.
	_spatial.rebuild(state.entities)
	var attack_id: String = state.run_id+":mobility:"+str(int(_mobility_cast.cast_id))
	for sweep in _mobility_sweeps:
		var delta: Vector2 = sweep.to-sweep.from
		var shape := {"shape":"line","origin":_array(sweep.from),"direction":_array(delta.normalized()),"length":delta.length(),"width":float(_mobility_cast.width)}
		var midpoint: Vector2 = (sweep.from+sweep.to)*0.5
		for index in _spatial.query(midpoint,delta.length()*0.5+float(_mobility_cast.width)*0.5+32.0):
			var entity: Dictionary = state.entities[index]
			var id := str(entity.id)
			if entity.hp <= 0 or id in _mobility_cast.hit_ids or not Geometry.overlaps(shape,_vec(entity.position),float(entity.radius)): continue
			_mobility_cast.hit_ids.append(id)
			state.player_mobility.hit_ids.append(id)
			_hit_entity(state,entity,float(_mobility_cast.damage),"player_mobility",events,rewards,attack_id)
	# Existing combat order is untouched. Settle only newly accepted path kills
	# before publishing this tick or opening its upgrade offer.
	_remove_dead(state)
	_collect_drops(state,events,rewards.size())
	for reward in rewards: _claim_boss_reward(state,reward,events)
func _move_enemies(state: Dictionary, events: Array[Dictionary]) -> Array[int]:
	if get_script() == load("res://game/core/run_simulation.gd") and state.has("world") and state.world.stage == "city" and _streamed != null and _streamed.get_script() == Streamed:
		_streamed._bind_native_pursuit(state,_native_pursuit_counts)
	# Successful target clearances belong only to this movement batch.
	var movement_targets := {}
	var waiting_moves: Array[int] = []
	for index in state.entities.size():
		var entity: Dictionary = state.entities[index]
		if not entity.has("action_state"): _initialize_action(state,entity)
		_advance_enemy_action(state,entity,events,movement_targets)
		# Eligibility/attack updates keep their original array order. Only the
		# physical reposition of an already waiting actor is deferred.
		if _is_live_role(entity) and entity.hp > 0 and entity.action_state == "move" and int(entity.role_wait_since) >= 0 and int(entity.role_wait_since) < int(state.active_tick):
			waiting_moves.append(index)
		# NEW derived inactive anchors: the move branch reads position/player;
		# _start_enemy_action overwrites both anchors before using an attack.
		# Never rewrite windup, airborne, attack or recovery geometry.
		if state.has("world") and state.world.stage == "city" and entity.action_state == "move":
			entity.locked_origin = entity.position.duplicate()
			entity.locked_target = state.player.position.duplicate()
	return waiting_moves
func _move_waiting_roles(state: Dictionary, indices: Array[int]) -> void:
	if indices.is_empty(): return
	# The existing rebuild now describes this exact, fixed entity array after
	# spawn and every ordinary/attack move (including terrain destruction).
	# Relocate only moved waiters, so later waiters and combat queries stay exact.
	# Movement only reads these normalized profiles. Reuse at most the three
	# live roles within this call; never retain a catalog across tick/Core scope.
	var waiting_profiles := {}
	for index in indices:
		var entity: Dictionary = state.entities[index]
		var role := str(entity.enemy_id)
		if not waiting_profiles.has(role): waiting_profiles[role] = _role_profile(role)
		var previous := _vec(entity.position)
		_move_waiting_role(state,entity,waiting_profiles[role])
		_spatial.relocate(index,previous,_vec(entity.position))
		if state.has("world") and state.world.stage == "city":
			entity.locked_origin = entity.position.duplicate()
			entity.locked_target = state.player.position.duplicate()
func _initialize_action(state: Dictionary, entity: Dictionary) -> void:
	var direction := _vec(entity.position).direction_to(_vec(state.player.position))
	if direction.is_zero_approx(): direction = Vector2.RIGHT
	entity.facing = _array(direction)
	entity.action_state = "move"
	entity.action_started_tick = int(state.active_tick)
	entity.action_ends_tick = int(state.active_tick)
	entity.next_action_tick = int(state.active_tick)
	entity.pattern_index = 0
	entity.attack_kind = "none"
	entity.locked_origin = entity.position.duplicate()
	entity.locked_direction = _array(direction)
	entity.locked_target = state.player.position.duplicate()
	if _is_live_role(entity):
		entity.role_wait_since = -1
		entity.role_retry_tick = 0
		entity.role_hand_reach = -1.0
func _advance_enemy_action(state: Dictionary, entity: Dictionary, events: Array[Dictionary], movement_targets: Variant = null) -> void:
	if _is_live_role(entity):
		_advance_role_attack(state,entity,events,movement_targets)
		return
	var profile: Dictionary = Behaviors.profile(entity,state.rules.enemy_catalog)
	var tick := int(state.active_tick)
	var player := _vec(state.player.position)
	var position := _vec(entity.position)
	if entity.action_state == "move":
		if profile.kind != "none" and tick >= int(entity.next_action_tick) and position.distance_to(player) <= float(profile.trigger_range) and _start_enemy_action(state,entity,profile,events):
			return
		_move_pursuing_enemy(state,entity,movement_targets)
		return
	if entity.action_state == "windup" and tick >= int(entity.action_ends_tick):
		var action := "airborne" if entity.attack_kind == "leap" else "attack"
		var duration := int(profile.airborne_ticks) if action == "airborne" else int(profile.active_ticks)
		_set_action(entity,action,tick,duration)
	if entity.action_state == "airborne":
		if tick >= int(entity.action_ends_tick):
			entity.position = entity.locked_target.duplicate()
			_set_action(entity,"attack",tick,int(profile.active_ticks))
		else:
			var weight := float(tick-int(entity.action_started_tick))/float(profile.airborne_ticks)
			var next_position := _vec(entity.locked_origin).lerp(_vec(entity.locked_target),weight)
			entity.velocity = _array((next_position-_vec(entity.position))*TICKS_PER_SECOND)
			entity.position = _array(next_position)
			return
	if entity.enemy_id == FINAL_ENEMY_ID and entity.action_state in ["attack","brake","recover"]:
		_advance_final_charge(state,entity,profile,events)
		return
	if entity.action_state == "attack":
		if tick >= int(entity.action_ends_tick):
			_set_action(entity,"recover",tick,int(profile.recovery_ticks))
		elif entity.attack_kind in ["charge","grab"]:
			entity.velocity = _array(_vec(entity.locked_direction)*float(profile.rush_speed))
			entity.position = _array(_move_world(state,_vec(entity.position),_vec(entity.velocity)/TICKS_PER_SECOND,float(entity.radius),true))
			return
	if entity.action_state == "recover" and tick >= int(entity.action_ends_tick):
		_set_action(entity,"move",tick,0)
		entity.next_action_tick = tick+int(profile.cooldown_ticks)
	entity.velocity = [0.0,0.0]
func _advance_final_charge(state: Dictionary, entity: Dictionary, profile: Dictionary, events: Array[Dictionary]) -> void:
	var tick := int(state.active_tick)
	if entity.action_state == "attack":
		if tick >= int(entity.action_ends_tick):
			_stop_final_charge(state,entity,profile)
		else:
			var previous := _vec(entity.position)
			var direction := _vec(entity.locked_direction)
			var speed := _final_charge_speed(profile,tick-int(entity.action_started_tick))
			var delta := direction*speed/TICKS_PER_SECOND
			var sweep := _final_contact_sweep(state,previous,delta,direction,profile,_streamed)
			if not sweep.get("ok",false): return
			var position: Vector2 = sweep.position
			entity.position = _array(position)
			entity.velocity = _array((position-previous)*TICKS_PER_SECOND)
			var shoulder := previous+direction*float(profile.shoulder_forward)
			_final_sweeps.append({"source_id":str(entity.id),"shape":"line","origin":_array(shoulder),"direction":entity.locked_direction.duplicate(),"length":previous.distance_to(position),"width":float(profile.shoulder_radius)*2.0,"damage":float(entity.damage),"tick":tick,"pattern_index":int(entity.pattern_index),"contact":sweep.contact.duplicate(true)})
			if sweep.stopped:
				# This successful-tick input shares the collision transaction. Capture
				# the charge epoch before brake replaces action_started_tick.
				if sweep.contact.get("shape","") == "shoulder_circle":
					_emit(state,events,"final_charge_contact",{"source_id":str(entity.id),"pattern_index":int(entity.pattern_index),"attack_started_tick":int(entity.action_started_tick),"origin_revision":int(state.get("world",{}).get("origin_revision",0)),"root_position":entity.position.duplicate(),"locked_direction":entity.locked_direction.duplicate(),"shape":"shoulder_circle","shape_id":str(sweep.contact.shape_id),"prop_id":str(sweep.contact.get("prop_id","")),"point":_array(sweep.contact.point),"center":_array(sweep.contact.center),"normal":_array(sweep.contact.normal),"fraction":float(sweep.contact.fraction)})
				_stop_final_charge(state,entity,profile)
				if not str(sweep.contact.get("prop_id","")).is_empty(): _strike_final_structure(state,entity,profile,sweep.contact,events)
			return
	if entity.action_state == "brake" and tick >= int(entity.action_ends_tick): _set_action(entity,"recover",tick,int(profile.recovery_ticks))
	if entity.action_state == "recover" and tick >= int(entity.action_ends_tick):
		_set_action(entity,"move",tick,0)
		entity.next_action_tick = tick+int(profile.cooldown_ticks)
	entity.velocity = [0.0,0.0]
func _strike_final_structure(state: Dictionary, entity: Dictionary, profile: Dictionary, contact: Dictionary, events: Array[Dictionary]) -> void:
	if contact.get("shape","") != "shoulder_circle" or not contact.get("point") is Vector2: return
	var prop_id: String = contact.prop_id
	var attack_id := "final-impact:%s:%d"%[str(entity.id),int(entity.pattern_index)]
	if attack_id in state.command_ids_applied: return
	var actor := {"source_team":"titan","structure_capable":true,"cancelled":false,"position":_array(contact.point)}
	var rules := {"warning_ticks":int(profile.warning_ticks),"recovery_ticks":int(profile.brake_ticks)+int(profile.recovery_ticks),"structure_damage":int(profile.structure_damage),"structure_reach":int(profile.structure_reach),"structure_admission_interval_ticks":int(profile.structure_admission_interval_ticks),"max_structure_attacks":int(profile.max_structure_attacks)}
	var budget := {"remaining_strong_slots":1,"in_flight":0,"next_admit_tick":int(state.world.next_structure_strike_tick)}
	var admitted: Dictionary = _streamed.structure_candidate_proposal(state,actor,prop_id,rules,budget)
	if not admitted.get("ok",false):
		if not admitted.get("error_code","") in ["not_destructible","structure_budget","out_of_reach"]: _streamed._query_result(admitted)
		_emit(state,events,"final_structure_stopped",{"entity_id":entity.id,"prop_id":prop_id,"reason":admitted.get("error_code","")})
		return
	# Admission reserves the existing global structural budget. This impact is
	# the already-warned physical shoulder action, not a second future attack.
	# Its single reached prop and current active tick bound damage exactly.
	var attack := {"kind":"structure_strike","source_team":"titan","cancelled":false,"attack_instance_id":attack_id,"target_prop_id":prop_id,"hit_target_ids":[],"active_from_tick":int(state.active_tick),"expires_tick":int(state.active_tick),"structure_damage":int(profile.structure_damage)}
	var reached := {"prop_id":prop_id,"reached":true,"tick":int(state.active_tick),"fraction":float(contact.fraction)}
	var proposal: Dictionary = _streamed.destruction_proposal(state,attack,reached)
	if not proposal.get("ok",false):
		_streamed._query_result(proposal)
		return
	var next_world: Dictionary = proposal.world
	next_world.next_structure_strike_tick = admitted.world.next_structure_strike_tick
	# A fresh geometry helper must not erase an earlier failure in this tick.
	# Leave the failed batch attached so the outer transaction rolls back.
	if not _streamed.query_status().get("ok",false): return
	state.world = next_world
	var next = _streamed.fresh()
	var ready: Dictionary = next.prepare(state,_streamed._hydration)
	if not ready.get("ok",false):
		_streamed._query_result(ready)
		return
	_streamed = next
	_claim_id(state.command_ids_applied,attack_id)
	var payload: Dictionary = proposal.event.duplicate(true)
	var type: String = payload.type
	payload.erase("type")
	payload.position = entity.position.duplicate()
	_emit(state,events,type,payload)
func _final_contact_shapes(state: Dictionary, origin: Vector2, end: Vector2, radius: float, helper, finite_override: Dictionary = {}) -> Dictionary:
	var shapes := []
	if finite_override.is_empty() and state.has("world") and state.world.stage == "city":
		if helper == null: return _failure("world_not_ready")
		var query: Dictionary = helper.props_query(Streamed.segment_rect(origin,end,radius))
		if not query.get("ok",false): return query
		for prop in query.props:
			if (int(prop.collision_mask)&3) != 0: shapes.append({"id":prop.prop_id,"prop_id":prop.prop_id,"rect":prop.ground_footprint})
		return {"ok":true,"shapes":shapes,"bounds":null}
	var world := finite_override if not finite_override.is_empty() else _finite_geometry(state)
	if world.is_empty(): return {"ok":true,"shapes":[],"bounds":null}
	for index in world.obstacles.size(): shapes.append({"id":"finite:%d"%index,"rect":World._rect(world.obstacles[index])})
	return {"ok":true,"shapes":shapes,"bounds":World._rect(world.bounds)}
func _final_contact_ready(state: Dictionary, root: Vector2, direction: Vector2, profile: Dictionary, helper, finite_override: Dictionary = {}) -> Dictionary:
	# Non-damaging space for the baked warning pose, including its connector.
	# Only admission/restore/spawn/handoff use this; actual contact stays below.
	var preparation := root+direction*float(profile.preparation_forward)
	var shapes := _final_contact_shapes(state,root,preparation,float(profile.shoulder_radius),helper,finite_override)
	if not shapes.get("ok",false): return shapes
	return {"ok":true,"clear":ArmoredContact.clear(root,preparation,float(profile.shoulder_radius),shapes.shapes,shapes.bounds)}
func _final_contact_sweep(state: Dictionary, root: Vector2, delta: Vector2, direction: Vector2, profile: Dictionary, helper, finite_override: Dictionary = {}) -> Dictionary:
	var body: Dictionary
	if finite_override.is_empty() and state.has("world") and state.world.stage == "city":
		if helper == null: return _failure("world_not_ready")
		body = helper.sweep(root,delta,32.0)
	else:
		var world := finite_override if not finite_override.is_empty() else _finite_geometry(state)
		body = {"ok":true,"position":World.sweep(root,delta,32.0,world),"fraction":World._travel_fraction(root,delta,32.0,world)}
	if not body.get("ok",false): return body
	var shoulder := root+direction*float(profile.shoulder_forward)
	var shapes := _final_contact_shapes(state,shoulder,shoulder+delta,float(profile.shoulder_radius),helper,finite_override)
	if not shapes.get("ok",false): return shapes
	var probe := ArmoredContact.trace(shoulder,delta,float(profile.shoulder_radius),shapes.shapes,shapes.bounds)
	return ArmoredContact.combine(root,delta,body,probe)
func _final_charge_speed(profile: Dictionary, age: int) -> float:
	return lerpf(float(profile.rush_start_speed),float(profile.rush_speed),float(age)/maxf(1.0,float(profile.active_ticks)-1.0))
func _stop_final_charge(state: Dictionary, entity: Dictionary, profile: Dictionary) -> void:
	# A new stationary action anchors the already-swept stop, including impacts.
	# Existing saved position, locked origin and phase clocks fully describe it.
	entity.locked_origin = entity.position.duplicate()
	_set_action(entity,"brake",int(state.active_tick),int(profile.brake_ticks))
	state.telegraphs = state.telegraphs.filter(func(h): return not (h.get("behavior_attack",false) and str(h.source_id) == str(entity.id)))
func _final_actor_record(state: Dictionary) -> Dictionary:
	var result := {}
	for entity in state.get("entities",[]):
		if entity.get("enemy_id") != FINAL_ENEMY_ID: continue
		if not result.is_empty(): return {}
		result = {"entity":entity,"parked":false}
	if state.get("world") is Dictionary and state.world.get("schema_version") == 2:
		for entry in state.world.dormant.entities:
			if entry.record.get("enemy_id") != FINAL_ENEMY_ID: continue
			if not result.is_empty(): return {}
			result = {"entity":entry.record,"parked":true}
	return result
func final_actor_transition_ready(state: Dictionary) -> bool:
	if state.get("phase") != "evacuation": return false
	var record := _final_actor_record(state)
	if record.is_empty() or record.entity.get("boss_id") != FINAL_BOSS_ID: return false
	if record.parked or record.entity.get("action_state") == "move": return Population.quiescent(state,record.entity)
	return record.entity.get("action_state") in ["windup","brake","recover"]
func final_actor_handoff(state: Dictionary, dock_definition: Dictionary) -> Dictionary:
	# Pure scenario DTO. The caller appends these copies to its private atomic
	# scene/save candidate only after retiring ordinary city actors and attacks.
	if not final_actor_transition_ready(state): return _failure("final_actor_busy")
	if not state.get("world") is Dictionary or state.world.get("stage") != "city" or _streamed == null: return _failure("world_not_ready")
	if not _same_json(dock_definition,_chapter.get("authored_dock",{})) or not Streamed._dock_valid(dock_definition) or not _position_valid(dock_definition.get("final_actor_entry_position")): return _failure("invalid_dock_definition")
	var record := _final_actor_record(state)
	var original: Dictionary = record.entity
	if not _entity_definition_valid(state,original,_chapter) or not _behavior_state_valid(state,original,_streamed): return _failure("invalid_core_state")
	var anchor := _vec(dock_definition.final_actor_entry_position)
	var player := _vec(dock_definition.entry_position)
	var geometry: Dictionary = dock_definition.geometry
	var radius := float(original.radius)
	if not World.walkable(anchor,radius,geometry) or not World.walkable(player,float(state.player.radius),geometry) or anchor.distance_to(player) <= radius+float(state.player.radius): return _failure("blocked_final_entry")
	var profile: Dictionary = Behaviors.profile(original,state.rules.enemy_catalog)
	# Only a live warning owns an activated probe and immutable heading.
	# Move/parked/brake/recover are non-damaging; their old axis is inactive.
	# The next ordinary warning must pass full preflight at its actual heading.
	if original.action_state == "windup":
		var first_delta := _vec(original.locked_direction)*_final_charge_speed(profile,0)/TICKS_PER_SECOND
		var ready := _final_contact_ready(state,anchor,_vec(original.locked_direction),profile,null,geometry)
		if not ready.get("ok",false) or not ready.clear: return _failure("blocked_final_entry")
		var next := _final_contact_sweep(state,anchor,first_delta,_vec(original.locked_direction),profile,null,geometry)
		var shoulder := anchor+_vec(original.locked_direction)*float(profile.shoulder_forward)
		var sweep := {"shape":"line","origin":_array(shoulder),"direction":original.locked_direction,"length":first_delta.length(),"width":float(profile.shoulder_radius)*2.0}
		if not next.get("ok",false) or next.stopped or Geometry.overlaps(sweep,player,float(state.player.radius)): return _failure("blocked_final_entry")
	var exit_rect: Array = dock_definition.escape_rect
	var exit_point := Vector2(float(exit_rect[0])+float(exit_rect[2])*0.5,float(exit_rect[1])+float(exit_rect[3])*0.5)
	if World.sweep(player,exit_point-player,float(state.player.radius),geometry).distance_to(exit_point) > 0.001: return _failure("blocked_escape_route")
	var entity: Dictionary = original.duplicate(true)
	var offset := anchor-_vec(original.position)
	entity.position = _array(anchor)
	entity.locked_origin = _array(_vec(original.locked_origin)+offset)
	entity.locked_target = _array(_vec(original.locked_target)+offset)
	if original.action_state == "move":
		# Move has no remaining attack phase. Its old inactive anchors are not
		# scenery/targets in the dock; the next real tick begins a fresh warning.
		entity.locked_origin = entity.position.duplicate()
		entity.locked_target = _array(player)
	entity.velocity = [0.0,0.0]
	var carried := []
	for hazard in state.telegraphs:
		if not hazard.get("behavior_attack",false) or str(hazard.source_id) != str(entity.id): continue
		var copy: Dictionary = hazard.duplicate(true)
		copy.origin = _array(_vec(copy.origin)+offset)
		carried.append(copy)
	return {"ok":true,"entity":entity,"telegraphs":carried}
func _set_action(entity: Dictionary, action: String, tick: int, duration: int) -> void:
	entity.action_state = action
	entity.action_started_tick = tick
	entity.action_ends_tick = tick+duration
	entity.velocity = [0.0,0.0]
func _legacy_role_slot_available(state: Dictionary, _entity: Dictionary) -> bool:
	# A legacy windup consumes the same two slots observed by RoleBudget.
	# Never cancel an admitted attack, and never count its hazard and body twice.
	if state.phase != "survival": return true
	var role_present := false
	for actor in state.entities:
		if _is_live_role(actor) and actor.hp > 0: role_present = true; break
	if not role_present: return true
	var tick := int(state.active_tick)
	var used := 0
	var sources := {}
	for attack in state.enemy_attack_instances:
		if int(attack.attack_ends_tick) <= tick: continue
		sources[str(attack.source_id)] = true
		used += int(attack.profile.threat_cost)
	for hazard in state.telegraphs:
		var source := str(hazard.source_id)
		if int(hazard.expires_tick) <= tick or sources.has(source): continue
		sources[source] = true
		used += 2
	if used+2 > (2 if int(state.survival_tick) < 10800 else 3): return false
	# One shared 30/120-tick opportunity drains legacy-first reservations.
	# A role that cannot find a safe path cannot freeze legacy attacks forever.
	for waiting in state.entities:
		if not _is_live_role(waiting) or waiting.hp <= 0 or waiting.get("action_state") != "move": continue
		var since := int(waiting.get("role_wait_since",-1))
		if since >= 0 and tick-since >= 60 and tick%120 < 30: return false
	return true
func _start_enemy_action(state: Dictionary, entity: Dictionary, profile: Dictionary, events: Array[Dictionary]) -> bool:
	if not _legacy_role_slot_available(state,entity): return false
	# Reserve the command/hazard identity before mutating the actor windup.
	# Capacity refusal defers this action while ordinary chase can continue.
	var hazard_limit := 512 if state.has("world") else 1024
	var behavior_command_id := "behavior:%s:%d"%[str(entity.id),int(entity.pattern_index)+1]
	var identity_unavailable: bool = behavior_command_id.length() > 128 or behavior_command_id in state.command_ids_applied
	if identity_unavailable or state.command_ids_applied.size() >= 16384 or state.telegraphs.size() >= hazard_limit or int(state.next_entity_id) >= MAX_COUNTER or int(entity.pattern_index) >= MAX_COUNTER:
		if state.has("world"):
			_tick_navigation.deferred_attacks += 1
			_tick_navigation.actors.append({"entity_id":str(entity.id),"reason":"attack_admission_identity" if identity_unavailable else "attack_admission_capacity"})
		return false
	var target := _nearest_world(state,_vec(state.player.position),float(entity.radius)) if profile.kind == "leap" else _vec(state.player.position)
	if not is_finite(target.x) or not is_finite(target.y): return false
	var direction := _vec(entity.position).direction_to(target)
	if direction.is_zero_approx(): direction = _vec(entity.facing)
	if entity.enemy_id == FINAL_ENEMY_ID:
		var ready := _final_contact_ready(state,_vec(entity.position),direction,profile,_streamed)
		if not ready.get("ok",false) or not ready.clear: return false
	entity.attack_kind = profile.kind
	entity.pattern_index = int(entity.pattern_index)+1
	entity.locked_origin = entity.position.duplicate()
	entity.locked_direction = _array(direction)
	entity.locked_target = _array(target)
	entity.facing = _array(direction)
	_set_action(entity,"windup",int(state.active_tick),int(profile.warning_ticks))
	var leap: bool = profile.kind == "leap"
	var shape := "circle" if profile.kind in ["slam","leap"] else ("sector" if profile.kind == "sweep" else "line")
	var warning := int(profile.warning_ticks)+int(profile.get("airborne_ticks",0))
	var payload := {"source_id":str(entity.id),"shape":shape,"origin":entity.locked_target.duplicate() if leap else entity.locked_origin.duplicate(),"direction":entity.locked_direction.duplicate(),"radius":float(profile.get("radius",1.0)),"length":float(profile.get("length",1.0)),"width":maxf(float(profile.get("width",1.0)),float(entity.radius)*2.0),"arc_degrees":float(profile.get("arc_degrees",90.0)),"warning_ticks":warning,"active_ticks":int(profile.active_ticks),"damage":float(entity.damage),"behavior_attack":true}
	var command := {"command_id":behavior_command_id,"kind":"telegraph_attack","payload":payload}
	if state.has("world"): command.origin_revision = state.world.origin_revision
	_apply_command(state,command,events,true)
	return true
func _auto_attack(state: Dictionary, events: Array[Dictionary], _boss_rewards: Array[Dictionary]) -> void:
	var item_ids: Array[String] = []
	for key in state.equipment: item_ids.append(str(key))
	item_ids.sort()
	var projectile_reservations: int = state.projectiles.size()
	for original_id in item_ids:
		var item_id: String = str(original_id)
		if int(state.player.attack_ready_ticks.get(item_id,0)) > int(state.active_tick) or state.attack_seq >= MAX_COUNTER: continue
		var definition: Dictionary = _catalog.equipment[item_id]
		var stats: Dictionary = _catalog.weapon_stats(state,item_id,int(state.equipment[item_id]))
		var evolution: String = state.evolutions.get(item_id,"")
		var detail: Dictionary = _catalog.evolutions.evaluate(state,evolution) if not evolution.is_empty() else {}
		if not evolution.is_empty() and detail.get("status") != "evolved": continue
		if definition.mode == "chain":
			_cast_chain(state,stats if evolution.is_empty() else detail.effect_delta,item_id,events)
			continue
		var radius: float = stats.range if evolution.is_empty() else detail.effect_delta.get("acquisition_range",detail.effect_delta.radius)
		var targets: Array[int] = _spatial.query(_vec(state.player.position),radius+48.0)
		var target_index := -1
		var nearest := radius+48.0
		for index in targets:
			var entity: Dictionary = state.entities[index]
			if entity.hp <= 0.0: continue
			var distance := _vec(entity.position).distance_to(_vec(state.player.position))
			if distance <= radius+float(entity.radius) and distance < nearest:
				var mask := 16 if evolution == "evo_crossfire" else (8 if definition.mode == "projectile" else 4)
				var visible := _fantasy_cover_clear(state,_vec(state.player.position),_vec(entity.position)) if definition.mode == "zone" else _cover_clear(state,_vec(state.player.position),_vec(entity.position),0,mask)
				if not visible: continue
				nearest = distance
				target_index = index
		if target_index < 0: continue
		var direction := _vec(state.player.position).direction_to(_vec(state.entities[target_index].position))
		if direction.is_zero_approx(): direction = _vec(state.player.facing)
		var count := 1 if evolution.is_empty() else int(detail.effect_delta.stages)
		if definition.mode != "zone" and state.player_attack_instances.size()+count > 64: continue
		if evolution.is_empty() and definition.mode == "projectile" and projectile_reservations >= MAX_PROJECTILES: continue
		var cast_id: String = state.run_id+":attack:"+str(int(state.attack_seq)+1)
		var records: Array = []
		var cooldown: int = int(stats.cooldown_ticks)
		if definition.mode == "zone":
			records = Fantasy.fire_records(state,_catalog,_vec(state.entities[target_index].position),direction,cast_id)
			if records.is_empty(): continue
			if not evolution.is_empty(): cooldown = int(detail.effect_delta.cooldown_ticks)
			if not _fantasy_capacity(state,item_id,records.size(),events): continue
		elif not evolution.is_empty():
			var proposal: Dictionary = _evolved.reserve(state,item_id,_vec(state.entities[target_index].position),direction,cast_id)
			if not proposal.get("ok",false): continue
			records = proposal.records
			cooldown = int(proposal.cooldown_ticks)
		else:
			var shape: String = "circle" if definition.mode == "combo" else definition.mode
			var record := {"attack_id":cast_id+":0","cast_id":cast_id,"base_item_id":item_id,"evolution_id":"","attack_started_tick":int(state.active_tick),"execute_tick":int(state.active_tick),"stage_index":0,"stage_count":1,"origin_binding":"fixed","origin":state.player.position.duplicate(),"direction":_array(direction),"shape":shape,"radius":radius,"arc_degrees":float(stats.get("arc_degrees",360.0)),"damage":float(stats.damage),"hit_entity_ids":[],"pose_tag":"artillery_command" if item_id == "wall_cannon" else item_id}
			if definition.mode == "line": record.merge({"length":radius,"width":float(stats.width)})
			if definition.mode == "combo":
				record.damage *= int(definition.hits)
				record.target_id = str(state.entities[target_index].id)
			if definition.mode == "projectile": record.merge({"radius":4.0,"range":radius+48.0,"projectile_speed":float(stats.projectile_speed),"splash_radius":float(stats.splash_radius)},true)
			records.append(record)
		if int(state.active_tick)+cooldown > MAX_COUNTER: continue
		if evolution.is_empty() and definition.mode == "projectile": projectile_reservations += 1
		state.attack_seq = int(state.attack_seq)+1
		state.player.attack_ready_ticks[item_id] = int(state.active_tick)+cooldown
		for record in records:
			state.player_attack_instances.append(record)
			if not evolution.is_empty() or definition.mode == "zone": _emit(state,events,"player_attack",_attack_payload(record,"scheduled"))
func _cast_chain(state: Dictionary, stats: Dictionary, item_id: String, events: Array[Dictionary]) -> void:
	var cast_id: String = state.run_id+":attack:"+str(int(state.attack_seq)+1)
	var query := func(point: Vector2, radius: float): return _spatial.query(point,radius)
	var clear := func(from: Vector2, to: Vector2): return _fantasy_cover_clear(state,from,to)
	var records: Array = Fantasy.chain_records(state,stats,item_id,cast_id,query,clear)
	if records.is_empty(): return
	if int(state.active_tick)+int(stats.cooldown_ticks) > MAX_COUNTER: return
	if not _fantasy_capacity(state,item_id,records.size(),events): return
	state.attack_seq = int(state.attack_seq)+1
	state.player.attack_ready_ticks[item_id] = int(state.active_tick)+int(stats.cooldown_ticks)
	state.player_attack_instances.append_array(records)
func _fantasy_cover_clear(state: Dictionary, origin: Vector2, target: Vector2) -> bool:
	if state.has("world"): return _cover_clear(state,origin,target,0,4)
	# Historical finite attacks retain their old cover contract. New families
	# use the actual finite collision footprint rather than passing through it.
	return World.sweep(origin,target-origin,0,_finite_geometry(state)).distance_to(target) <= 0.001
func _legacy_attack_state(state: Dictionary) -> Dictionary:
	var legacy := state.duplicate()
	legacy.player_attack_instances = state.player_attack_instances.filter(func(record): return not record is Dictionary or (not Fantasy.is_fantasy(record) and not Signature.is_signature(record)))
	return legacy
func _auto_signature(state: Dictionary, events: Array[Dictionary]) -> void:
	if not state.has("character_skill"): return
	var runtime: Dictionary = state.character_skill
	var tick := int(state.active_tick)
	if tick < int(runtime.next_probe_tick) or tick < int(runtime.ready_tick) or not str(runtime.pending_cast_id).is_empty(): return
	if tick > MAX_COUNTER-Signature.COOLDOWN or state.attack_seq >= MAX_COUNTER or state.event_seq > MAX_COUNTER-5: return
	runtime.next_probe_tick = mini(MAX_COUNTER,tick+Signature.PROBE_INTERVAL)
	if state.player_attack_instances.size()+3 > 64: return
	var query := func(point: Vector2, radius: float): return _spatial.query(point,radius)
	var clear := func(from: Vector2, to: Vector2): return _fantasy_cover_clear(state,from,to)
	var target: int = _signature.choose_target(state,query,clear)
	if target < 0: return
	var direction := _vec(state.player.position).direction_to(_vec(state.entities[target].position))
	if direction.is_zero_approx(): direction = _vec(state.player.facing)
	var cast: String = state.run_id+":attack:"+str(int(state.attack_seq)+1)
	var proposal: Dictionary = _signature.reserve(state,str(state.entities[target].id),direction,cast)
	if not proposal.get("ok",false): return
	state.attack_seq = int(state.attack_seq)+1
	runtime.ready_tick = tick+Signature.COOLDOWN
	runtime.next_probe_tick = runtime.ready_tick
	runtime.pending_cast_id = cast
	for record in proposal.records:
		state.player_attack_instances.append(record)
		_emit(state,events,"player_attack",_attack_payload(record,"scheduled"))
func _fantasy_capacity(state: Dictionary, item_id: String, count: int, events: Array[Dictionary]) -> bool:
	var casts := {}
	var next_release := MAX_COUNTER
	for record in state.player_attack_instances:
		next_release = mini(next_release,int(record.execute_tick))
		if record.base_item_id == "fire_zone": casts[record.cast_id] = maxi(int(casts.get(record.cast_id,0)),int(record.execute_tick))
	var fields_full: bool = item_id == "fire_zone" and casts.size() >= 2
	if state.player_attack_instances.size()+count <= 64 and not fields_full: return true
	if fields_full:
		next_release = MAX_COUNTER
		for tick in casts.values(): next_release = mini(next_release,int(tick))
	var retry_tick := mini(MAX_COUNTER,maxi(int(state.active_tick)+1,next_release+1))
	state.player.attack_ready_ticks[item_id] = retry_tick
	_emit(state,events,"player_attack_deferred",{"base_item_id":item_id,"reason":"field_capacity" if fields_full else "attack_capacity","retry_tick":retry_tick})
	return false
func _attack_payload(record: Dictionary, phase: String) -> Dictionary:
	var result := record.duplicate(true)
	result.phase = phase
	var geometry := {"shape":record.shape,"origin":record.origin.duplicate(),"direction":record.direction.duplicate(),"radius":float(record.radius),"arc_degrees":float(record.arc_degrees)}
	for field in ["length","width","projectile_id","target_id"]:
		if field == "target_id" and Signature.is_signature(record): continue
		if record.has(field): geometry[field] = record[field]
	result.geometry = geometry
	return result
func _execute_player_attacks(state: Dictionary, events: Array[Dictionary], boss_rewards: Array[Dictionary]) -> void:
	state.player_attack_instances.sort_custom(func(a,b): return int(a.execute_tick) < int(b.execute_tick) if a.execute_tick != b.execute_tick else str(a.attack_id) < str(b.attack_id))
	var pending: Array = []
	for saved in state.player_attack_instances:
		if int(saved.execute_tick) > int(state.active_tick):
			pending.append(saved)
			continue
		var record: Dictionary = saved.duplicate(true)
		if record.origin_binding == "player": record.origin = state.player.position.duplicate()
		if record.shape == "projectile":
			var id := _new_id(state)
			record.projectile_id = id
			state.projectiles.append({"id":id,"item_id":record.base_item_id,"attack_id":record.attack_id,"cast_id":record.cast_id,"position":record.origin.duplicate(),"velocity":_array(_vec(record.direction)*float(record.projectile_speed)),"damage":float(record.damage),"splash_radius":float(record.splash_radius),"remaining_distance":float(record.range),"radius":float(record.radius)})
		_emit(state,events,"player_attack",_attack_payload(record,"executed"))
		if record.shape == "projectile": continue
		var radius: float = maxf(float(record.radius),float(record.get("length",0.0)))+48.0
		for index in _spatial.query(_vec(record.origin),radius):
			var entity: Dictionary = state.entities[index]
			var id := str(entity.id)
			if entity.hp <= 0.0 or id in record.hit_entity_ids: continue
			if record.has("target_id") and record.target_id != id: continue
			if not Geometry.overlaps(record,_vec(entity.position),float(entity.radius)): continue
			var visible := _fantasy_cover_clear(state,_vec(record.origin),_vec(entity.position)) if Fantasy.is_fantasy(record) or Signature.is_signature(record) else _cover_clear(state,_vec(record.origin),_vec(entity.position),0,16 if record.evolution_id == "evo_crossfire" else 4)
			if visible:
				record.hit_entity_ids.append(id)
				_hit_entity(state,entity,float(record.damage),record.base_item_id,events,boss_rewards,record.attack_id)
	state.player_attack_instances = pending
	if state.has("character_skill") and not str(state.character_skill.pending_cast_id).is_empty():
		var still_pending := false
		for record in pending:
			if Signature.is_signature(record): still_pending = true; break
		if not still_pending: state.character_skill.pending_cast_id = ""
func _advance_projectiles(state: Dictionary, events: Array[Dictionary], boss_rewards: Array[Dictionary], existing: Dictionary) -> void:
	var kept: Array = []
	for projectile in state.projectiles:
		if not existing.has(str(projectile.id)):
			kept.append(projectile)
			continue
		var previous := _vec(projectile.position)
		var displacement := _vec(projectile.velocity)/TICKS_PER_SECOND
		var cover := _cover_world(state,previous,previous+displacement,float(projectile.radius),8)
		var blocked: bool = cover.get("ok",false) and float(cover.get("fraction",1.0)) < 1.0
		var travel: Vector2 = displacement*float(cover.get("fraction",0.0))
		projectile.position = _array(previous+travel)
		projectile.remaining_distance = float(projectile.remaining_distance)-displacement.length()
		var hit := false
		var segment := {"shape":"line","origin":_array(previous),"direction":_array(displacement.normalized()),"length":travel.length(),"width":float(projectile.radius)*2.0}
		for index in _spatial.query(previous,displacement.length()+48.0):
			var entity: Dictionary = state.entities[index]
			if entity.hp <= 0.0 or not Geometry.overlaps(segment,_vec(entity.position),float(entity.radius)): continue
			hit = true
			var impact := _vec(entity.position)
			_emit(state,events,"projectile_impact",{"projectile_id":projectile.id,"attack_id":projectile.attack_id,"base_item_id":projectile.item_id,"position":_array(impact),"radius":projectile.splash_radius})
			if float(projectile.splash_radius) > 0.0:
				for splash_index in _spatial.query(impact,float(projectile.splash_radius)+48.0):
					var splash_target: Dictionary = state.entities[splash_index]
					if _vec(splash_target.position).distance_to(impact) <= float(projectile.splash_radius)+float(splash_target.radius) and _cover_clear(state,impact,_vec(splash_target.position),0,4):
						_hit_entity(state,splash_target,float(projectile.damage),str(projectile.item_id),events,boss_rewards,str(projectile.attack_id))
			else: _hit_entity(state,entity,float(projectile.damage),str(projectile.item_id),events,boss_rewards,str(projectile.attack_id))
			break
		if blocked and not hit:
			_emit(state,events,"projectile_impact",{"projectile_id":projectile.id,"attack_id":projectile.attack_id,"base_item_id":projectile.item_id,"position":projectile.position.duplicate(),"radius":projectile.splash_radius})
		if not hit and not blocked and projectile.remaining_distance > 0.0: kept.append(projectile)
	state.projectiles = kept
func _hit_entity(state: Dictionary, entity: Dictionary, damage: float, source: String, events: Array[Dictionary], boss_rewards: Array[Dictionary], attack_id: String = "") -> void:
	if entity.hp <= 0.0: return
	if entity.enemy_id == FINAL_ENEMY_ID:
		_emit(state,events,"armor_blocked",{"target_id":entity.id,"source_id":source,"attack_id":attack_id,"base_item_id":source,"amount":0.0})
		return
	var amount := minf(float(entity.hp),damage)
	entity.hp = maxf(0.0,float(entity.hp)-damage)
	state.stats.damage_dealt = float(state.stats.damage_dealt)+amount
	_emit(state,events,"damage",{"target_id":entity.id,"source_id":source,"amount":amount,"hp":entity.hp,"attack_id":attack_id,"base_item_id":source,"position":entity.position.duplicate()})
	if entity.hp > 0.0: return
	state.stats.kills = int(state.stats.kills)+1
	_add_drop(state,entity.position,int(entity.xp))
	if not str(entity.boss_id).is_empty():
		var reward := {"boss_id":entity.boss_id,"entity_id":entity.id}
		if Loot.enabled(state): reward.position = entity.position.duplicate()
		boss_rewards.append(reward)
func _remove_dead(state: Dictionary) -> void:
	var alive: Array = []
	var defeated: Array[String] = []
	for entity in state.entities:
		if entity.hp > 0.0: alive.append(entity)
		else: defeated.append(str(entity.id))
	state.entities = alive
	if not defeated.is_empty():
		var remaining: Array = []
		for hazard in state.telegraphs:
			if hazard.get("behavior_attack",false) and str(hazard.source_id) in defeated: continue
			remaining.append(hazard)
		state.telegraphs = remaining
		state.enemy_attack_instances = state.enemy_attack_instances.filter(func(attack): return not str(attack.source_id) in defeated)
		for source in defeated: _role_samples.erase(source)
func _add_drop(state: Dictionary, position: Array, xp: int) -> void:
	if xp <= 0: return
	if state.has("world") and state.world.get("schema_version") == 2:
		var target := Population.drop_target(state,position)
		if not target.get("ok",false):
			_streamed._query_result(target)
			return
		if target.kind == "append": state.drops.append({"id":_new_id(state),"position":position.duplicate(),"xp":xp})
		elif target.kind == "active": state.drops[target.index].xp = int(state.drops[target.index].xp)+xp
		else:
			# Tick candidates normally share world authority. Detach before mutation;
			# dormant data is deliberately absent from derived terrain identity.
			state.world = state.world.duplicate(true)
			state.world.dormant.drops[target.index].record.xp = int(state.world.dormant.drops[target.index].record.xp)+xp
		return
	var point := _vec(position)
	var cell := Vector2i(floor(point.x/16.0),floor(point.y/16.0))
	for drop in state.drops:
		var existing := _vec(drop.position)
		if Vector2i(floor(existing.x/16.0),floor(existing.y/16.0)) == cell:
			drop.xp = int(drop.xp)+xp
			return
	if state.drops.size() >= MAX_DROPS:
		var nearest: Dictionary = state.drops[0]
		var best_distance := point.distance_squared_to(_vec(nearest.position))
		for drop in state.drops:
			var distance := point.distance_squared_to(_vec(drop.position))
			if distance < best_distance:
				nearest = drop
				best_distance = distance
		nearest.xp = int(nearest.xp)+xp
		return
	state.drops.append({"id":_new_id(state),"position":position.duplicate(),"xp":xp})
func _add_loot(state: Dictionary, spec: Dictionary, anchor: Vector2) -> void:
	if spec.is_empty(): return
	var id: String = Loot.chest_id(state.run_id,spec.source,spec.source_id)
	if not Loot.find_chest(state,id).is_empty() or state.loot.chests.size() >= Loot.MAX_CHESTS: return
	var chest := {"id":id,"source":spec.source,"source_id":spec.source_id,"reward":spec.reward,"status":"pending","stage":"finite","position":[0.0,0.0],"address":{},"offer_id":"","result":""}
	if not Loot.set_position(state,chest,anchor):
		_role_error = _failure("invalid_loot_position")
		return
	state.loot.chests.append(chest)

func _loot_coverage_present(state: Dictionary, aabb: Rect2) -> bool:
	# covered() records world_not_ready on a miss. Placement probes must not
	# poison the live world's query status or generate absent terrain.
	if _streamed == null or _streamed._world == null: return false
	if _streamed._world._origin != state.world.origin_chunk: return false
	var keys: Array = _streamed._world.chunk_keys()
	var low_x := int(floor(aabb.position.x/768))
	var high_x := int(floor((aabb.end.x-0.0001 if aabb.size.x > 0 else aabb.end.x)/768))
	var low_y := int(floor(aabb.position.y/768))
	var high_y := int(floor((aabb.end.y-0.0001 if aabb.size.y > 0 else aabb.end.y)/768))
	if high_x-low_x > 8 or high_y-low_y > 8: return false
	for y in range(low_y,high_y+1):
		for x in range(low_x,high_x+1):
			var point: Dictionary = Loot.Address.normalize(state.world.origin_chunk,Vector2(x*768,y*768))
			if not point.get("ok",false) or not keys.has(Loot.Address.key(point.chunk)): return false
	return true

func _loot_path_clear(state: Dictionary, origin: Vector2, target: Vector2) -> bool:
	if origin.distance_squared_to(target) > 512.0*512.0: return false
	# A successful swept straight walking path proves same connected component.
	# Do not invoke a failing public query for a point outside resident coverage.
	if state.has("world") and state.world.stage == "city":
		if not _loot_coverage_present(state,Streamed.segment_rect(origin,target,8.0)): return false
	if not _walkable_world(state,origin,8.0) or not _walkable_world(state,target,8.0): return false
	return _move_world(state,origin,target-origin,8.0,true).distance_squared_to(target) <= 0.0001

func _update_loot(state: Dictionary, events: Array[Dictionary]) -> void:
	for index in range(Loot.FIELD_TICKS.size()):
		var spec: Dictionary = Loot.field_spec(index)
		if int(state.survival_tick) >= int(spec.due_tick):
			_add_loot(state,spec,_vec(state.player.position))
	var pending: Array = []
	for chest in state.loot.chests:
		if chest.status == "pending": pending.append(chest)
	if not pending.is_empty() and Loot.retry_due(int(state.active_tick),int(state.loot.next_retry_tick)):
		state.loot.next_retry_tick = mini(MAX_COUNTER,int(state.active_tick)+Loot.PLACEMENT_RETRY_TICKS)
		var budget: int = Loot.MAX_PLACEMENT_CANDIDATES
		# Rotate the first pending source so one blocked chest cannot starve others.
		var first: int = int(state.active_tick/Loot.PLACEMENT_RETRY_TICKS)%pending.size()
		for offset in range(pending.size()):
			var chest: Dictionary = pending[(first+offset)%pending.size()]
			var anchor := _vec(state.player.position)
			if chest.source == "boss":
				var local: Dictionary = Loot.local_position(state,chest)
				if not local.get("ok",false): continue
				anchor = local.position
			for candidate_index in range(Loot.MAX_PLACEMENT_CANDIDATES):
				if budget == 0: break
				budget -= 1
				var radius := 160.0+float(candidate_index%3)*40.0 if chest.source == "field" else float(candidate_index%4)*16.0
				var point := anchor+Vector2.from_angle(TAU*float(candidate_index)/16.0)*radius
				var occupied := false
				for other in state.loot.chests:
					if other.status != "placed": continue
					var local: Dictionary = Loot.local_position(state,other)
					if local.get("ok",false) and point.distance_squared_to(local.position) < 576.0: occupied = true; break
				if occupied or not _loot_path_clear(state,_vec(state.player.position),point): continue
				if not Loot.set_position(state,chest,point): continue
				chest.status = "placed"
				break
			if budget == 0: break
	if state.has("player_mobility") and state.player_mobility.phase != "ground": return
	var pickup: float = _catalog.stat(state,"pickup_radius",float(state.rules.pickup_radius))
	# Stable creation order defines simultaneous field/boss collection order.
	for chest in state.loot.chests:
		if chest.status != "placed": continue
		var local: Dictionary = Loot.local_position(state,chest)
		if not local.get("ok",false) or local.position.distance_to(_vec(state.player.position)) > pickup: continue
		if not _loot_path_clear(state,_vec(state.player.position),local.position): continue
		if chest.reward == "skill":
			if state.pending_offers.size() >= 256 or int(state.offer_seq) >= MAX_COUNTER: continue
			_queue_offer(state,"chest")
			var descriptor: Dictionary = state.pending_offers.back()
			descriptor.chest_id = chest.id
			chest.offer_id = descriptor.offer_id
			chest.status = "queued"
		else:
			chest.status = "claimed"
			chest.result = "gold"
			state.loot.gold = int(state.loot.gold)+Loot.GOLD_PER_CHEST
		_emit(state,events,"loot_collected",{"chest_id":chest.id,"reward":chest.reward,"amount":Loot.GOLD_PER_CHEST if chest.reward == "gold" else 1})
		if Loot.potions_enabled(state) and chest.source == "field":
			state.loot.potions.append({"id":chest.id+":potion","chest_id":chest.id,"status":"placed","stage":chest.stage,"position":chest.position.duplicate(),"address":chest.address.duplicate(true),"born_tick":int(state.active_tick),"heal_amount":Loot.POTION_HEAL,"healed_amount":0.0})
			_emit(state,events,"potion_dropped",{"potion_id":chest.id+":potion","amount":1})
	_collect_potions(state,events)

func _collect_potions(state: Dictionary, events: Array[Dictionary]) -> void:
	if not Loot.potions_enabled(state) or state.phase not in ["survival","evacuation"] or float(state.player.hp) <= 0.0: return
	if state.has("player_mobility") and state.player_mobility.phase != "ground": return
	var pickup: float = _catalog.stat(state,"pickup_radius",float(state.rules.pickup_radius))
	for potion in state.loot.potions:
		if potion.status != "placed" or float(state.player.hp) >= float(state.player.max_hp): continue
		var local: Dictionary = Loot.local_position(state,potion)
		if not local.get("ok",false) or local.position.distance_squared_to(_vec(state.player.position)) > pickup*pickup: continue
		if not _loot_path_clear(state,_vec(state.player.position),local.position): continue
		var healed: float = minf(Loot.POTION_HEAL,float(state.player.max_hp)-float(state.player.hp))
		state.player.hp = float(state.player.hp)+healed
		potion.status = "claimed"
		potion.healed_amount = healed
		_emit(state,events,"potion_collected",{"potion_id":potion.id,"amount":1,"healed_amount":healed})

func transfer_loot_to_dock(state: Dictionary) -> void:
	# Called on the private dock-transition candidate, never the live authority.
	if not Loot.enabled(state): return
	for chest in state.loot.chests:
		if chest.status not in ["pending","placed"]: continue
		if chest.source == "field": chest.status = "expired"
		else:
			chest.status = "pending"
			Loot.set_position(state,chest,_vec(state.player.position))
	if Loot.potions_enabled(state):
		for potion in state.loot.potions:
			if potion.status == "placed": potion.status = "expired"
	state.loot.next_retry_tick = maxi(int(state.loot.next_retry_tick),int(state.active_tick))

func _collect_drops(state: Dictionary, events: Array[Dictionary], reserved_boss_offers: int = 0) -> void:
	var pickup := _catalog.stat(state,"pickup_radius",float(state.rules.pickup_radius))
	var drop_grid = SpatialHash.new()
	drop_grid.rebuild(state.drops)
	var collected: Array[int] = []
	var xp := 0
	for index in drop_grid.query(_vec(state.player.position),pickup):
		var drop: Dictionary = state.drops[index]
		if _vec(drop.position).distance_to(_vec(state.player.position)) <= pickup:
			collected.append(index)
			xp += int(drop.xp)
	collected.reverse()
	for index in collected: state.drops.remove_at(index)
	if xp > 0:
		state.player.xp = int(state.player.xp)+xp
		_emit(state,events,"xp_gained",{"amount":xp,"xp":state.player.xp})
	# Bound work and preserve unprocessed XP when many thresholds arrive together.
	# The next unpaused tick resumes after the current descriptor batch resolves.
	while state.pending_offers.size() < 256-reserved_boss_offers and int(state.offer_seq) < MAX_COUNTER and int(state.player.level) < MAX_COUNTER and int(state.player.xp) >= Catalog.xp_to_next(int(state.player.level),state.rules.progression):
		state.player.xp = int(state.player.xp)-Catalog.xp_to_next(int(state.player.level),state.rules.progression)
		state.player.level = int(state.player.level)+1
		_queue_offer(state,"level")
func _claim_boss_reward(state: Dictionary, reward: Dictionary, events: Array[Dictionary]) -> void:
	var boss: String = str(reward.get("boss_id",""))
	var reward_id := "boss:"+boss
	if not boss in REAL_BOSS_IDS or not boss in state.boss_ids_fired or reward_id in state.reward_ids_claimed: return
	if int(state.stats.minibosses_defeated) >= 5: return
	_claim_id(state.reward_ids_claimed,reward_id)
	state.stats.minibosses_defeated = int(state.stats.minibosses_defeated)+1
	state.tactical_seals = int(state.tactical_seals)+1
	state.player.hp = minf(float(state.player.max_hp),float(state.player.hp)+float(state.player.max_hp)*0.25)
	_emit(state,events,"boss_defeated",reward.duplicate(true))
	if Loot.enabled(state):
		_add_loot(state,Loot.boss_spec(boss),_vec(reward.get("position",state.player.position)))
	else: _queue_offer(state,"boss")
func _queue_offer(state: Dictionary, source: String) -> void:
	if int(state.offer_seq) >= MAX_COUNTER or state.pending_offers.size() >= 256: return
	state.offer_seq = int(state.offer_seq)+1
	state.pending_offers.append({"offer_id":state.run_id+":offer:"+str(int(state.offer_seq)),"source":source,"level_ordinal":int(state.player.level)})
func _activate_next_offer(state: Dictionary, events: Array[Dictionary]) -> bool:
	if not state.upgrade_offer.is_empty() or not state.phase in ["survival","evacuation"]: return true
	while not state.pending_offers.is_empty():
		var descriptor: Dictionary = state.pending_offers[0]
		var result: Dictionary = Growth.new(_catalog).materialize(state,descriptor)
		if not result.get("ok",false): return false
		state.pending_offers.pop_front()
		state.progression_rng_state = result.next_rng_state
		state.view_revision = int(state.view_revision)+1
		if result.offer.is_empty():
			if descriptor.source == "chest":
				var chest: Dictionary = Loot.find_chest(state,descriptor.chest_id)
				if chest.is_empty() or chest.status != "queued": return false
				chest.status = "claimed"
				chest.result = "gold"
				state.loot.gold = int(state.loot.gold)+Loot.GOLD_PER_CHEST
				_emit(state,events,"loot_collected",{"chest_id":chest.id,"reward":"gold","amount":Loot.GOLD_PER_CHEST,"reason":"skill_pool_empty"})
			else: state.player.hp = minf(float(state.player.max_hp),float(state.player.hp)+float(state.player.max_hp)*0.10)
			_claim_id(state.reward_ids_claimed,"offer:"+descriptor.offer_id)
			continue
		state.upgrade_offer = result.offer
		_claim_id(state.pause_reasons,"upgrade")
		_emit(state,events,"upgrade_opened",state.upgrade_offer.duplicate(true))
		return true
	state.pause_reasons.erase("upgrade")
	return true
func _player_damage(state: Dictionary, events: Array[Dictionary]) -> void:
	var kept: Array = []
	for hazard in state.telegraphs:
		if int(state.active_tick) >= int(hazard.expires_tick): continue
		kept.append(hazard)
		var final_warning := false
		for entity in state.entities:
			if entity.enemy_id == FINAL_ENEMY_ID and str(entity.id) == str(hazard.source_id): final_warning = true; break
		if final_warning: continue
		if int(state.active_tick) >= int(hazard.active_from_tick) and Geometry.overlaps(hazard,_vec(state.player.position),float(state.player.radius)) and _cover_clear(state,_vec(hazard.origin),_vec(state.player.position),0,4):
			_damage_player(state,float(hazard.damage),str(hazard.source_id),events)
	state.telegraphs = kept
	for sweep in _final_sweeps:
		if Geometry.overlaps(sweep,_vec(state.player.position),float(state.player.radius)) and _cover_clear(state,_vec(sweep.origin),_vec(state.player.position),0,4):
			_damage_player(state,float(sweep.damage),str(sweep.source_id),events)
	for entity in state.entities:
		if _is_live_role(entity): continue
		if entity.enemy_id == FINAL_ENEMY_ID and entity.get("action_state","move") in ["attack","brake","recover"]: continue
		if entity.get("action_state","move") in ["windup","airborne","recover"]: continue
		if _vec(entity.position).distance_to(_vec(state.player.position)) <= float(entity.radius)+float(state.player.radius):
			_damage_player(state,float(entity.damage),str(entity.id),events)
	_role_player_damage(state,events)
func _damage_player(state: Dictionary, damage: float, source: String, events: Array[Dictionary]) -> void:
	if state.player.hp <= 0.0 or int(state.active_tick) < int(state.player.invulnerable_until): return
	var amount := maxf(1.0,damage-_catalog.stat(state,"armor",0.0))
	amount = minf(float(state.player.hp),amount)
	state.player.hp = maxf(0.0,float(state.player.hp)-amount)
	state.player.invulnerable_until = int(state.active_tick)+30
	_emit(state,events,"damage",{"target_id":"player","source_id":source,"amount":amount,"hp":state.player.hp})
func _use_prepared_supply(state: Dictionary, events: Array[Dictionary]) -> void:
	if state.supply_used or state.run_config.prepared_supply != "field_bandage" or state.player.hp <= 0: return
	var item: Dictionary = _supplies.item("field_bandage")
	var params: Dictionary = item.effect_params
	if float(state.player.hp) > float(state.player.max_hp)*float(params.threshold_ratio): return
	var amount := minf(float(params.heal),float(state.player.max_hp)-float(state.player.hp))
	state.supply_used = true
	state.player.hp = float(state.player.hp)+amount
	_emit(state,events,"supply_used",{"run_id":state.run_id,"item_id":"field_bandage","healed_amount":amount,"remaining":0})
func _regenerate(state: Dictionary) -> void:
	state.player.hp = minf(float(state.player.max_hp),float(state.player.hp)+_catalog.stat(state,"regen_per_second",0.0)/TICKS_PER_SECOND)
func _inside_escape(state: Dictionary) -> bool:
	if state.has("world") and state.world.stage != "dock": return false
	var zone: Array = state.escape_zone
	return Rect2(float(zone[0]),float(zone[1]),float(zone[2]),float(zone[3])).has_point(_vec(state.player.position))
func _end_run(state: Dictionary, result: String, reason: String, events: Array[Dictionary]) -> void:
	if state.phase in ["won","dead","abandoned"]: return
	state.phase = result
	state.enemy_attack_instances.clear()
	_role_samples.clear()
	for entity in state.entities:
		if _is_live_role(entity):
			entity.role_hand_reach = -1.0
			entity.role_wait_since = -1
			entity.role_retry_tick = 0
			entity.action_state = "move"
			entity.attack_kind = "none"
			entity.velocity = [0.0,0.0]
			entity.action_started_tick = int(state.active_tick)
			entity.action_ends_tick = int(state.active_tick)
			entity.next_action_tick = int(state.active_tick)
	if Loot.enabled(state):
		for chest in state.loot.chests:
			if chest.status == "queued": chest.status = "expired"
	state.upgrade_offer = {}
	state.pending_offers.clear()
	state.pause_reasons.erase("upgrade")
	state.view_revision = int(state.view_revision)+1
	_emit(state,events,"run_ended",{"result":result,"reason":reason,"clear_reward":1 if result == "won" else 0,"chapter_id":state.chapter_id})
func _emit(state: Dictionary, events: Array[Dictionary], type: String, payload: Dictionary) -> void:
	state.event_seq = int(state.event_seq)+1
	events.append({"event_id":state.run_id+":"+str(int(state.event_seq)),"type":type,"tick":int(state.active_tick),"payload":payload})
func _claim_id(ids: Array, id: String) -> void:
	if not id in ids:
		ids.append(id)
		ids.sort()
func _new_id(state: Dictionary) -> int:
	var id := int(state.next_entity_id)
	state.next_entity_id = id+1
	return id
func _position_valid(value: Variant) -> bool:
	# All saved local vectors must survive real_t float32 conversion as finite.
	return value is Array and value.size() == 2 and Catalog.number_valid(value[0],-10000000.0,10000000.0) and Catalog.number_valid(value[1],-10000000.0,10000000.0)
func _rect_valid(value: Variant) -> bool:
	return value is Array and value.size() == 4 and _position_valid([value[0],value[1]]) and _position_valid([value[2],value[3]]) and float(value[2]) > 0.0 and float(value[3]) > 0.0
func _hazard_valid(payload: Dictionary) -> bool:
	if not _id_valid(payload.get("source_id",null)) or not _position_valid(payload.get("origin",[])) or not payload.get("shape","") in ["circle","sector","line"]: return false
	if not _integer_valid(payload.get("warning_ticks",null)) or not _integer_valid(payload.get("active_ticks",null),1) or not _number_valid(payload.get("damage",null)): return false
	if payload.shape in ["circle","sector"] and (not _number_valid(payload.get("radius",null)) or float(payload.radius) <= 0.0): return false
	if payload.shape in ["sector","line"] and not _position_valid(payload.get("direction",[])): return false
	if payload.shape == "line" and (not _number_valid(payload.get("length",null)) or not _number_valid(payload.get("width",null)) or float(payload.length) <= 0.0 or float(payload.width) <= 0.0): return false
	if payload.shape == "sector" and (not _number_valid(payload.get("arc_degrees",90.0)) or float(payload.get("arc_degrees",90.0)) > 360.0): return false
	return true
func _offer_valid(state: Dictionary, offer: Dictionary, applicable: bool) -> bool:
	if offer.is_empty(): return true
	if not offer.get("source") is String: return false
	if offer.size() != (6 if offer.get("source") == "chest" else 5) or not offer.has_all(["offer_id","source","level_ordinal","options","selected_option_id"]) or not Catalog.json_data_valid(offer): return false
	if not offer.options is Array or offer.options.is_empty() or offer.options.size() > 3 or not offer.selected_option_id is String: return false
	var descriptor := {"offer_id":offer.offer_id,"source":offer.source,"level_ordinal":offer.level_ordinal}
	if offer.source == "chest":
		if not offer.get("chest_id") is String: return false
		descriptor.chest_id = offer.chest_id
	if not Growth.new(_catalog)._descriptor_valid(state,descriptor) or (offer.source == "level" and offer.level_ordinal < 2): return false
	var ids := {}
	for option in offer.options:
		if not option is Dictionary or not _catalog.option_well_formed(state,option) or (applicable and not _catalog.option_valid(state,option)): return false
		if ids.has(option.option_id) or not _same_decoration(option,_catalog.decorate_option(state,option)): return false
		ids[option.option_id] = true
	return ids.has(offer.selected_option_id)
func _same_decoration(saved: Dictionary, derived: Dictionary) -> bool:
	# Derived UI arithmetic may round by one double ULP in Godot's own JSON
	# parser. Compare the serializer/parser's canonical representation, while
	# immutable rules and choice identities retain their separate strict checks.
	var saved_json = JSON.parse_string(JSON.stringify(saved,"",true,true))
	var derived_json = JSON.parse_string(JSON.stringify(derived,"",true,true))
	return _same_json(saved_json,derived_json)
func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]),float(value[1]))
func _array(value: Vector2) -> Array:
	return [value.x,value.y]

func _normalize_saved_numbers(value: Variant, parent_key := "") -> bool:
	# JSON reads every numeric literal as a float. Restore schema integers so
	# canonical replay equality and typed clocks survive a disk roundtrip.
	if value is Dictionary:
		for key in value.keys():
			if key is StringName:
				var child = value[key]
				value.erase(key)
				value[str(key)] = child
			if value[key] is float and (parent_key in ["equipment","passives","attack_ready_ticks","permanent_upgrades"] or key in ["loot_rules_version","born_tick","next_retry_tick","gold","character_skill_revision","ready_tick","next_probe_tick","cast_damage_level","recovery_ticks","cooldown_ticks","airborne_ticks","threat_cost","started_tick","attack_ends_tick","recover_ends_tick","role_wait_since","role_retry_tick","schema_version","seed","active_tick","survival_tick","next_entity_id","event_seq","run_serial","tactical_seals","attack_seq","offer_seq","view_revision","level_ordinal","attack_started_tick","execute_tick","stage_index","stage_count","equipment_slots","passive_slots","final_started_tick","invulnerable_until","xp","level","next_level","kills","minibosses_defeated","evacuation_ticks","base_xp","xp_per_level","spawned_tick","action_started_tick","action_ends_tick","next_action_tick","pattern_index","created_tick","active_from_tick","expires_tick","warning_ticks","active_ticks","id","entity_id"]):
				var number: float = value[key]
				if not is_finite(number) or number != floor(number) or number < (-1.0 if key in ["final_started_tick","role_wait_since"] else 0.0) or number > MAX_COUNTER: return false
				value[key] = int(number)
			elif not _normalize_saved_numbers(value[key],str(key)): return false
	elif value is Array:
		for child in value:
			if not _normalize_saved_numbers(child,parent_key): return false
	return true

func _attract_drops(state: Dictionary) -> void:
	var pickup := _catalog.stat(state,"pickup_radius",float(state.rules.pickup_radius))
	var player := _vec(state.player.position)
	for drop in state.drops:
		var point := _vec(drop.position)
		if point.distance_to(player) <= pickup*3.0:
			drop.position = _array(point.move_toward(player,240.0/TICKS_PER_SECOND))
func _number_valid(value: Variant, minimum := 0.0) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum
func _integer_valid(value: Variant, minimum := 0) -> bool:
	return _number_valid(value,float(minimum)) and float(value) == floor(float(value)) and float(value) <= MAX_COUNTER
func _generated_identity_number(value: Variant) -> int:
	# Restore uniqueness uses str(id), so canonical decimal String IDs reserve
	# the same allocator range as numeric IDs without changing their saved type.
	if Catalog.integer_valid(value,1,MAX_COUNTER): return int(value)
	if value is String and value.length() <= 10 and value.is_valid_int():
		var number: int = value.to_int()
		if number >= 1 and number <= MAX_COUNTER and value == str(number): return number
	return 0
func _id_valid(value: Variant) -> bool:
	return (value is String and not value.is_empty()) or _integer_valid(value,1)
func _string_set_valid(value: Array) -> bool:
	var seen: Array = []
	for id in value:
		if not id is String or id.is_empty() or id in seen: return false
		seen.append(id)
	return true
func _core_payload_valid(value: Dictionary, chapter: Dictionary = {}, validation_helper = null) -> bool:
	if chapter.is_empty():
		var current: Dictionary = {"ok":not _chapter.is_empty(),"chapter":_chapter}
		if not current.get("ok",false): return false
		chapter = current.chapter
	for key in ["schema_version","seed","active_tick","survival_tick","next_entity_id","event_seq"]:
		if not _integer_valid(value.get(key,null)): return false
	if int(value.seed) > 0x7fffffff or not _integer_valid(value.get("final_started_tick",null),-1): return false
	if not value.get("evacuation_ready",null) is bool: return false
	if not _rect_valid(value.get("escape_zone",null)) and not (value.has("world") and Streamed.inactive_city_exit(value.get("escape_zone"))): return false
	for key in ["boss_ids_fired","reward_ids_claimed","command_ids_applied","pause_reasons"]:
		if not _string_set_valid(value[key]): return false
	var player: Dictionary = value.player
	for key in ["hp","max_hp","radius"]:
		if not _number_valid(player.get(key,null)): return false
	for key in ["invulnerable_until","xp","level"]:
		if not _integer_valid(player.get(key,null)): return false
	if not player.get("attack_ready_ticks",null) is Dictionary: return false
	for item_id in player.attack_ready_ticks:
		if not _catalog.equipment.has(item_id) or not _integer_valid(player.attack_ready_ticks[item_id]): return false
	if not value.get("rules",null) is Dictionary: return false
	var rules: Dictionary = value.rules
	var world = rules.get("world_geometry",{})
	if not World.valid(world) or (value.content_revision == "ch01.2" and world.is_empty()): return false
	if not _position_valid(player.get("position")): return false
	if value.has("player_mobility") and value.player_mobility.phase != "ground":
		if validation_helper == null or not validation_helper.mobility_player_clearance(value).get("walkable",false): return false
	elif not _validation_walkable(value,_vec(player.position),float(player.radius),validation_helper): return false
	if not rules.get("allowed_equipment_ids",null) is Array or not _string_set_valid(rules.allowed_equipment_ids): return false
	for item_id in rules.allowed_equipment_ids:
		if not _catalog.equipment.has(item_id): return false
	for item_id in value.equipment:
		if not item_id in rules.allowed_equipment_ids: return false
	for kind in ["equipment","passives"]:
		for item_id in value[kind]:
			if not _integer_valid(value[kind][item_id],1): return false
	if not _number_valid(rules.get("move_speed",null)) or not _number_valid(rules.get("pickup_radius",null)) or not _integer_valid(rules.get("evacuation_ticks",null),1) or int(rules.evacuation_ticks) != 4500: return false
	if not rules.get("progression",null) is Dictionary or not _integer_valid(rules.progression.get("base_xp",null),1) or not _integer_valid(rules.progression.get("xp_per_level",null)): return false
	if not rules.get("enemy_catalog",null) is Dictionary: return false
	for enemy_id in rules.enemy_catalog:
		var definition = rules.enemy_catalog[enemy_id]
		if not definition is Dictionary: return false
		for key in ["hp","speed","radius"]:
			if not _number_valid(definition.get(key,null)): return false
		if not _number_valid(definition.get("damage",definition.get("contact_damage",null))) or not _integer_valid(definition.get("xp",null)): return false
	for key in ["kills","minibosses_defeated"]:
		if not _integer_valid(value.stats.get(key,null)): return false
	if not _number_valid(value.stats.get("damage_dealt",null)): return false
	var seen: Array = []
	var seen_bosses := {}
	var population := {"ok":true,"retire":[],"park_entities":[]}
	if value.has("world") and value.world.stage == "city": population = Population.plan(value)
	if not population.get("ok",false): return false
	var dormant: Dictionary = value.world.dormant if value.has("world") and value.world.get("schema_version") == 2 else {"entities":[],"drops":[]}
	if value.entities.size()+dormant.entities.size() > MAX_ENTITIES or value.drops.size()+dormant.drops.size() > MAX_DROPS: return false
	var projectile_casts := {}
	for attack in value.player_attack_instances: projectile_casts[attack.cast_id] = true
	for collection in ["entities","projectiles","drops","telegraphs"]:
		var records: Array = value[collection].duplicate()
		if collection in ["entities","drops"]:
			for entry in dormant[collection]: records.append(entry.record)
		for index in records.size():
			var record = records[index]
			var parked: bool = index >= value[collection].size()
			if not record is Dictionary or not _id_valid(record.get("id",null)) or str(record.id) in seen: return false
			seen.append(str(record.id))
			var numeric_identity := _generated_identity_number(record.id)
			if numeric_identity >= int(value.next_entity_id) or (not record.id is String and numeric_identity == 0): return false
			if collection != "telegraphs" and not _position_valid(record.get("position",null)): return false
			if collection == "entities":
				for key in ["hp","max_hp","speed","radius","damage"]:
					if not _number_valid(record.get(key,null)): return false
				if not _integer_valid(record.get("xp",null)) or not _integer_valid(record.get("spawned_tick",null)) or not _position_valid(record.get("velocity",null)): return false
				if not record.get("boss_id",null) is String or not record.get("enemy_id",null) is String or not rules.enemy_catalog.has(record.enemy_id): return false
				if not _entity_definition_valid(value,record,chapter) or not _behavior_state_valid(value,record,validation_helper): return false
				if not record.boss_id.is_empty():
					if seen_bosses.has(record.boss_id): return false
					seen_bosses[record.boss_id] = true
				if parked and (record.boss_id.is_empty() or not Population.quiescent(value,record)): return false
				var suspended: bool = parked or index in population.retire or index in population.park_entities
				if not suspended and record.get("action_state","") != "airborne" and not _validation_walkable(value,_vec(record.position),float(record.radius),validation_helper): return false
			elif collection == "projectiles":
				if not _projectile_valid(value,record) or projectile_casts.has(record.cast_id): return false
				projectile_casts[record.cast_id] = true
			elif collection == "drops":
				if not _integer_valid(record.get("xp",null),1): return false
			elif collection == "telegraphs":
				if not _hazard_valid(record): return false
				for key in ["created_tick","active_from_tick","expires_tick"]:
					if not _integer_valid(record.get(key,null)): return false
				if int(record.active_from_tick) != int(record.created_tick)+int(record.warning_ticks) or int(record.expires_tick) != int(record.active_from_tick)+int(record.active_ticks): return false
	return _run_relationships_valid(value) and _owned_behavior_hazards_valid(value) and _validate_role_attacks(value,validation_helper)
func _entity_definition_valid(state: Dictionary, record: Dictionary, chapter: Dictionary) -> bool:
	if not _same_json(record.get("entity_id"),record.id): return false
	var definition: Dictionary = state.rules.enemy_catalog[record.enemy_id]
	for pair in [["max_hp","hp"],["speed","speed"],["radius","radius"],["damage","damage"],["xp","xp"],["behavior","behavior"],["art_id","art_id"]]:
		if not _same_json(record.get(pair[0]),definition.get(pair[1])): return false
	if record.hp <= 0 or record.hp > record.max_hp or record.spawned_tick > state.active_tick: return false
	if record.enemy_id == FINAL_ENEMY_ID:
		return record.boss_id == FINAL_BOSS_ID and FINAL_BOSS_ID in state.boss_ids_fired and record.spawned_tick == state.final_started_tick and record.hp == record.max_hp and record.xp == 0 and FINAL_ACTOR_SPAWN_ID in state.command_ids_applied
	if record.boss_id.is_empty(): return record.enemy_id in chapter.enemy_ids
	if not record.boss_id in REAL_BOSS_IDS or not record.boss_id in state.boss_ids_fired or "boss:"+record.boss_id in state.reward_ids_claimed: return false
	var authored: Dictionary = chapter.boss_schedule[REAL_BOSS_IDS.find(record.boss_id)]
	return record.enemy_id == authored.enemy_id and record.spawned_tick == authored.tick and state.survival_tick >= authored.tick
func _projectile_valid(state: Dictionary, record: Dictionary, canonical_damage: Variant = null) -> bool:
	var fields := ["id","item_id","attack_id","cast_id","position","velocity","damage","splash_radius","remaining_distance","radius"]
	if record.size() != fields.size() or not record.has_all(fields): return false
	if not Catalog.integer_valid(record.id,1,int(state.next_entity_id)-1) or not record.item_id is String or not state.equipment.has(record.item_id): return false
	if not record.cast_id is String or not record.attack_id is String or not Evolved._cast_id_valid(state,record.cast_id) or record.attack_id != record.cast_id+":0": return false
	var definition: Dictionary = _catalog.equipment.get(record.item_id,{})
	if definition.get("mode") != "projectile" or not Catalog.number_valid(record.radius,4.0,4.0) or not _position_valid(record.velocity): return false
	if absf(_vec(record.velocity).length()-float(definition.projectile_speed)) > 0.001: return false
	if not Catalog.number_valid(record.remaining_distance,0.0000001,10000000) or not Catalog.number_valid(record.damage,0,10000000) or not Catalog.number_valid(record.splash_radius,0,10000000): return false
	# A flying projectile retains the joint weapon-level/damage/range snapshot
	# from any already-earned build, including before the weapon evolved.
	var damage_increment: float = _catalog.passives.damage.increment
	var range_increment: float = _catalog.passives.attack_range.increment
	for level in range(1,int(state.equipment[record.item_id])+1):
		var base_damage := float(definition.damage)+(level-1)*float(definition.damage_per_level)
		var possible_damage: Array[float] = []
		for damage_level in range(int(state.passives.get("damage",0))+1):
			var expected := base_damage*(1.0+float(state.rules.get("permanent_damage_bonus",0.0))+damage_increment*damage_level)
			if absf(float(record.damage)-expected) <= 0.000001 and not expected in possible_damage: possible_damage.append(expected)
		if possible_damage.is_empty(): continue
		for range_level in range(int(state.passives.get("attack_range",0))+1):
			var scale := 1.0+range_increment*range_level
			var splash := float(definition.splash_radius)*scale
			var reach := (float(definition.range)+(level-1)*float(definition.range_per_level))*scale+48.0
			if absf(float(record.splash_radius)-splash) <= 0.000001 and float(record.remaining_distance) <= reach+0.000001:
				if canonical_damage == null: return true
				for damage in possible_damage:
					if not damage in canonical_damage: canonical_damage.append(damage)
				break
	return canonical_damage is Array and canonical_damage.size() == 1
func _run_relationships_valid(value: Dictionary) -> bool:
	if int(value.active_tick) < int(value.survival_tick): return false
	if value.phase in ["dead","won","abandoned"] and (not value.upgrade_offer.is_empty() or not value.pending_offers.is_empty() or "upgrade" in value.pause_reasons): return false
	if (not value.upgrade_offer.is_empty()) != ("upgrade" in value.pause_reasons): return false
	if value.upgrade_offer.is_empty() and not value.pending_offers.is_empty(): return false
	var final_count := 0
	for entity in value.entities:
		if entity.enemy_id == FINAL_ENEMY_ID: final_count += 1
	if value.get("world") is Dictionary and value.world.get("schema_version") == 2:
		for entry in value.world.dormant.entities:
			if entry.record.enemy_id == FINAL_ENEMY_ID: final_count += 1
	if final_count != (1 if FINAL_ACTOR_SPAWN_ID in value.command_ids_applied else 0): return false
	var started := int(value.final_started_tick)
	if started == -1:
		return value.phase in ["survival","dead","abandoned"] and not value.evacuation_ready
	if started < FINAL_TICK or started > int(value.active_tick) or int(value.survival_tick) != FINAL_TICK or value.phase == "survival": return false
	if not "ch01_final_armored" in value.boss_ids_fired: return false
	var elapsed := int(value.active_tick)-started
	if value.evacuation_ready and elapsed < int(value.rules.evacuation_ticks): return false
	if value.phase == "won" and (not value.evacuation_ready or elapsed < int(value.rules.evacuation_ticks) or not _inside_escape(value)): return false
	return true

func _offer_queue_ids_valid(state: Dictionary) -> bool:
	var ids := {}
	var prefix: String = state.run_id+":offer:"
	for reward in state.reward_ids_claimed:
		if reward.begins_with("boss:"): continue
		if not reward.begins_with("offer:"+prefix): return false
		var id: String = reward.trim_prefix("offer:")
		var serial: String = id.trim_prefix(prefix)
		if not serial.is_valid_int() or str(serial.to_int()) != serial or not Catalog.integer_valid(serial.to_int(),1,int(state.offer_seq)): return false
		ids[id] = true
	var offers: Array = state.pending_offers.duplicate()
	if not state.upgrade_offer.is_empty(): offers.push_front(state.upgrade_offer)
	var previous := 0
	var previous_level := 1
	var level_ordinals := {}
	var boss_descriptors := 0
	for offer in offers:
		var id: String = offer.offer_id
		var serial: int = id.trim_prefix(prefix).to_int()
		if ids.has(id) or serial <= previous or offer.level_ordinal < previous_level or (offer.source == "level" and offer.level_ordinal < 2): return false
		if offer.source == "level":
			if level_ordinals.has(int(offer.level_ordinal)): return false
			level_ordinals[int(offer.level_ordinal)] = true
		elif offer.source == "boss": boss_descriptors += 1
		previous = serial
		previous_level = int(offer.level_ordinal)
		ids[id] = true
	return boss_descriptors == 0 if Loot.enabled(state) else boss_descriptors <= int(state.stats.minibosses_defeated)
func _behavior_state_valid(state: Dictionary, entity: Dictionary, validation_helper = null) -> bool:
	if _is_live_role(entity): return _role_owner_valid(state,entity)
	for key in ["role_wait_since","role_retry_tick","role_hand_reach"]:
		if entity.has(key): return false
	var required := ["action_state","action_started_tick","action_ends_tick","next_action_tick","pattern_index","attack_kind","locked_origin","locked_direction","locked_target","facing"]
	var present := false
	for key in required:
		if entity.has(key): present = true
	if not present: return entity.enemy_id != FINAL_ENEMY_ID # The explicit final profile always owns an FSM.
	for key in required:
		if not entity.has(key): return false
	if not entity.action_state in (["move","windup","attack","brake","recover"] if entity.enemy_id == FINAL_ENEMY_ID else ["move","windup","attack","recover","airborne"]) or not entity.attack_kind in ["none","charge","slam","sweep","grab","leap"]: return false
	for key in ["action_started_tick","action_ends_tick","next_action_tick","pattern_index"]:
		if not _integer_valid(entity[key]): return false
	if int(entity.action_started_tick) > int(state.active_tick) or int(entity.action_ends_tick) < int(entity.action_started_tick): return false
	for key in ["locked_origin","locked_direction","locked_target","facing"]:
		if not _position_valid(entity[key]): return false
	if not is_equal_approx(_vec(entity.locked_direction).length_squared(),1.0) or not is_equal_approx(_vec(entity.facing).length_squared(),1.0): return false
	if entity.has("art_id") and not entity.art_id is String: return false
	if entity.action_state == "move": return true
	var profile: Dictionary = Behaviors.profile(entity,state.rules.enemy_catalog)
	if entity.attack_kind != profile.kind or entity.attack_kind == "none" or int(entity.pattern_index) < 1 or int(entity.action_ends_tick) <= int(state.active_tick): return false
	var duration_key: String = {"windup":"warning_ticks","airborne":"airborne_ticks","attack":"active_ticks","brake":"brake_ticks","recover":"recovery_ticks"}[entity.action_state]
	if not profile.has(duration_key) or int(entity.action_ends_tick)-int(entity.action_started_tick) != int(profile[duration_key]): return false
	if entity.action_state == "airborne" and entity.attack_kind != "leap": return false
	if not "behavior:%s:%d"%[str(entity.id),int(entity.pattern_index)] in state.command_ids_applied: return false
	if not _validation_walkable(state,_vec(entity.locked_origin),float(entity.radius),validation_helper): return false
	if entity.attack_kind == "leap" and not _validation_walkable(state,_vec(entity.locked_target),float(entity.radius),validation_helper): return false
	if entity.enemy_id == FINAL_ENEMY_ID and entity.action_state in ["windup","attack"]:
		var ready := _final_contact_ready(state,_vec(entity.locked_origin),_vec(entity.locked_direction),profile,validation_helper)
		if not ready.get("ok",false) or not ready.clear: return false
	if not _action_motion_valid(state,entity,profile,validation_helper): return false
	if entity.action_state in ["windup","airborne","attack"]:
		var found := false
		for hazard in state.telegraphs:
			if hazard is Dictionary and hazard.get("source_id",null) == str(entity.id) and hazard.get("behavior_attack",false) == true and _behavior_hazard_matches(entity,profile,hazard):
				found = true
		if not found: return false
	return true

func _behavior_hazard_matches(entity: Dictionary, profile: Dictionary, hazard: Dictionary) -> bool:
	if not _hazard_valid(hazard): return false
	for key in ["created_tick","active_from_tick","expires_tick"]:
		if not _integer_valid(hazard.get(key,null)): return false
	var warning := int(profile.warning_ticks)+int(profile.get("airborne_ticks",0))
	if int(hazard.warning_ticks) != warning or int(hazard.active_ticks) != int(profile.active_ticks) or float(hazard.damage) != float(entity.damage): return false
	var created := int(entity.action_started_tick)
	if entity.action_state == "airborne": created -= int(profile.warning_ticks)
	elif entity.action_state == "attack": created -= warning
	if int(hazard.created_tick) != created or int(hazard.active_from_tick) != created+warning: return false
	var origin := _vec(entity.locked_target) if entity.attack_kind == "leap" else _vec(entity.locked_origin)
	if not _vec(hazard.origin).is_equal_approx(origin) or not _vec(hazard.get("direction",[0.0,0.0])).is_equal_approx(_vec(entity.locked_direction)): return false
	var shape := "circle" if entity.attack_kind in ["slam","leap"] else ("sector" if entity.attack_kind == "sweep" else "line")
	if hazard.shape != shape: return false
	if shape in ["circle","sector"] and not is_equal_approx(float(hazard.radius),float(profile.radius)): return false
	if shape == "sector" and not is_equal_approx(float(hazard.get("arc_degrees",90.0)),float(profile.arc_degrees)): return false
	if shape == "line" and (not is_equal_approx(float(hazard.length),float(profile.length)) or not is_equal_approx(float(hazard.width),maxf(float(profile.width),float(entity.radius)*2.0))): return false
	return true

func _action_motion_pose(state: Dictionary, entity: Dictionary, profile: Dictionary, validation_helper = null, detailed: bool = false) -> Dictionary:
	var contacts := []
	var sweep_steps := 0
	var position := _vec(entity.locked_origin)
	var velocity := Vector2.ZERO
	var age := int(state.active_tick)-int(entity.action_started_tick)
	if entity.enemy_id == FINAL_ENEMY_ID and entity.action_state in ["brake","recover"]:
		return {"ok":true,"position":position,"velocity":velocity,"contacts":contacts,"sweep_steps":0}
	if entity.action_state == "airborne":
		var duration := float(profile.airborne_ticks)
		var origin := _vec(entity.locked_origin)
		var target := _vec(entity.locked_target)
		position = origin.lerp(target,float(age)/duration)
		var previous := origin.lerp(target,float(maxi(0,age-1))/duration)
		velocity = (position-previous)*TICKS_PER_SECOND
	elif entity.action_state in ["attack","recover"]:
		if entity.attack_kind in ["charge","grab"]:
			var rush := _vec(entity.locked_direction)*float(profile.rush_speed)
			var step_delta := rush/TICKS_PER_SECOND
			var steps := age+1 if entity.action_state == "attack" else int(profile.active_ticks)
			# Match the engine's real_t rounding at every physical step rather
			# than comparing against a numerically different closed-form sum.
			for index in steps:
				if entity.enemy_id == FINAL_ENEMY_ID:
					rush = _vec(entity.locked_direction)*_final_charge_speed(profile,index)
					step_delta = rush/TICKS_PER_SECOND
				if entity.enemy_id == FINAL_ENEMY_ID:
					var combined := _final_contact_sweep(state,position,step_delta,_vec(entity.locked_direction),profile,validation_helper)
					if not combined.get("ok",false): return combined
					# Live final contact enters brake immediately, including fraction1.
					# A saved attack cannot replay through that already-ended phase.
					if combined.stopped: return _failure("invalid_final_attack_phase")
					if detailed:
						sweep_steps += 1
						if combined.stopped: contacts.append({"step":index,"shape_id":combined.contact.get("shape_id",""),"kind":"shoulder" if not combined.contact.is_empty() else "body"})
					position = combined.position
				elif state.has("world") and state.world.stage == "city":
					if validation_helper == null: return _failure("world_not_ready")
					var swept: Dictionary = validation_helper.sweep(position,step_delta,float(entity.radius))
					if not swept.get("ok",false): return swept
					if detailed:
						sweep_steps += 1
						if float(swept.fraction) < 1.0: contacts.append({"step":index,"prop_id":swept.hit_prop_id})
					position = swept.position
				else: position = World.sweep(position,step_delta,float(entity.radius),_finite_geometry(state))
			if entity.action_state == "attack": velocity = rush
		elif entity.attack_kind == "leap": position = _vec(entity.locked_target)
	return {"ok":true,"position":position,"velocity":velocity,"contacts":contacts,"sweep_steps":sweep_steps}
func _action_motion_valid(state: Dictionary, entity: Dictionary, profile: Dictionary, validation_helper = null) -> bool:
	return _motion_pose_matches(entity,_action_motion_pose(state,entity,profile,validation_helper))
func _motion_pose_matches(entity: Dictionary, pose: Dictionary) -> bool:
	# Absolute subpixel tolerances do not widen with world coordinates.
	return pose.get("ok",false) and _vec(entity.position).distance_to(pose.position) <= 0.001 and _vec(entity.velocity).distance_to(pose.velocity) <= 0.01 and _vec(entity.facing).distance_to(_vec(entity.locked_direction)) <= 0.0001
func _reconcile_rebased_motion(source: Dictionary, candidate: Dictionary, old_helper, next_helper, retired_entity_ids: Array = []) -> Dictionary:
	var corrections := []
	var by_id := {}
	for entity in candidate.entities: by_id[str(entity.id)] = entity
	for index in source.entities.size():
		var original: Dictionary = source.entities[index]
		if _is_live_role(original):
			if not by_id.has(str(original.id)):
				# Only the exact ordinary, ownerless source retired by this same
				# private population transaction may disappear during rebase.
				if original.id in retired_entity_ids and Population.outside(source,original) and Population.quiescent(source,original): continue
				return _failure("invalid_core_state")
			var role_rebase := _reconcile_role_rebase(source,candidate,original,by_id[str(original.id)],old_helper,next_helper)
			if not role_rebase.get("ok",false): return role_rebase
			continue
		if not original.get("action_state","") in ["airborne","attack","brake","recover"]: continue
		if not by_id.has(str(original.id)): return _failure("invalid_core_state")
		var entity: Dictionary = by_id[str(original.id)]
		var profile: Dictionary = Behaviors.profile(original,source.rules.enemy_catalog)
		var previous := _action_motion_pose(source,original,profile,old_helper,true)
		if not previous.get("ok",false): return previous
		if not _motion_pose_matches(original,previous): return _failure("invalid_core_state")
		var next := _action_motion_pose(candidate,entity,profile,next_helper,true)
		if not next.get("ok",false): return next
		var from := _vec(entity.position)
		var distance := from.distance_to(next.position)
		var measured := {"entity_id":str(entity.id),"distance":distance,"limit":0.03125,"before":_array(from),"after":_array(next.position),"sweep_steps":next.sweep_steps,"old_contacts":previous.contacts,"new_contacts":next.contacts}
		# Reconstruct only real_t integration roundoff. Never accept a larger
		# motion discrepancy or a changed wall/contact sequence as a rebase.
		if distance > 0.03125 or previous.contacts != next.contacts:
			measured.merge({"ok":false,"error_code":"rebase_motion_discontinuity"})
			return measured
		if distance > 0 and entity.action_state != "airborne":
			var correction: Dictionary = next_helper.sweep(from,next.position-from,float(entity.radius))
			if not correction.get("ok",false): return correction
			measured.correction_fraction = correction.fraction
			if float(correction.fraction) != 1.0 or correction.position.distance_to(next.position) > 0.0001:
				measured.merge({"ok":false,"error_code":"rebase_motion_contact_changed"})
				return measured
		entity.position = _array(next.position)
		entity.velocity = _array(next.velocity)
		if distance > 0: corrections.append(measured)
	return {"ok":true,"corrections":corrections}
func _owned_behavior_hazards_valid(state: Dictionary) -> bool:
	var actors: Dictionary = {}
	for entity in state.entities: actors[str(entity.id)] = entity
	var sources: Array[String] = []
	for hazard in state.telegraphs:
		if hazard.has("behavior_attack") and not hazard.behavior_attack is bool: return false
		if not hazard.get("behavior_attack",false): continue
		var source: String = str(hazard.source_id)
		if source in sources or not actors.has(source): return false
		var actor: Dictionary = actors[source]
		if _is_live_role(actor): return false
		if actor.hp <= 0.0 or not actor.has("action_state") or not actor.action_state in ["windup","airborne","attack"]: return false
		if not _behavior_hazard_matches(actor,Behaviors.profile(actor,state.rules.enemy_catalog),hazard): return false
		sources.append(source)
	return true
func _canonicalize_saved_vectors(state: Dictionary) -> void:
	# The inactive city exit and actual scene rectangles share one numeric form.
	state.escape_zone = state.escape_zone.map(func(value): return float(value))
	# Engine vectors are real_t float32 values widened into JSON-safe arrays.
	# Reconstruct that representation after decimal parsing; even full-precision
	# JSON can otherwise leave a double ULP on a widened float32 coordinate.
	for key in ["position","velocity","facing"]:
		state.player[key] = _array(_vec(state.player[key]))
	if state.has("player_mobility"):
		var mobility: Dictionary = state.player_mobility
		mobility.direction = _array(_vec(mobility.direction))
		# These locals/directions were created by engine Vector2 operations.
		# Recover real_t representation only; never translate absolute chunks,
		# choose another path, change progress or force an airborne landing.
		for point in mobility.path: point.local = _array(_vec(point.local))
		if mobility.schema_version == 2:
			for anchor in mobility.anchors: anchor.local = _array(_vec(anchor.local))
		elif not mobility.anchor.is_empty():
			mobility.anchor.local = _array(_vec(mobility.anchor.local))
			for field in ["pass_start","pass_end"]:
				mobility.anchor[field].local = _array(_vec(mobility.anchor[field].local))
		if not mobility.landing.is_empty(): mobility.landing.local = _array(_vec(mobility.landing.local))
	if state.has("loot"):
		for chest in state.loot.chests + state.loot.get("potions",[]):
			chest.position = _array(_vec(chest.position))
			if chest.stage == "city": chest.address.local = _array(_vec(chest.address.local))
	for collection in ["entities","projectiles","drops"]:
		var records: Array = state[collection].duplicate()
		if state.has("world") and state.world.get("schema_version") == 2 and collection in ["entities","drops"]:
			for entry in state.world.dormant[collection]: records.append(entry.record)
		for record in records:
			# The first hand cap is a real_t Vector2 dot result, too. Recover
			# its exact saved value; never recompute reach from current walls.
			if record.has("role_hand_reach"): record.role_hand_reach = float(Vector2(float(record.role_hand_reach),0.0).x)
			for key in ["position","velocity","facing","locked_origin","locked_direction","locked_target"]:
				if record.has(key): record[key] = _array(_vec(record[key]))
	for attack in state.enemy_attack_instances:
		for key in ["locked_origin","locked_direction","locked_target"]: attack[key] = _array(_vec(attack[key]))
	for attack in state.player_attack_instances:
		attack.origin = _array(_vec(attack.origin))
		attack.direction = _array(_vec(attack.direction))
	for hazard in state.telegraphs:
		hazard.origin = _array(_vec(hazard.origin))
		if hazard.has("direction"): hazard.direction = _array(_vec(hazard.direction))

func _finite_geometry(state: Dictionary) -> Dictionary:
	if state.has("world"):
		if state.world.stage != "dock": return {}
		return _chapter.authored_dock.geometry
	return state.rules.get("world_geometry",{})
func _validation_walkable(state: Dictionary, position: Vector2, radius: float, helper) -> bool:
	if state.has("world") and state.world.stage == "city":
		if helper == null: return false
		var result: Dictionary = helper.walkable(position,radius)
		return result.get("ok",false) and result.get("walkable",false)
	return World.walkable(position,radius,_finite_geometry(state))

# Streamed transaction: immutable rules/config/world and resident geometry are
# shared. Only records/arrays actually written by this fixed tick are copied.
# No per-tick restore, fresh helper, prepare or full-state recursive duplication.
func _tick_candidate(state: Dictionary) -> Dictionary:
	var candidate := state.duplicate()
	if state.has("loot"): candidate.loot = state.loot.duplicate(true)
	if state.has("character_skill"): candidate.character_skill = state.character_skill.duplicate()
	if state.has("player_mobility"): candidate.player_mobility = state.player_mobility.duplicate(true)
	candidate.player = state.player.duplicate()
	candidate.player.attack_ready_ticks = state.player.attack_ready_ticks.duplicate()
	candidate.stats = state.stats.duplicate()
	for collection in ["entities","projectiles","drops"]:
		var records := []
		for record in state[collection]: records.append(record.duplicate())
		candidate[collection] = records
	candidate.enemy_attack_instances = []
	for attack in state.enemy_attack_instances: candidate.enemy_attack_instances.append(attack.duplicate(true))
	for collection in ["telegraphs","player_attack_instances","boss_ids_fired","reward_ids_claimed","command_ids_applied","pause_reasons","pending_offers"]:
		candidate[collection] = state[collection].duplicate()
	return candidate
func _step_streamed(state: Dictionary, move: Vector2, commands: Array[Dictionary]) -> Array[Dictionary]:
	if state.phase in ["won","dead","abandoned"] or not state.pause_reasons.is_empty() or not state.upgrade_offer.is_empty(): return []
	if _streamed == null:
		_last_step_status = _failure("world_not_ready")
		return []
	var ready: Dictionary = _streamed.begin_query_batch(state,commands)
	if not ready.get("ok",false):
		_last_step_status = ready
		return []
	var candidate := _tick_candidate(state)
	var tick_commands: Array[Dictionary] = commands
	var previous_helper = _streamed
	var next_helper = _streamed
	var rebase_motion := []
	var population := Population.apply_to_candidate(candidate)
	if not population.get("ok",false):
		_last_step_status = population
		return []
	var rebased := false
	# Population transitions and rebasing share one private fixed-tick candidate.
	# Dormant world records keep their absolute address and are never rebased.
	if candidate.world.stage == "city":
		var normalized := Streamed.Address.normalize(candidate.world.origin_chunk,_vec(candidate.player.position))
		if not normalized.get("ok",false):
			_last_step_status = normalized
			return []
		if normalized.offset != Vector2.ZERO:
			var proposal := Streamed.rebase_proposal(candidate,commands)
			if not proposal.get("ok",false):
				_last_step_status = proposal
				return []
			candidate = proposal.state
			_canonicalize_saved_vectors(candidate)
			tick_commands = []
			tick_commands.assign(proposal.commands)
			rebased = true
	if rebased or not _streamed.matches(candidate):
		var prepared: Dictionary
		if rebased and _can_prepare_live_coverage(state) and _streamed._rebase_eligible(state,candidate,_streamed._hydration):
			prepared = _streamed._prepare_rebased(state,candidate,_streamed._hydration,tick_commands)
			if prepared.get("ok",false): next_helper = prepared.helper
		else:
			next_helper = _streamed.fresh()
			prepared = next_helper.prepare(candidate,_streamed._hydration,tick_commands)
		if not prepared.get("ok",false):
			_last_step_status = prepared
			return []
	if rebased:
		var reconciled := _reconcile_rebased_motion(state,candidate,_streamed,next_helper,population.get("retired_entity_ids",[]))
		if not reconciled.get("ok",false):
			_last_step_status = reconciled
			return []
		rebase_motion = reconciled.corrections
	for id in population.get("woken_entities",[]):
		for entity in candidate.entities:
			if entity.id != id: continue
			var legal: Dictionary = next_helper.walkable(_vec(entity.position),float(entity.radius))
			if not legal.get("ok",false) or not legal.get("walkable",false):
				_last_step_status = legal if not legal.get("ok",false) else {"ok":false,"error_code":"population_blocked","entity_id":str(id)}
				return []
	_streamed = next_helper
	_tick_navigation = {"target_adjustments":0,"target_waits":0,"route_queries":0,"route_blocked":0,"route_deferred":0,"max_route_wait_ticks":0,"deferred_attacks":0,"actors":[]}
	# Only the exact native path can reuse the readiness admitted above. Between
	# that check and the pre-move role query, this path changes no spatial input.
	_role_batch_tick = -1
	_role_batch_helper_id = 0
	if get_script() == load("res://game/core/run_simulation.gd") and commands.is_empty() and candidate.phase == "survival" and candidate.world.stage == "city" and not population.get("changed",true) and not rebased and _streamed == previous_helper and _streamed.get_script() == Streamed and _streamed._world != null and _streamed._world.get_script() == Streamed.Stream and _streamed._generator != null and _streamed._generator.get_script() == Streamed.Generator and candidate.active_tick is int and candidate.active_tick >= 0 and candidate.active_tick < MAX_COUNTER-1:
		if not candidate.has("player_mobility") or (candidate.player_mobility is Dictionary and candidate.player_mobility.get("schema_version") is int and candidate.player_mobility.schema_version == 2):
			_role_batch_tick = int(candidate.active_tick)
			_role_batch_helper_id = _streamed.get_instance_id()
	var events := _step_running(candidate,move,tick_commands)
	# The private candidate root can outlive commit. End the borrowed query now,
	# before any failure/rollback path, while retaining its completed status.
	if get_script() == load("res://game/core/run_simulation.gd") and _role_tick_query is RefCounted and _role_tick_query.get_script() == RoleQuery: _role_tick_query._expire_admitted_tick()
	var status: Dictionary = _streamed.query_status()
	if not _role_error.is_empty(): status = _role_error
	if not status.get("ok",false):
		_final_sweeps.clear()
		_streamed = previous_helper
		_last_step_status = status
		return []
	if _needs_counter_transaction(state,commands):
		var earned: int = int(candidate.player.level)-int(state.player.level)+(Loot.earned_offer_count(candidate)-Loot.earned_offer_count(state) if Loot.enabled(state) else int(candidate.stats.minibosses_defeated)-int(state.stats.minibosses_defeated))
		if int(candidate.offer_seq)-int(state.offer_seq) != earned:
			_final_sweeps.clear()
			_streamed = previous_helper
			_last_step_status = _failure("counter_exhausted")
			return []
		var checked := restore(candidate,_streamed._hydration)
		if not checked.get("ok",false):
			_final_sweeps.clear()
			_streamed = previous_helper
			_last_step_status = checked
			return []
		candidate = checked.state
	state.clear()
	state.merge(candidate,true)
	_attack_view_cache = _role_view_packet(state,_role_samples)
	_last_step_status = {"ok":true,"navigation":_tick_navigation,"rebase_motion":rebase_motion,"population":population,"role_admission":_role_admission.duplicate(true)}
	return events
func step_status() -> Dictionary: return _last_step_status.duplicate(true)
func _walkable_world(state: Dictionary, point: Vector2, radius: float) -> bool:
	if not is_finite(point.x) or not is_finite(point.y): return false
	if state.has("world") and state.world.stage == "city":
		var result: Dictionary = _streamed.walkable(point,radius)
		return result.get("ok",false) and result.get("walkable",false)
	return World.walkable(point,radius,_finite_geometry(state))
func _nearest_world(state: Dictionary, point: Vector2, radius: float) -> Vector2:
	if not state.has("world") or state.world.stage == "dock": return World.nearest_walkable(point,radius,_finite_geometry(state))
	if _walkable_world(state,point,radius): return point
	for ring in [16.0,32.0,64.0,96.0]:
		for index in 16:
			var nearby: Vector2 = point+Vector2.from_angle(TAU*index/16.0)*ring
			if _walkable_world(state,nearby,radius): return nearby
	return Vector2(INF,INF)
func _move_world(state: Dictionary, point: Vector2, delta: Vector2, radius: float, swept: bool = false) -> Vector2:
	if state.has("world") and state.world.stage == "city":
		var result: Dictionary = _streamed.sweep(point,delta,radius) if swept else _streamed.move(point,delta,radius)
		return result.position if result.get("ok",false) else point
	return World.sweep(point,delta,radius,_finite_geometry(state)) if swept else World.move(point,delta,radius,_finite_geometry(state))
func _movement_target(state: Dictionary, target: Vector2, radius: float, cache: Variant) -> Vector2:
	if cache == null: return _nearest_world(state,target,radius)
	# Never reuse a success across a failed query, helper replacement, geometry
	# change, rebase, tick or actor-count change. Exact target/radius are keys.
	if _streamed._world == null or not _streamed.query_status().get("ok",false) or not is_finite(target.x) or not is_finite(target.y) or not is_finite(radius) or radius < 0 or radius > 32:
		cache.clear()
		return _nearest_world(state,target,radius)
	var world = _streamed._world
	var identity := [_streamed,world,world._world_revision,world._coverage_revision,int(state.active_tick),state.world.world_revision,state.world.origin_revision,state.world.origin_chunk[0],state.world.origin_chunk[1],state.entities.size()]
	if cache.get("identity",[]) != identity:
		cache.clear()
		cache.identity = identity
		cache.targets = {}
	if cache.targets.has(target) and cache.targets[target].has(radius): return cache.targets[target][radius]
	var result := _nearest_world(state,target,radius)
	if is_finite(result.x) and is_finite(result.y) and _streamed.query_status().get("ok",false):
		if not cache.targets.has(target): cache.targets[target] = {}
		cache.targets[target][radius] = result
	else:
		cache.clear()
	return result
# Ordinary city pursuit may retain its saved velocity for at
# most two ticks. This changes AI trajectories; it is not an equivalent cache.
# No helper-local steering history participates in saved-state reconstruction.
func _move_pursuing_enemy(state: Dictionary, entity: Dictionary, movement_targets: Variant = null) -> void:
	var native_scope = null
	if get_script() == load("res://game/core/run_simulation.gd") and state.has("world") and state.world.stage == "city" and _streamed != null and _streamed.get_script() == Streamed:
		native_scope = _streamed._begin_native_pursuit(int(state.active_tick))
	var position := _vec(entity.position)
	var target := _vec(state.player.position)
	var speed := float(entity.speed)
	var previous := _vec(entity.velocity)
	var steering := {}
	var tick := int(state.active_tick)
	if state.has("world") and state.world.stage == "city" and entity.get("boss_id","") == "" and entity.enemy_id != FINAL_ENEMY_ID and entity.action_state == "move" and tick > int(entity.action_started_tick)+1 and speed > 0.0 and not previous.is_zero_approx() and absf(previous.length()-speed) <= 0.001 and (tick+str(entity.id).hash())%3 != 0:
		steering = {"velocity":previous,"speed":speed}
	var direction := _direction_world(state,position,target,float(entity.radius),str(entity.id),movement_targets,steering)
	var velocity: Vector2 = previous if steering.get("reused",false) else direction*speed
	var next := _move_world(state,position,velocity/TICKS_PER_SECOND,float(entity.radius))
	if steering.get("reused",false) and next.distance_to(position+velocity/TICKS_PER_SECOND) > 0.00001 and _streamed.query_status().get("ok",false):
		# Axis movement may shorten a clear diagonal sweep. Retry from the same
		# original position and commit only the final authoritative movement.
		direction = _direction_world(state,position,target,float(entity.radius),str(entity.id),movement_targets)
		velocity = direction*speed
		next = _move_world(state,position,velocity/TICKS_PER_SECOND,float(entity.radius))
	entity.velocity = _array(velocity)
	entity.position = _array(next)
	if not direction.is_zero_approx(): entity.facing = _array(direction)
	if native_scope != null: native_scope.close()
func _direction_world(state: Dictionary, point: Vector2, target: Vector2, radius: float, actor_id: String, movement_targets: Variant = null, steering: Dictionary = {}) -> Vector2:
	if not state.has("world") or state.world.stage == "dock": return _world.direction(point,target,radius,_finite_geometry(state))
	var legal_target := _movement_target(state,target,radius,movement_targets)
	if not is_finite(legal_target.x):
		if _streamed.query_status().get("ok",false):
			_tick_navigation.target_waits += 1
			_tick_navigation.actors.append({"entity_id":actor_id,"reason":"no_legal_target","radius":radius})
		return Vector2.ZERO
	if legal_target != target:
		_tick_navigation.target_adjustments += 1
		_tick_navigation.actors.append({"entity_id":actor_id,"reason":"target_clearance_adjusted","radius":radius,"target":_array(target),"legal_target":_array(legal_target)})
	var direct: Dictionary = _streamed.sweep(point,legal_target-point,radius)
	if not direct.get("ok",false): return Vector2.ZERO
	if float(direct.fraction) == 1.0: return point.direction_to(legal_target)
	if not steering.is_empty():
		var continued: Dictionary = _streamed.sweep(point,steering.velocity/TICKS_PER_SECOND,radius)
		if not continued.get("ok",false): return Vector2.ZERO
		if float(continued.fraction) == 1.0:
			steering.reused = true
			return steering.velocity/float(steering.speed)
	var result: Dictionary = _streamed.direction(point,legal_target,radius,int(state.active_tick),actor_id)
	if not result.get("deferred",false): _tick_navigation.route_queries += 1
	if result.get("blocked",false):
		_tick_navigation["route_deferred" if result.get("deferred",false) else "route_blocked"] += 1
		_tick_navigation.max_route_wait_ticks = maxi(_tick_navigation.max_route_wait_ticks,int(result.wait_ticks))
		_tick_navigation.actors.append({"entity_id":actor_id,"reason":"route_retry_cooldown" if result.get("deferred",false) else "route_blocked","wait_ticks":result.wait_ticks})
	return result.direction if result.get("ok",false) else Vector2.ZERO
func _cover_world(state: Dictionary, origin: Vector2, target: Vector2, radius: float, mask: int) -> Dictionary:
	if not state.has("world"): return {"ok":true,"fraction":1.0}
	if state.world.stage == "city": return _streamed.cover_query(origin,target,radius,mask)
	if mask == 16: return {"ok":true,"fraction":1.0}
	var destination := World.sweep(origin,target-origin,radius,_finite_geometry(state))
	return {"ok":true,"fraction":1.0 if destination.distance_to(target) <= 0.001 else (destination.distance_to(origin)/origin.distance_to(target) if origin != target else 0.0)}
func _cover_clear(state: Dictionary, origin: Vector2, target: Vector2, radius: float, mask: int) -> bool:
	var result := _cover_world(state,origin,target,radius,mask)
	return result.get("ok",false) and float(result.get("fraction",0.0)) == 1.0

# Ordinary role ownership lives in the same fixed-tick transaction as actors.
func _is_live_role(entity: Dictionary) -> bool:
	return entity.get("enemy_id","") in LIVE_ROLE_IDS and entity.get("boss_id","") == ""
func _role_profile(enemy_id: String) -> Dictionary:
	var profile := RoleCatalog.profile(_chapter.enemy_role_catalog,enemy_id) if enemy_id in LIVE_ROLE_IDS else {}
	if get_script() != load("res://game/core/run_simulation.gd"): _normalize_saved_numbers(profile)
	return profile
func _role_query(state: Dictionary, helper = null):
	var live: bool = helper == null and is_same(state,_role_tick_state)
	if live and _role_tick_query != null: return _role_tick_query
	var query
	if state.has("world") and state.world.stage == "city":
		query = RoleQuery.for_streamed(_streamed if helper == null else helper,state)
	else: query = RoleQuery.for_finite(_finite_geometry(state))
	if live: _role_tick_query = query
	return query
func _role_failure(result: Dictionary) -> void:
	if _role_error.is_empty(): _role_error = result.duplicate(true)
func _owned_role_attack(state: Dictionary, source: String) -> Dictionary:
	for attack in state.enemy_attack_instances:
		if attack is Dictionary and attack.get("source_id") is String and attack.source_id == source: return attack
	return {}
func _advance_role_attack(state: Dictionary, entity: Dictionary, _events: Array[Dictionary], movement_targets: Variant = null) -> void:
	var tick := int(state.active_tick)
	var profile := _role_profile(entity.enemy_id)
	var attack := _owned_role_attack(state,str(entity.id))
	if not attack.is_empty():
		if tick >= int(attack.recover_ends_tick):
			state.enemy_attack_instances.erase(attack)
			entity.role_hand_reach = -1.0
			entity.role_wait_since = -1
			entity.role_retry_tick = 0
			entity.attack_kind = "none"
			_set_action(entity,"move",tick,0)
			entity.velocity = [0.0,0.0]
			return
		var result: Dictionary = RoleModel.sample_query(attack,tick,_role_query(state),float(entity.role_hand_reach))
		if not result.get("ok",false): _role_failure(result); return
		var sample: Dictionary = result.sample
		_role_samples[str(entity.id)] = sample
		entity.action_state = sample.phase
		entity.action_started_tick = int(attack.started_tick if sample.phase == "windup" else (attack.active_from_tick if sample.phase == "attack" else attack.attack_ends_tick))
		entity.action_ends_tick = int(attack.active_from_tick if sample.phase == "windup" else (attack.attack_ends_tick if sample.phase == "attack" else attack.recover_ends_tick))
		entity.position = sample.position.duplicate()
		entity.velocity = sample.velocity.duplicate()
		return
	var position := _vec(entity.position)
	var player := _vec(state.player.position)
	if tick >= int(entity.next_action_tick) and position.distance_to(player) <= float(profile.trigger_range):
		var legal: Dictionary = _role_query(state).walkable(position,maxf(float(entity.radius),float(profile.width)*0.5))
		if not legal.get("ok",false): _role_failure(legal); return
		if legal.walkable:
			if int(entity.role_wait_since) < 0:
				entity.role_wait_since = tick
			entity.velocity = [0.0,0.0]
			return
	entity.role_wait_since = -1
	entity.role_retry_tick = 0
	_move_pursuing_enemy(state,entity,movement_targets)
# Waiting is an admission state, not a command to freeze the actor. These
# provisional movement bands stay inside the authored attack trigger; they do
# not change attack reach, damage, reservations or the durable retry clocks.
func _move_waiting_role(state: Dictionary, entity: Dictionary, profile: Dictionary) -> void:
	var band: Vector2 = {"stone_thrower":Vector2(180.0,250.0),"grabber":Vector2(115.0,155.0),"quadruped":Vector2(110.0,145.0)}[entity.enemy_id]
	var position := _vec(entity.position)
	var player := _vec(state.player.position)
	var offset := position-player
	var distance := offset.length()
	var away := offset.normalized() if distance > 0.0001 else -_vec(entity.facing)
	var speed := float(entity.speed)
	var next_distance := move_toward(distance,clampf(distance,band.x,band.y),speed*0.55/TICKS_PER_SECOND)
	# A bounded four-second lateral arc, with smooth reversals. Phase uses only
	# saved wait age and identity, so restore/rebase cannot restart the motion.
	# Differencing the sine avoids a persistent one-direction orbit at rest.
	var phase := (int(state.active_tick)-int(entity.role_wait_since)+str(entity.id).hash()%240)%240
	var angular_scale := speed*0.4*4.0/(TAU*(band.x+band.y)*0.5)
	var angle := angular_scale*(sin(TAU*float(phase)/240.0)-sin(TAU*float(phase-1)/240.0))
	var preferred := player+away.rotated(angle)*next_distance-position
	var mirrored := player+away.rotated(-angle)*next_distance-position
	# Peer bodies are non-solid, as in ordinary chase/spawn/restore. Keep the
	# saved-phase intention stable; only actual terrain/range rejection can
	# select the mirrored arc. No peer score or outward search redirects it.
	var choices: Array[Vector2] = [preferred]
	if mirrored != preferred: choices.append(mirrored)
	# Preserve the legal attack-origin clearance as well as the torso. The
	# existing swept-axis mover supplies wall sliding and transactional failure.
	var radius := maxf(float(entity.radius),float(profile.width)*0.5)
	var next := position
	# At most two finite choices means at most two actual world moves.
	for delta in choices:
		if delta.is_zero_approx(): continue
		var endpoint := _move_world(state,position,delta,radius)
		if _streamed != null and not _streamed.query_status().get("ok",false): break
		# Axis clipping is accepted only at its actual endpoint. Terrain and
		# authored trigger remain hard boundaries, with transactional failure.
		if endpoint.distance_to(player) <= float(profile.trigger_range) and not (endpoint-position).is_zero_approx():
			next = endpoint
			break
	var travelled := next-position
	entity.position = _array(next)
	entity.velocity = _array(travelled*TICKS_PER_SECOND)
	var facing := next.direction_to(player)
	if not facing.is_zero_approx(): entity.facing = _array(facing)
	if travelled.is_zero_approx() and preferred.length() > 0.0001 and _tick_navigation.has("actors"):
		_tick_navigation.actors.append({"entity_id":str(entity.id),"reason":"waiting_reposition_blocked","radius":radius})
func _admit_role_attacks(state: Dictionary, events: Array[Dictionary]) -> void:
	if not _role_error.is_empty() or state.phase != "survival": return
	var eligible: Array[Dictionary] = []
	for entity in state.entities:
		if _is_live_role(entity) and entity.hp > 0 and entity.get("action_state") == "move" and int(entity.get("role_wait_since",-1)) >= 0 and int(entity.role_retry_tick) <= int(state.active_tick): eligible.append(entity)
	eligible.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		if a.role_wait_since != b.role_wait_since: return a.role_wait_since < b.role_wait_since
		var left := _generated_identity_number(a.id)
		var right := _generated_identity_number(b.id)
		if left > 0 and right > 0: return left < right
		if (left > 0) != (right > 0): return left > 0
		return str(a.id) < str(b.id))
	if not eligible.is_empty(): _try_start_role_attack(state,eligible[0],events)
func _try_start_role_attack(state: Dictionary, entity: Dictionary, _events: Array[Dictionary]) -> bool:
	var tick := int(state.active_tick)
	var profile := _role_profile(entity.enemy_id)
	if int(state.attack_seq) >= MAX_COUNTER or tick > MAX_COUNTER-int(profile.warning_ticks)-int(profile.active_ticks)-int(profile.recovery_ticks)-int(profile.cooldown_ticks):
		_role_failure(_failure("counter_exhausted"))
		return false
	var limit := 64 if state.has("world") else 128
	if state.enemy_attack_instances.size() >= limit:
		entity.role_retry_tick = tick+ROLE_RETRY_TICKS
		_role_admission = {"evaluations":0,"accepted":false,"reason":"capacity","work_units":0,"source_id":str(entity.id),"wait_ticks":tick-int(entity.role_wait_since)}
		return false
	var serial := int(state.attack_seq)+1
	var attack_id: String = state.run_id+":enemy:"+str(entity.id)+":"+str(serial)
	var query = _role_query(state)
	var begun: Dictionary = RoleModel.begin_query(entity,state.player,tick,profile,query,attack_id)
	if not begun.get("ok",false):
		if query.status().get("ok",false) and begun.get("error_code") in ["invalid_origin","out_of_range"]:
			entity.role_retry_tick = tick+ROLE_RETRY_TICKS
			_role_admission = {"evaluations":0,"accepted":false,"reason":begun.error_code,"work_units":0,"source_id":str(entity.id),"wait_ticks":tick-int(entity.role_wait_since)}
		else: _role_failure(begun)
		return false
	var attack: Dictionary = begun.attack
	var observations := _observed_legacy_reservations(state,attack)
	var active: Array[Dictionary] = []
	active.assign(state.enemy_attack_instances)
	active.append_array(observations.attacks)
	var caps := {attack_id:float(begun.grab_reach_cap)}
	for owner in state.entities:
		if not _is_live_role(owner): continue
		var owned := _owned_role_attack(state,str(owner.id))
		if not owned.is_empty(): caps[owned.attack_id] = float(owner.role_hand_reach)
	var context := {"tick":tick,"survival_tick":int(state.survival_tick),"reaction_ticks":21,"candidate_wait_since":int(entity.role_wait_since),"geometry_fully_loaded":true,"move_speed":float(state.rules.move_speed)*_catalog.stat(state,"move_multiplier",1.0),"player_radius":float(state.player.radius),"margin":8.0,"max_work_units":8192,"grab_reach_caps":caps,"legacy_cover_modes":observations.cover_modes,"observed_bodies":observations.bodies,"observation_work_units":observations.work_units,"observation_counts":observations.counts}
	var evaluation: Dictionary = RoleBudget.evaluate_query(attack,active,state.player,query,context)
	_role_admission = evaluation.diagnostics.duplicate(true)
	_role_admission.merge({"evaluations":1,"accepted":evaluation.accepted,"reason":evaluation.reason,"observation_counts":observations.counts.duplicate(),"source_id":str(entity.id),"wait_ticks":tick-int(entity.role_wait_since)},true)
	if evaluation.reason == "world_unavailable" or not query.status().get("ok",false):
		var failed: Dictionary = query.status()
		_role_failure(failed if not failed.get("ok",false) else {"ok":false,"error_code":"world_unavailable","diagnostics":evaluation.diagnostics})
		return false
	if evaluation.reason == "invalid_candidate":
		_role_failure({"ok":false,"error_code":"invalid_role_admission","diagnostics":evaluation.diagnostics})
		return false
	if not evaluation.accepted:
		entity.role_retry_tick = tick+ROLE_RETRY_TICKS
		return false
	var sampled: Dictionary = RoleModel.sample_query(attack,tick,query,float(begun.grab_reach_cap))
	if not sampled.get("ok",false): _role_failure(sampled); return false
	state.attack_seq = serial
	state.enemy_attack_instances.append(attack)
	entity.pattern_index = serial
	entity.attack_kind = profile.kind
	entity.role_hand_reach = float(begun.grab_reach_cap)
	entity.role_wait_since = -1
	entity.role_retry_tick = 0
	entity.next_action_tick = int(attack.recover_ends_tick)+int(profile.cooldown_ticks)
	for key in ["locked_origin","locked_direction","locked_target"]: entity[key] = attack[key].duplicate()
	entity.facing = attack.locked_direction.duplicate()
	entity.position = sampled.sample.position.duplicate()
	entity.velocity = [0.0,0.0]
	_set_action(entity,"windup",tick,int(profile.warning_ticks))
	_role_samples[str(entity.id)] = sampled.sample
	return true
func _role_player_damage(state: Dictionary, events: Array[Dictionary]) -> void:
	var attacks: Array = state.enemy_attack_instances.duplicate()
	attacks.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return _role_serial(a) < _role_serial(b))
	var owners := {}
	for entity in state.entities:
		if _is_live_role(entity): owners[str(entity.id)] = entity
	for attack in attacks:
		var source: String = attack.source_id
		if not owners.has(source) or not _role_samples.has(source) or "player" in attack.hit_target_ids: continue
		var sample: Dictionary = _role_samples[source]
		for shape in sample.damage_geometry:
			if not Geometry.overlaps(shape,_vec(state.player.position),float(state.player.radius)): continue
			var visible: Dictionary = RoleModel.visibility_query(sample,_vec(state.player.position),_role_query(state))
			if not visible.get("ok",false): _role_failure(visible); return
			if not visible.visible: continue
			var hp := float(state.player.hp)
			_damage_player(state,float(owners[source].damage),source,events)
			if float(state.player.hp) < hp: attack.hit_target_ids.append("player")
			break
func _role_serial(attack: Dictionary) -> int:
	var id := str(attack.get("attack_id",""))
	var tail := id.substr(id.rfind(":")+1)
	return tail.to_int() if tail.is_valid_int() and str(tail.to_int()) == tail else 0
func _role_owner_valid(state: Dictionary, entity: Dictionary) -> bool:
	if not entity.has("action_state"):
		return _owned_role_attack(state,str(entity.id)).is_empty() and not entity.has("role_hand_reach") and not entity.has("role_wait_since") and not entity.has("role_retry_tick")
	if not entity.get("action_state") in ["move","windup","attack","recover"] or not entity.get("attack_kind") in ["none","grab","charge","throw"]: return false
	for key in ["action_started_tick","action_ends_tick","next_action_tick","pattern_index","role_retry_tick"]:
		if not Catalog.integer_valid(entity.get(key)): return false
	if not Catalog.integer_valid(entity.get("role_wait_since"),-1,int(state.active_tick)) or not Catalog.number_valid(entity.get("role_hand_reach"),-1.0,float(_role_profile(entity.enemy_id).length)): return false
	if entity.action_started_tick > state.active_tick or entity.action_ends_tick < entity.action_started_tick or entity.role_retry_tick > int(state.active_tick)+ROLE_RETRY_TICKS: return false
	for key in ["locked_origin","locked_direction","locked_target","facing"]:
		if not _position_valid(entity.get(key)): return false
	if not is_equal_approx(_vec(entity.facing).length_squared(),1.0) or not is_equal_approx(_vec(entity.locked_direction).length_squared(),1.0): return false
	var attack := _owned_role_attack(state,str(entity.id))
	if attack.is_empty():
		var cooldown: int = int(_role_profile(entity.enemy_id).cooldown_ticks) if int(entity.pattern_index) > 0 and state.phase == "survival" else 0
		if entity.action_ends_tick != entity.action_started_tick or entity.next_action_tick != int(entity.action_started_tick)+cooldown: return false
		if int(entity.role_wait_since) >= 0 and (entity.role_wait_since < entity.action_started_tick or state.active_tick < entity.next_action_tick): return false
		return entity.action_state == "move" and entity.attack_kind == "none" and entity.role_hand_reach == -1.0 and entity.pattern_index <= state.attack_seq and (entity.role_wait_since >= 0 or entity.role_retry_tick == 0)
	if entity.role_wait_since != -1 or entity.role_retry_tick != 0: return false
	if entity.role_hand_reach < 0: return false
	if not RoleModel.validate_checked(attack,_role_profile(entity.enemy_id)).is_empty(): return false
	var tick := int(state.active_tick)
	var serial := _role_serial(attack)
	if serial < 1 or serial > int(state.attack_seq) or entity.pattern_index != serial or attack.attack_id != state.run_id+":enemy:"+str(entity.id)+":"+str(serial): return false
	if attack.started_tick > tick or attack.recover_ends_tick <= tick or attack.recover_ends_tick > MAX_COUNTER-int(attack.profile.cooldown_ticks): return false
	if entity.next_action_tick != int(attack.recover_ends_tick)+int(attack.profile.cooldown_ticks): return false
	var phase := "windup" if tick < attack.active_from_tick else ("attack" if tick < attack.attack_ends_tick else "recover")
	if entity.action_state != phase or entity.attack_kind != attack.kind: return false
	var start: int = attack.started_tick if phase == "windup" else (attack.active_from_tick if phase == "attack" else attack.attack_ends_tick)
	var end: int = attack.active_from_tick if phase == "windup" else (attack.attack_ends_tick if phase == "attack" else attack.recover_ends_tick)
	if entity.action_started_tick != start or entity.action_ends_tick != end: return false
	for key in ["locked_origin","locked_direction","locked_target"]:
		if not _same_json(entity[key],attack[key]): return false
	if _vec(entity.facing).distance_to(_vec(attack.locked_direction)) > 0.0001: return false
	if attack.kind != "charge" and (_vec(entity.position).distance_to(_vec(attack.locked_origin)) > 0.001 or not _vec(entity.velocity).is_zero_approx()): return false
	return true
func _validate_role_attacks(state: Dictionary, validation_helper = null) -> bool:
	if state.enemy_attack_instances.size() > (64 if state.has("world") else 128): return false
	if state.phase != "survival" and not state.enemy_attack_instances.is_empty(): return false
	var actors := {}
	for entity in state.entities: actors[str(entity.id)] = entity
	var ids := {}
	var sources := {}
	var serials := {}
	for attack in state.enemy_attack_instances:
		if not attack is Dictionary or not attack.get("source_id") is String or not actors.has(attack.source_id): return false
		var actor: Dictionary = actors[attack.source_id]
		if not _is_live_role(actor) or actor.hp <= 0 or not _role_owner_valid(state,actor): return false
		if ids.has(attack.attack_id) or sources.has(attack.source_id) or serials.has(_role_serial(attack)): return false
		if attack.hit_target_ids != [] and attack.hit_target_ids != ["player"]: return false
		if not attack.hit_target_ids.is_empty() and state.active_tick < attack.active_from_tick: return false
		ids[attack.attack_id] = true
		sources[attack.source_id] = true
		serials[_role_serial(attack)] = true
	for cast in state.player_attack_instances:
		if serials.has(int(str(cast.cast_id).get_slice(":",str(cast.cast_id).get_slice_count(":")-1))): return false
	for hazard in state.telegraphs:
		if sources.has(str(hazard.get("source_id",""))): return false
	return _role_samples_checked(state,validation_helper).get("ok",false)
func _role_samples_checked(state: Dictionary, helper = null) -> Dictionary:
	var samples := {}
	if state.enemy_attack_instances.is_empty(): return {"ok":true,"samples":samples}
	var owners := {}
	for entity in state.entities: owners[str(entity.id)] = entity
	var query = _role_query(state,helper)
	for attack in state.enemy_attack_instances:
		if not owners.has(attack.source_id): return _failure("invalid_role_owner")
		var result: Dictionary = RoleModel.sample_query(attack,int(state.active_tick),query,float(owners[attack.source_id].role_hand_reach))
		if not result.get("ok",false): return result
		var owner: Dictionary = owners[attack.source_id]
		if _vec(owner.position).distance_to(_vec(result.sample.position)) > 0.03125 or _vec(owner.velocity).distance_to(_vec(result.sample.velocity)) > 0.03125: return _failure("role_motion_mismatch")
		samples[attack.source_id] = result.sample
	return {"ok":true,"samples":samples}
func _role_view_packet(state: Dictionary, samples: Dictionary) -> Dictionary:
	var world: Dictionary = state.get("world",{})
	var packet := {"ok":true,"run_id":state.run_id,"tick":int(state.active_tick),"scene_id":str(world.get("scene_id","finite")),"origin_revision":int(world.get("origin_revision",0)),"world_revision":int(world.get("world_revision",0)),"attacks":[]}
	if state.phase != "survival": return packet
	for attack in state.enemy_attack_instances:
		if not samples.has(attack.source_id): continue
		var sample: Dictionary = samples[attack.source_id]
		var entry := {"attack_id":attack.attack_id,"source_id":attack.source_id,"role_id":attack.role_id}
		for key in ["phase","position","telegraph_geometry","damage_geometry"]: entry[key] = sample[key]
		for key in ["hand_pose","projectile_pose"]:
			if sample.has(key): entry[key] = sample[key]
		packet.attacks.append(entry.duplicate(true))
	return packet
func enemy_attack_view(state: Dictionary) -> Dictionary:
	if not state.has_all(["run_id","active_tick","phase","enemy_attack_instances"]): return {"ok":false,"error_code":"attack_view_unavailable","attacks":[]}
	var expected := _role_view_packet(state,{})
	if state.enemy_attack_instances.is_empty(): return expected
	for key in ["run_id","tick","scene_id","origin_revision","world_revision"]:
		if _attack_view_cache.get(key) != expected[key]:
			expected.ok = false
			expected.error_code = "attack_view_stale"
			return expected
	return _attack_view_cache.duplicate(true)
func _reconcile_role_rebase(source: Dictionary, candidate: Dictionary, original: Dictionary, entity: Dictionary, old_helper, next_helper) -> Dictionary:
	if original.get("action_state") == "move": return {"ok":true}
	if not _role_owner_valid(source,original) or not _role_owner_valid(candidate,entity): return _failure("invalid_core_state")
	var old_attack := _owned_role_attack(source,str(original.id))
	var next_attack := _owned_role_attack(candidate,str(entity.id))
	var before: Dictionary = RoleModel.sample_query(old_attack,int(source.active_tick),_role_query(source,old_helper),float(original.role_hand_reach))
	var after: Dictionary = RoleModel.sample_query(next_attack,int(candidate.active_tick),_role_query(candidate,next_helper),float(entity.role_hand_reach))
	if not before.get("ok",false): return before
	if not after.get("ok",false): return after
	var shift := _vec(entity.locked_origin)-_vec(original.locked_origin)
	if (_vec(before.sample.position)+shift).distance_to(_vec(after.sample.position)) > 0.03125: return _failure("rebase_motion_discontinuity")
	for pose in ["hand_pose","projectile_pose"]:
		if not before.sample.has(pose): continue
		if not after.sample.has(pose): return _failure("rebase_motion_discontinuity")
		for key in before.sample[pose]:
			if before.sample[pose][key] is Array:
				if (_vec(before.sample[pose][key])+shift).distance_to(_vec(after.sample[pose][key])) > 0.03125: return _failure("rebase_motion_discontinuity")
			elif before.sample[pose][key] != after.sample[pose][key]: return _failure("rebase_motion_discontinuity")
	return {"ok":true}
func _observed_legacy_reservations(state: Dictionary, candidate: Dictionary) -> Dictionary:
	var tick := int(state.active_tick)
	var end := int(candidate.attack_ends_tick)
	var occupied := {str(candidate.source_id):true}
	for attack in state.enemy_attack_instances:
		end = maxi(end,int(attack.attack_ends_tick))
		occupied[str(attack.source_id)] = true
	end = mini(end,tick+RoleBudget.MAX_HORIZON+1)
	var observed_ticks := mini(21,maxi(0,end-tick-1))
	var player := _vec(state.player.position)
	var clearance := float(state.player.radius)+8.0
	var reach := float(state.rules.move_speed)*_catalog.stat(state,"move_multiplier",1.0)*float(end-tick-1)/60.0+clearance
	var region := Rect2(player-Vector2.ONE*reach,Vector2.ONE*reach*2.0)
	var counts := {"entity_count":state.entities.size(),"telegraph_count":state.telegraphs.size(),"time_filtered":0,"bounds_filtered":0,"hash_cells":0,"hash_candidates":0,"body_exact_tests":0,"reservation_count":0,"primitive_count":0}
	var owners := {}
	for entity in state.entities: owners[str(entity.id)] = entity
	var reserved := {}
	var modes := {}
	for hazard in state.telegraphs:
		var source := str(hazard.source_id)
		if occupied.has(source): continue
		var owner: Dictionary = owners.get(source,{})
		if not owner.is_empty() and (owner.hp <= 0 or owner.get("action_state") == "recover"): continue
		var start := maxi(tick,int(hazard.active_from_tick))
		var finish := mini(end,int(hazard.expires_tick))
		if finish <= start:
			counts.time_filtered += 1
			continue
		var shapes: Array[Dictionary] = [_role_hazard_geometry(hazard)]
		var cover: Array = ["legacy_mask4" if state.has("world") else "none"]
		if not owner.is_empty() and owner.get("action_state") in ["windup","airborne","attack"]:
			var profile: Dictionary = Behaviors.profile(owner,state.rules.enemy_catalog)
			var point: Vector2 = _vec(owner.locked_target) if owner.attack_kind == "leap" else (_vec(owner.locked_origin) if owner.action_state == "windup" else _vec(owner.position))
			if owner.attack_kind in ["charge","grab"]:
				var steps: int = int(profile.active_ticks) if owner.action_state == "windup" else maxi(0,int(owner.action_ends_tick)-tick-1)
				shapes.append(RoleModel._line(point,point+_vec(owner.locked_direction)*float(profile.rush_speed)*float(steps)/60.0,float(owner.radius)*2.0))
			else: shapes.append({"shape":"circle","origin":_array(point),"radius":float(owner.radius)})
			cover.append("none")
		var nearby: Array[Dictionary] = []
		var nearby_modes := []
		for index in shapes.size():
			if not _role_shape_bounds(shapes[index]).intersects(region,true):
				counts.bounds_filtered += 1
				continue
			nearby.append(shapes[index])
			nearby_modes.append(cover[index])
		if nearby.is_empty(): continue
		if reserved.has(source):
			reserved[source].active_from_tick = mini(reserved[source].active_from_tick,start)
			reserved[source].attack_ends_tick = maxi(reserved[source].attack_ends_tick,finish)
			reserved[source].damage_geometry.append_array(nearby)
			modes[reserved[source].attack_id].append_array(nearby_modes)
		else:
			var id: String = state.run_id+":observed:"+source+":"+str(int(hazard.created_tick))
			reserved[source] = {"legacy_projection":true,"attack_id":id,"source_id":source,"active_from_tick":start,"attack_ends_tick":finish,"threat_cost":2,"damage_geometry":nearby}
			modes[id] = nearby_modes
		counts.primitive_count += nearby.size()
	counts.reservation_count = reserved.size()
	var max_radius := 0.0
	var max_speed := 0.0
	for id in state.rules.enemy_catalog:
		if id in LIVE_ROLE_IDS or id == FINAL_ENEMY_ID: continue
		max_radius = maxf(max_radius,float(state.rules.enemy_catalog[id].radius))
		max_speed = maxf(max_speed,float(state.rules.enemy_catalog[id].speed))
	var radius := max_radius+max_speed*float(observed_ticks)/60.0+clearance
	var minimum := Vector2i(floor((player.x-radius)/_spatial.cell_size),floor((player.y-radius)/_spatial.cell_size))
	var maximum := Vector2i(floor((player.x+radius)/_spatial.cell_size),floor((player.y+radius)/_spatial.cell_size))
	counts.hash_cells = (maximum.x-minimum.x+1)*(maximum.y-minimum.y+1)
	var nearby_indices: Array[int] = _spatial.query(player,radius)
	counts.hash_candidates = nearby_indices.size()
	var bodies := []
	for index in nearby_indices:
		var entity: Dictionary = state.entities[index]
		var source := str(entity.id)
		if _is_live_role(entity) or entity.hp <= 0 or entity.get("action_state") != "move" or reserved.has(source): continue
		counts.body_exact_tests += 1
		var bound := float(entity.radius)+float(entity.speed)*float(observed_ticks)/60.0+clearance
		if _vec(entity.position).distance_to(player) > bound: continue
		bodies.append({"source_id":source,"origin":entity.position.duplicate(),"body_radius":float(entity.radius),"move_speed":float(entity.speed),"observed_until_tick":tick+observed_ticks})
	var work := 0
	for count in counts.values(): work += int(count)
	return {"attacks":reserved.values(),"cover_modes":modes,"bodies":bodies,"counts":counts,"work_units":work}
func _role_hazard_geometry(hazard: Dictionary) -> Dictionary:
	var result := {"shape":hazard.shape,"origin":hazard.origin.duplicate()}
	for key in {"circle":["radius"],"line":["direction","length","width"],"sector":["direction","radius","arc_degrees"]}[hazard.shape]:
		result[key] = hazard.get(key,90.0 if key == "arc_degrees" else 0.0)
	return result
func _role_shape_bounds(shape: Dictionary) -> Rect2:
	var origin := _vec(shape.origin)
	if shape.shape == "line": return Streamed.segment_rect(origin,origin+_vec(shape.direction)*float(shape.length),float(shape.width)*0.5)
	var radius := float(shape.radius)
	return Rect2(origin-Vector2.ONE*radius,Vector2.ONE*radius*2.0)
