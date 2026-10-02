# PIFBot campaign training-area rotation v0.1
#
# Keeps grinding on actual encounter terrain and rotates among nearby encounter
# maps around the city of the next Gym. Route choice uses encounter LEVELS only;
# species remain player-knowledge and are learned by seeing them in battle.
#
# Rotation defaults:
# - sample at least 8 wild encounters on a map
# - after that, rotate once 4 encounters in a row reveal nothing new
# - hard cap of 15 encounters on one map
# - prefer encounter maps whose level range overlaps Gym cap +/- 5
# - if none exist/reachable, fall back to the closest-level nearby maps

module PIFBot
  CAMPAIGN_TRAIN_LEVEL_WINDOW = 5
  CAMPAIGN_TRAIN_MIN_ENCOUNTERS = 8
  CAMPAIGN_TRAIN_STALE_STREAK = 4
  CAMPAIGN_TRAIN_HARD_CAP = 15
  CAMPAIGN_TRAIN_MAP_HOP_LIMIT = 12

  @campaign_training_samples = {}
  @campaign_training_rotate_pending = false
  @campaign_training_failed_maps = {}
  @campaign_training_anchor_map = nil

  def self.campaign_training_reset_rotation
    @campaign_training_samples = {}
    @campaign_training_rotate_pending = false
    @campaign_training_failed_maps = {}
    @campaign_training_anchor_map = nil
  end

  def self.campaign_training_map_name(map_id)
    infos = safe_value({}) { pbLoadMapInfos }
    info = infos ? infos[map_id] : nil
    return safe_value("Map #{map_id}") { info.name.to_s }
  rescue Exception
    return "Map #{map_id}"
  end

  def self.campaign_training_gym_city_map
    gym = campaign_next_gym
    return nil if !gym
    city = gym[:city].to_s.downcase
    infos = safe_value({}) { pbLoadMapInfos }
    return nil if !infos

    exact = nil
    fallback = nil
    infos.each do |map_id, info|
      next if !info
      name = safe_value("") { info.name.to_s }
      low = name.downcase
      exact = map_id if low == "#{city} city" || low == city
      if fallback.nil? && !low.index(city).nil? &&
         low.index("gym").nil? && low.index("center").nil? &&
         low.index("gate").nil? && low.index("mart").nil?
        fallback = map_id
      end
    end
    return exact || fallback
  rescue Exception
    return nil
  end

  def self.campaign_training_encounter_data(map_id)
    version = safe_value(0) { $PokemonGlobal.encounter_version }
    mode = safe_value(GameData::Encounter) {
      $PokemonEncounters ? $PokemonEncounters.getEncounterMode : GameData::Encounter
    }
    data = safe_value(nil) { mode.get(map_id, version) }
    data ||= safe_value(nil) { GameData::Encounter.get(map_id, version) }
    return data
  rescue Exception
    return nil
  end

  def self.campaign_training_level_range(map_id)
    data = campaign_training_encounter_data(map_id)
    return nil if !data

    mins = []
    maxs = []
    weighted_sum = 0.0
    total_weight = 0.0

    safe_value({}) { data.types }.each do |type_id, slots|
      type_data = safe_value(nil) { GameData::EncounterType.get(type_id) }
      next if !type_data
      kind = safe_value(nil) { type_data.type }
      next if kind != :land && kind != :cave

      safe_value([]) { slots }.each do |slot|
        next if !slot || slot.length < 4
        weight = [slot[0].to_f, 1.0].max
        min_level = slot[2].to_i
        max_level = slot[3].to_i
        max_level = min_level if max_level <= 0
        mins.push(min_level)
        maxs.push(max_level)
        weighted_sum += ((min_level + max_level) / 2.0) * weight
        total_weight += weight
      end
    end

    return nil if mins.length == 0
    avg = total_weight > 0 ? weighted_sum / total_weight : (mins.min + maxs.max) / 2.0
    return { :min => mins.min, :max => maxs.max, :avg => avg }
  rescue Exception => e
    append_action_log("ERROR", "training level range: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_training_map_distances(anchor_map)
    return {} if !anchor_map
    distances = { anchor_map => 0 }
    queue = [anchor_map]
    head = 0

    while head < queue.length && distances.length <= CAMPAIGN_MAP_SEARCH_LIMIT
      current = queue[head]
      head += 1
      distance = distances[current]
      next if distance >= CAMPAIGN_TRAIN_MAP_HOP_LIMIT

      center_map_neighbors(current).each do |neighbor|
        next if distances.has_key?(neighbor)
        distances[neighbor] = distance + 1
        queue.push(neighbor)
      end
    end
    return distances
  rescue Exception
    return {}
  end

  def self.campaign_training_map_stats(map_id)
    @campaign_training_samples ||= {}
    @campaign_training_samples[map_id] ||= {
      :encounters => 0,
      :seen => {},
      :stale => 0,
      :last_seen_at => 0
    }
    return @campaign_training_samples[map_id]
  end

  def self.campaign_training_visible_wild_species(battle)
    party = safe_value([]) { battle.pbParty(1) }
    pkmn = party.compact[0] if party
    return safe_value(nil) { pkmn.species } if pkmn

    battlers = safe_value([]) { battle.battlers }
    visible = battlers.find do |b|
      b && safe_value(false) { b.opposes? } && !safe_value(false) { b.fainted? }
    end
    return safe_value(nil) { visible.pokemon.species } if visible
    return nil
  rescue Exception
    return nil
  end

  def self.campaign_training_observe_wild(battle)
    return if !campaign_active?
    return if safe_value(nil) { @campaign_phase } != :training
    return if !safe_value(false) { battle.wildBattle? }
    map_id = safe_value(nil) { $game_map.map_id }
    return if !map_id

    stats = campaign_training_map_stats(map_id)
    stats[:encounters] += 1
    species = campaign_training_visible_wild_species(battle)
    is_new = species && !stats[:seen].has_key?(species)

    if species
      stats[:seen][species] = true
      stats[:stale] = is_new ? 0 : stats[:stale] + 1
    else
      stats[:stale] += 1
    end
    stats[:last_seen_at] = Time.now.to_i

    rotate = false
    reason = nil
    if stats[:encounters] >= CAMPAIGN_TRAIN_HARD_CAP
      rotate = true
      reason = "hard cap #{CAMPAIGN_TRAIN_HARD_CAP}"
    elsif stats[:encounters] >= CAMPAIGN_TRAIN_MIN_ENCOUNTERS &&
          stats[:stale] >= CAMPAIGN_TRAIN_STALE_STREAK
      rotate = true
      reason = "#{stats[:stale]} encounters without a new species"
    end

    append_action_log(
      "CAMPAIGN_TRAIN",
      "#{campaign_training_map_name(map_id)} sample #{stats[:encounters]} | " +
      "seen #{stats[:seen].length} unique | stale #{stats[:stale]}" +
      (is_new ? " | NEW #{species}" : "")
    )

    if rotate
      @campaign_training_rotate_pending = true
      append_action_log(
        "CAMPAIGN_TRAIN",
        "rotation queued from #{campaign_training_map_name(map_id)} | #{reason}"
      )
    end
  rescue Exception => e
    append_action_log("ERROR", "training encounter sample: #{e.class}: #{e.message}")
  end

  def self.campaign_training_candidates(exclude_map = nil)
    anchor = campaign_training_gym_city_map
    anchor ||= safe_value(nil) { $game_map.map_id }
    return [] if !anchor
    @campaign_training_anchor_map = anchor

    distances = campaign_training_map_distances(anchor)
    cap = campaign_target_level
    low = [1, cap - CAMPAIGN_TRAIN_LEVEL_WINDOW].max
    high = cap + CAMPAIGN_TRAIN_LEVEL_WINDOW
    candidates = []

    distances.each do |map_id, hops|
      next if exclude_map && map_id == exclude_map
      next if @campaign_training_failed_maps && @campaign_training_failed_maps[map_id]
      range = campaign_training_level_range(map_id)
      next if !range

      # "Within 5 levels" means the route's encounter range overlaps the
      # Gym-cap window. If no such map is accessible, the sorter below allows
      # the closest lower/higher area as a fallback.
      in_window = range[:max] >= low && range[:min] <= high
      level_distance = if in_window
                         0.0
                       elsif range[:max] < low
                         (low - range[:max]).to_f
                       else
                         (range[:min] - high).to_f
                       end
      sample = campaign_training_map_stats(map_id)
      candidates.push({
        :map_id => map_id,
        :name => campaign_training_map_name(map_id),
        :hops => hops,
        :range => range,
        :in_window => in_window,
        :level_distance => level_distance,
        :sampled => sample[:encounters]
      })
    end

    has_window = candidates.any? { |entry| entry[:in_window] }
    pool = has_window ? candidates.select { |entry| entry[:in_window] } : candidates
    pool.sort_by! do |entry|
      # Unsampled maps first so the bot actually surveys different encounter
      # pools; then favor level fit and geographic closeness.
      sampled_penalty = entry[:sampled] > 0 ? 1 : 0
      [
        sampled_penalty,
        entry[:level_distance],
        entry[:sampled],
        entry[:hops],
        entry[:map_id]
      ]
    end
    return pool
  rescue Exception => e
    append_action_log("ERROR", "training candidate maps: #{e.class}: #{e.message}")
    return []
  end

  def self.campaign_choose_next_training_map(exclude_current = true)
    current = safe_value(nil) { $game_map.map_id }
    candidates = campaign_training_candidates(exclude_current ? current : nil)
    return nil if candidates.length == 0

    # Prefer a map for which the current world router can actually produce a
    # route. This also naturally rejects story-locked/unreachable candidates.
    candidates[0, 12].each do |entry|
      path = safe_value(nil) { campaign_plan_path_to_map(entry[:map_id]) }
      next if !path
      append_action_log(
        "CAMPAIGN_TRAIN",
        "selected #{entry[:name]} | levels #{entry[:range][:min]}-#{entry[:range][:max]} | " +
        "Gym cap #{campaign_target_level} +/-#{CAMPAIGN_TRAIN_LEVEL_WINDOW} | " +
        "#{entry[:hops]} map hops | prior encounters #{entry[:sampled]}"
      )
      return entry[:map_id]
    end
    return nil
  rescue Exception => e
    append_action_log("ERROR", "choose training map: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_begin_training_rotation
    current = safe_value(nil) { $game_map.map_id }
    tries = 0
    while tries < 8
      target = campaign_choose_next_training_map(true)
      break if !target

      if campaign_begin_route(target, "rotate training area for encounter variety")
        @campaign_training_map = target
        @campaign_training_rotate_pending = false
        @campaign_training_path = []
        @campaign_phase = :travel_training
        return true
      end

      @campaign_training_failed_maps ||= {}
      @campaign_training_failed_maps[target] = true
      tries += 1
    end

    @campaign_training_rotate_pending = false
    append_action_log(
      "CAMPAIGN_TRAIN",
      "no alternate reachable training map found from #{campaign_training_map_name(current)}; continuing current area"
    )
    return false
  rescue Exception => e
    append_action_log("ERROR", "training rotation: #{e.class}: #{e.message}")
    @campaign_training_rotate_pending = false
    return false
  end

  # Outdoor grinding is intentionally stricter than the game's generic helper:
  # stay on land_wild_encounters terrain (grass/etc.). Cave interiors may use
  # ordinary walkable tiles because the engine defines cave encounters map-wide.
  def self.campaign_training_encounter_tile?(x, y)
    return false if !$game_map
    return false if !safe_value(false) { $game_map.valid?(x, y) }

    terrain = safe_value(nil) { $game_map.terrain_tag(x, y) }
    return false if !terrain
    return false if safe_value(false) { terrain.ice }

    metadata = safe_value(nil) { GameData::MapMetadata.try_get($game_map.map_id) }
    outdoor = safe_value(false) { metadata.outdoor_map }

    if outdoor
      return safe_value(false) {
        $PokemonEncounters.has_land_encounters? && terrain.land_wild_encounters
      }
    end

    return true if safe_value(false) { $PokemonEncounters.has_cave_encounters? }
    return safe_value(false) {
      $PokemonEncounters.has_land_encounters? && terrain.land_wild_encounters
    }
  rescue Exception
    return false
  end

  def self.campaign_training_choose_direction
    return nil if !$game_player

    # Entering a route/gate can place the player on pavement. One connector
    # path to the nearest encounter tile is allowed. Once on encounter terrain,
    # grinding NEVER voluntarily steps back onto non-encounter terrain.
    if !campaign_current_tile_has_encounters?
      if !@campaign_training_path || @campaign_training_path.length == 0
        @campaign_training_path = campaign_path_to_nearest_encounter_tile(false) || []
        append_action_log(
          "CAMPAIGN_TRAIN",
          "entering encounter terrain | connector #{@campaign_training_path.length} steps"
        ) if @campaign_training_path.length > 0
      end
      return @campaign_training_path.shift if @campaign_training_path.length > 0
      return nil
    end

    @campaign_training_path = []
    directions = [2, 4, 6, 8]
    encounter_safe = directions.select do |dir|
      next false if !navigation_safe_direction?(dir)
      xy = navigation_destination($game_player.x, $game_player.y, dir)
      campaign_training_encounter_tile?(xy[0], xy[1])
    end

    if encounter_safe.length > 0
      rotated = directions.rotate((@nav_steps || 0) % directions.length)
      encounter_safe.sort_by! do |dir|
        xy = navigation_destination($game_player.x, $game_player.y, dir)
        visits = @nav_visit_counts[navigation_tile_key(xy[0], xy[1])] || 0
        straight = (dir == @nav_last_direction) ? 0 : 1
        [visits, straight, rotated.index(dir) || 99]
      end
      return encounter_safe[0]
    end

    # Do not wander over pavement to another grass patch. Treat an exhausted or
    # isolated patch as a reason to survey a different nearby encounter map.
    @campaign_training_rotate_pending = true
    append_action_log("CAMPAIGN_TRAIN", "encounter patch has no safe adjacent encounter tile; rotate area")
    return nil
  rescue Exception => e
    append_action_log("ERROR", "strict training direction: #{e.class}: #{e.message}")
    return nil
  end

  class << self
    unless method_defined?(:pifbot_train_rotation_original_navigation_start)
      alias_method :pifbot_train_rotation_original_navigation_start, :navigation_start
    end

    def navigation_start
      result = pifbot_train_rotation_original_navigation_start
      if result
        campaign_training_reset_rotation
        # Never carry an old expansion target across a fresh F10 session.
        @campaign_expand_until_owned_count = nil
        @campaign_expansion_reason = nil
      end
      return result
    end

    unless method_defined?(:pifbot_train_rotation_original_navigation_record_wild_battle)
      alias_method :pifbot_train_rotation_original_navigation_record_wild_battle, :navigation_record_wild_battle
    end

    def navigation_record_wild_battle(battle)
      already_seen = @nav_seen_battles && battle && @nav_seen_battles[battle.object_id]
      pifbot_train_rotation_original_navigation_record_wild_battle(battle)
      if battle && !already_seen && safe_value(false) { battle.wildBattle? }
        campaign_training_observe_wild(battle)
      end
    end

    unless method_defined?(:pifbot_train_rotation_original_campaign_find_nearest_training_map)
      alias_method :pifbot_train_rotation_original_campaign_find_nearest_training_map, :campaign_find_nearest_training_map
    end

    def campaign_find_nearest_training_map(start_map = nil)
      # Campaign training should be tied to the next Gym, not merely whatever
      # encounter map happens to be closest to the player's current tile.
      selected = campaign_choose_next_training_map(false)
      return selected if selected
      return pifbot_train_rotation_original_campaign_find_nearest_training_map(start_map)
    end

    unless method_defined?(:pifbot_train_rotation_original_navigation_update)
      alias_method :pifbot_train_rotation_original_navigation_update, :navigation_update
    end

    def navigation_update
      if campaign_active? &&
         safe_value(nil) { @campaign_phase } == :training &&
         @campaign_training_rotate_pending &&
         !(respond_to?(:center_return_active?) && center_return_active?) &&
         navigation_can_update?
        return if campaign_begin_training_rotation
      end
      return pifbot_train_rotation_original_navigation_update
    end
  end
end
