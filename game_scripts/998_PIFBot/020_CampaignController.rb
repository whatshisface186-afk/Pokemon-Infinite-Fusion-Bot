# PIFBot campaign controller v0.1
#
# F10 is now the real spectator/campaign toggle. The old 10-wild-battle
# self-test is intentionally superseded rather than moved to another key.
#
# Current campaign loop:
# - Detect the next Kanto Gym from badge count.
# - Read Infinite Fusion's own current level cap.
# - Train the selected party to that cap.
# - If necessary, route to a nearby map that has land/cave encounters.
# - Route to the next Gym by map data rather than hard-coded map IDs.
# - Inside the Gym, seek the correct leader event and start the battle.
# - Track Gym losses; after 3 losses automatically review/rebuild the owned
#   roster, and if there is not enough roster variety, enter expansion mode
#   where unique catches are prioritized before rebuilding again.
#
# Deliberate staged limitations:
# - Required story-objective solving between later Gyms is not fully generalized
#   yet. The world router will stop with a clear reason when progression needs a
#   scripted objective it cannot yet solve.
# - Existing owned Pokemon can be selected from PC automatically now.
# - Fusion execution/buying/TM/held-item automation is authorized by the user
#   but is being added as separate tested layers rather than hidden inside this
#   first campaign state-machine patch.

module PIFBot
  CAMPAIGN_STATUS_PATH = "Data/pif_bot_campaign.txt"
  CAMPAIGN_TEAM_REVIEW_PATH = "Data/pif_bot_team_review.txt"

  # Official Kanto leader order used by Infinite Fusion's GYM_LEADERS_TYPES.
  CAMPAIGN_KANTO_GYMS = [
    { :leader => "Brock",    :trainer_type => :LEADER_Brock,    :city => "Pewter" },
    { :leader => "Misty",    :trainer_type => :LEADER_Misty,    :city => "Cerulean" },
    { :leader => "Lt. Surge",:trainer_type => :LEADER_Surge,    :city => "Vermilion" },
    { :leader => "Erika",    :trainer_type => :LEADER_Erika,    :city => "Celadon" },
    { :leader => "Koga",     :trainer_type => :LEADER_Koga,     :city => "Fuchsia" },
    { :leader => "Sabrina",  :trainer_type => :LEADER_Sabrina,  :city => "Saffron" },
    { :leader => "Blaine",   :trainer_type => :LEADER_Blaine,   :city => "Cinnabar" },
    { :leader => "Giovanni", :trainer_type => :LEADER_Giovanni, :city => "Viridian" }
  ]

  CAMPAIGN_ROUTE_MAX_NODES = 30000
  CAMPAIGN_MAP_SEARCH_LIMIT = 160
  CAMPAIGN_REBUILD_LOSS_LIMIT = 3
  CAMPAIGN_EXPANSION_CATCH_TARGET = 3

  @campaign_phase = nil
  @campaign_target_gym_map = nil
  @campaign_training_map = nil
  @campaign_route_path = []
  @campaign_route_goal_map = nil
  @campaign_route_reason = nil
  @campaign_route_replans = 0
  @campaign_gym_path = []
  @campaign_gym_event_id = nil
  @campaign_gym_losses = 0
  @campaign_last_badge_count = nil
  @campaign_seen_battles = {}
  @campaign_current_battle_gym_leader = false
  @campaign_current_battle_target = nil
  @campaign_expand_until_owned_count = nil
  @campaign_expansion_reason = nil
  @campaign_required_gym_party_size = nil
  @campaign_training_path = []
  @campaign_last_status_write = 0.0

  def self.campaign_active?
    return navigation_active?
  end

  def self.campaign_next_gym
    return nil if !$Trainer
    count = safe_value(0) { $Trainer.badge_count }
    return nil if count < 0 || count >= CAMPAIGN_KANTO_GYMS.length
    return CAMPAIGN_KANTO_GYMS[count]
  end

  def self.campaign_target_level
    return safe_value(100) { getCurrentLevelCap() }
  rescue Exception
    count = safe_value(0) { $Trainer.badge_count }
    return safe_value(100) { Settings::LEVEL_CAPS_KANTO[count] || 100 }
  end

  def self.campaign_selected_team
    return [] if !$Trainer
    return safe_value([]) { $Trainer.party }.compact
  end

  # Gym battles restrict the player to the leader's party size. Derive that
  # size from Infinite Fusion's trainer data rather than hard-coding Brock=2,
  # Misty=2, etc. Randomized Gym generation preserves the base trainer's team
  # length, so this remains useful in randomized runs.
  def self.campaign_gym_party_size
    learned = safe_value(0) { @campaign_required_gym_party_size.to_i }
    return learned if learned > 0

    gym = campaign_next_gym
    return 1 if !gym

    matches = []
    safe_value({}) { GameData::Trainer.list_all }.each_value do |trainer|
      next if !trainer
      next if safe_value(nil) { trainer.trainer_type } != gym[:trainer_type]
      matches.push(trainer)
    end
    return 1 if matches.length == 0

    primary = matches.find { |trainer| safe_value(-1) { trainer.version } == 0 }
    primary ||= matches.min_by { |trainer| safe_value(9999) { trainer.version } }
    count = safe_value(1) { primary.pokemon.length }
    count = 1 if count <= 0
    @campaign_required_gym_party_size = count
    return count
  rescue Exception
    return 1
  end

  def self.campaign_gym_team
    team = campaign_selected_team
    needed = campaign_gym_party_size
    return [] if team.length < needed

    indexes = (0...team.length).to_a
    ranked = campaign_rank_party_indexes(indexes, needed) if respond_to?(:campaign_rank_party_indexes)
    ranked ||= indexes[0, needed]
    return ranked.map { |idx| team[idx] }.compact
  rescue Exception
    return team[0, needed]
  end

  def self.campaign_team_ready?
    team = campaign_gym_team
    return false if team.length < campaign_gym_party_size
    cap = campaign_target_level
    team.each do |pkmn|
      return false if safe_value(0) { pkmn.level } < cap
    end
    return true
  end

  def self.campaign_owned_entries
    entries = []
    if $Trainer
      safe_value([]) { $Trainer.party }.each_with_index do |pkmn, index|
        next if !pkmn
        entries.push({ :pokemon => pkmn, :where => :party, :index => index })
      end
    end
    if $PokemonStorage
      for box in 0...$PokemonStorage.maxBoxes
        for slot in 0...$PokemonStorage.maxPokemon(box)
          pkmn = safe_value(nil) { $PokemonStorage[box, slot] }
          next if !pkmn
          entries.push({ :pokemon => pkmn, :where => :pc, :box => box, :slot => slot })
        end
      end
    end
    return entries
  rescue Exception
    return []
  end

  def self.campaign_owned_count
    return campaign_owned_entries.length
  end

  def self.campaign_expanding_roster?
    target = @campaign_expand_until_owned_count
    return false if !target
    return campaign_owned_count < target
  end

  def self.campaign_map_has_land_encounters?(map_id)
    return false if !map_id
    version = safe_value(0) { $PokemonGlobal.encounter_version }
    mode = safe_value(GameData::Encounter) {
      $PokemonEncounters ? $PokemonEncounters.getEncounterMode : GameData::Encounter
    }
    data = safe_value(nil) { mode.get(map_id, version) }
    data = safe_value(nil) { GameData::Encounter.get(map_id, version) } if !data
    return false if !data

    safe_value({}) { data.types }.each_key do |type_id|
      encounter_type = safe_value(nil) { GameData::EncounterType.get(type_id) }
      next if !encounter_type
      kind = safe_value(nil) { encounter_type.type }
      return true if kind == :land || kind == :cave
    end
    return false
  rescue Exception
    return false
  end

  def self.campaign_training_encounter_tile?(x, y)
    return false if !$game_map
    return false if !safe_value(false) { $game_map.valid?(x, y) }

    terrain = safe_value(nil) { $game_map.terrain_tag(x, y) }
    return false if !terrain
    return false if safe_value(false) { terrain.ice }

    # Match Infinite Fusion's encounter_possible_here? logic: cave maps can
    # encounter on ordinary walkable tiles; land maps require a terrain tag
    # explicitly marked for land wild encounters.
    return true if safe_value(false) { $PokemonEncounters.has_cave_encounters? }
    return safe_value(false) { terrain.land_wild_encounters }
  rescue Exception
    return false
  end

  def self.campaign_current_tile_has_encounters?
    return false if !$game_player
    return campaign_training_encounter_tile?($game_player.x, $game_player.y)
  end

  def self.campaign_path_to_nearest_encounter_tile(exclude_current = false)
    return nil if !$game_map || !$game_player
    map_id = $game_map.map_id
    start = [map_id, $game_player.x, $game_player.y]
    return [] if !exclude_current && campaign_training_encounter_tile?(start[1], start[2])

    queue = [start]
    head = 0
    parent = { center_state_key(start) => nil }
    direction_from_parent = {}
    visited = 0
    max_nodes = 6000

    while head < queue.length && visited < max_nodes
      current = queue[head]
      head += 1
      visited += 1

      [2, 4, 6, 8].each do |direction|
        neighbor = center_neighbor(current, direction, [map_id], nil)
        next if !neighbor || neighbor[0] != map_id
        nkey = center_state_key(neighbor)
        next if parent.has_key?(nkey)

        parent[nkey] = center_state_key(current)
        direction_from_parent[nkey] = direction

        if campaign_training_encounter_tile?(neighbor[1], neighbor[2])
          directions = []
          walk = nkey
          while parent[walk]
            directions.unshift(direction_from_parent[walk])
            walk = parent[walk]
          end
          return directions
        end
        queue.push(neighbor)
      end
    end
    return nil
  rescue Exception => e
    append_action_log("ERROR", "training grass path: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_training_choose_direction
    return nil if !$game_player

    # If a route transition or battle leaves us off encounter terrain, walk
    # directly back to the nearest encounter-capable tile instead of wandering
    # around pavement while "grinding".
    if !campaign_current_tile_has_encounters?
      if !@campaign_training_path || @campaign_training_path.length == 0
        @campaign_training_path = campaign_path_to_nearest_encounter_tile(false) || []
        append_action_log(
          "CAMPAIGN_TRAIN",
          "seeking encounter terrain | path #{@campaign_training_path.length}"
        ) if @campaign_training_path.length > 0
      end
      return @campaign_training_path.shift if @campaign_training_path.length > 0
      return nil
    end

    @campaign_training_path = []

    directions = [2, 4, 6, 8]
    grass_safe = directions.select do |dir|
      next false if !navigation_safe_direction?(dir)
      xy = navigation_destination($game_player.x, $game_player.y, dir)
      campaign_training_encounter_tile?(xy[0], xy[1])
    end

    if grass_safe.length > 0
      rotated = directions.rotate((@nav_steps || 0) % directions.length)
      grass_safe.sort_by! do |dir|
        xy = navigation_destination($game_player.x, $game_player.y, dir)
        visits = @nav_visit_counts[navigation_tile_key(xy[0], xy[1])] || 0
        straight = (dir == @nav_last_direction) ? 0 : 1
        [visits, straight, rotated.index(dir) || 99]
      end
      return grass_safe[0]
    end

    # Rare isolated grass tile: find another encounter tile, allowing a short
    # connector across non-grass only when staying in the current patch is
    # impossible.
    @campaign_training_path = campaign_path_to_nearest_encounter_tile(true) || []
    return @campaign_training_path.shift if @campaign_training_path.length > 0
    return nil
  rescue Exception => e
    append_action_log("ERROR", "training direction: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_find_nearest_training_map(start_map = nil)
    start_map ||= safe_value(nil) { $game_map.map_id }
    return nil if !start_map
    return start_map if campaign_map_has_land_encounters?(start_map)

    center_reset_plan_cache if respond_to?(:center_reset_plan_cache)
    queue = [start_map]
    seen = { start_map => true }
    head = 0

    while head < queue.length && seen.length <= CAMPAIGN_MAP_SEARCH_LIMIT
      current = queue[head]
      head += 1
      center_map_neighbors(current).each do |neighbor|
        next if seen[neighbor]
        seen[neighbor] = true
        return neighbor if campaign_map_has_land_encounters?(neighbor)
        queue.push(neighbor)
      end
    end
    return nil
  rescue Exception => e
    append_action_log("ERROR", "campaign training map search: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_find_gym_map(gym = nil)
    gym ||= campaign_next_gym
    return nil if !gym

    infos = safe_value({}) { pbLoadMapInfos }
    return nil if !infos
    city = gym[:city].downcase
    leader = gym[:leader].downcase
    candidates = []

    infos.each do |map_id, info|
      next if !info
      name = safe_value("") { info.name.to_s }
      low = name.downcase
      next if low.index("gym").nil?
      score = 0
      score += 100 if !low.index(city).nil?
      score += 30 if !low.index(leader).nil?
      score += 10 if low == "#{city} gym"
      candidates.push([score, map_id, name])
    end

    candidates.sort_by! { |entry| [-entry[0], entry[1]] }
    best = candidates.find { |entry| entry[0] >= 100 }
    best ||= candidates.find { |entry| entry[0] >= 30 }
    return best ? best[1] : nil
  rescue Exception => e
    append_action_log("ERROR", "campaign gym map lookup: #{e.class}: #{e.message}")
    return nil
  end

  # Plan until the first tile state inside goal_map_id, rather than requiring
  # a hard-coded coordinate. Transfer events and seamless boundaries are both
  # handled by the already-tested world-neighbor primitive.
  def self.campaign_plan_path_to_map(goal_map_id)
    return nil if !$game_map || !$game_player || !goal_map_id
    return [] if $game_map.map_id == goal_map_id

    center_reset_plan_cache if respond_to?(:center_reset_plan_cache)
    map_route = center_map_route($game_map.map_id, goal_map_id)
    return nil if !map_route

    start = [$game_map.map_id, $game_player.x, $game_player.y]
    queue = [start]
    head = 0
    parent = { center_state_key(start) => nil }
    direction_from_parent = {}
    visited = 0

    while head < queue.length && visited < CAMPAIGN_ROUTE_MAX_NODES
      current = queue[head]
      head += 1
      visited += 1
      current_key = center_state_key(current)

      [2, 4, 6, 8].each do |direction|
        neighbor = center_neighbor(current, direction, map_route, nil)
        next if !neighbor
        nkey = center_state_key(neighbor)
        next if parent.has_key?(nkey)

        parent[nkey] = current_key
        direction_from_parent[nkey] = direction

        if neighbor[0] == goal_map_id
          directions = []
          walk = nkey
          while parent[walk]
            directions.unshift(direction_from_parent[walk])
            walk = parent[walk]
          end
          return directions
        end
        queue.push(neighbor)
      end
    end
    return nil
  rescue Exception => e
    append_action_log("ERROR", "campaign route planning: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_begin_route(goal_map_id, reason)
    return true if $game_map && $game_map.map_id == goal_map_id

    @center_return_blocked_steps = {}
    started = Time.now.to_f
    path = campaign_plan_path_to_map(goal_map_id)
    elapsed = (Time.now.to_f - started) * 1000.0
    if !path
      append_action_log("CAMPAIGN_ROUTE", "no route to map #{goal_map_id} for #{reason}")
      return false
    end

    @campaign_route_goal_map = goal_map_id
    @campaign_route_reason = reason
    @campaign_route_path = path
    @campaign_route_replans = 0
    append_action_log(
      "CAMPAIGN_ROUTE",
      "#{reason} | map #{$game_map.map_id} -> #{goal_map_id} | #{path.length} steps | #{format("%.1f", elapsed)} ms"
    )
    return true
  rescue Exception => e
    append_action_log("ERROR", "campaign begin route: #{e.class}: #{e.message}")
    return false
  end

  def self.campaign_clear_route
    @campaign_route_goal_map = nil
    @campaign_route_reason = nil
    @campaign_route_path = []
    @campaign_route_replans = 0
  end

  def self.campaign_route_update
    goal = @campaign_route_goal_map
    return false if !goal

    if $game_map.map_id == goal
      reason = @campaign_route_reason
      campaign_clear_route
      append_action_log("CAMPAIGN_ROUTE", "arrived | #{reason} | map #{goal}")
      return :arrived
    end

    if !@campaign_route_path || @campaign_route_path.length == 0
      @campaign_route_replans += 1
      if !campaign_begin_route(goal, @campaign_route_reason || "campaign objective")
        return :unreachable
      end
    end

    direction = @campaign_route_path[0]
    state = [$game_map.map_id, $game_player.x, $game_player.y]
    if navigation_move(direction)
      @campaign_route_path.shift
      return :moving
    end

    center_block_step(state, direction, "campaign route movement rejected") if respond_to?(:center_block_step)
    @campaign_route_path = []
    @campaign_route_replans += 1
    append_action_log(
      "CAMPAIGN_ROUTE",
      "blocked map #{state[0]} #{state[1]},#{state[2]} dir=#{direction}; replanning"
    )
    return :moving
  rescue Exception => e
    append_action_log("ERROR", "campaign route update: #{e.class}: #{e.message}")
    return :unreachable
  end

  def self.campaign_event_script_text(event)
    list = safe_value([]) { event.list }
    text = []
    list.each do |cmd|
      next if !cmd
      code = safe_value(-1) { cmd.code }
      if [108, 408, 355, 655].include?(code)
        params = safe_value([]) { cmd.parameters }
        text.push(params[0].to_s) if params && params[0]
      elsif code == 111
        # Script conditional branch: parameters are [12, "script"].
        params = safe_value([]) { cmd.parameters }
        text.push(params[1].to_s) if params && params[0] == 12 && params[1]
      end
    end
    return text.join("\n")
  rescue Exception
    return ""
  end

  def self.campaign_find_leader_event
    gym = campaign_next_gym
    return nil if !gym || !$game_map
    token = gym[:trainer_type].to_s.downcase
    leader = gym[:leader].downcase

    matches = []
    safe_value({}) { $game_map.events }.each_value do |event|
      next if !event
      script = campaign_event_script_text(event).downcase
      next if script.length == 0
      score = 0
      score += 100 if !script.index(token).nil?
      score += 30 if !script.index(leader).nil? && !script.index("trainerbattle").nil?
      matches.push([score, event]) if score > 0
    end
    matches.sort_by! { |entry| -entry[0] }
    return matches.length > 0 ? matches[0][1] : nil
  rescue Exception
    return nil
  end

  def self.campaign_plan_adjacent_to_event(event)
    return nil if !event || !$game_map
    candidates = [
      [event.x, event.y + 1],
      [event.x, event.y - 1],
      [event.x + 1, event.y],
      [event.x - 1, event.y]
    ]
    best = nil
    candidates.each do |xy|
      next if !safe_value(false) { $game_map.valid?(xy[0], xy[1]) }
      target = { :map_id => $game_map.map_id, :x => xy[0], :y => xy[1] }
      path = plan_center_path(target)
      next if !path
      best = path if !best || path.length < best.length
    end
    return best
  rescue Exception
    return nil
  end

  def self.campaign_adjacent_to_event?(event)
    return false if !event || !$game_player
    return ((event.x - $game_player.x).abs + (event.y - $game_player.y).abs) == 1
  end

  def self.campaign_start_event(event)
    return false if !event
    return false if safe_value(false) { pbMapInterpreterRunning? }
    event.start
    append_action_log(
      "CAMPAIGN_GYM",
      "started leader event #{safe_value("?") { event.id }} at #{safe_value("?") { event.x }},#{safe_value("?") { event.y }}"
    )
    return true
  rescue Exception => e
    append_action_log("ERROR", "campaign start leader event: #{e.class}: #{e.message}")
    return false
  end

  def self.campaign_gym_safe_direction?(direction)
    return false if !$game_map || !$game_player
    x = $game_player.x
    y = $game_player.y
    nx, ny = navigation_destination(x, y, direction)
    return false if !safe_value(false) { $game_map.valid?(nx, ny) }
    return false if navigation_event_on_tile?(nx, ny)
    return false if !safe_value(false) { $game_player.passable?(x, y, direction) }
    return true
  rescue Exception
    return false
  end

  def self.campaign_gym_explore_direction
    directions = [2, 4, 6, 8]
    safe = directions.select { |dir| campaign_gym_safe_direction?(dir) }
    return nil if safe.length == 0
    safe.sort_by! do |dir|
      xy = navigation_destination($game_player.x, $game_player.y, dir)
      visits = @nav_visit_counts[navigation_tile_key(xy[0], xy[1])] || 0
      straight = (dir == @nav_last_direction) ? 0 : 1
      [visits, straight]
    end
    return safe[0]
  rescue Exception
    return nil
  end

  def self.campaign_gym_update
    leader_event = campaign_find_leader_event
    if leader_event
      if campaign_adjacent_to_event?(leader_event)
        campaign_start_event(leader_event)
        return
      end

      if @campaign_gym_event_id != safe_value(nil) { leader_event.id } ||
         !@campaign_gym_path || @campaign_gym_path.length == 0
        @campaign_gym_event_id = safe_value(nil) { leader_event.id }
        @campaign_gym_path = campaign_plan_adjacent_to_event(leader_event) || []
        append_action_log(
          "CAMPAIGN_GYM",
          "leader #{campaign_next_gym[:leader]} located | event #{@campaign_gym_event_id} | path #{@campaign_gym_path.length}"
        )
      end

      if @campaign_gym_path.length > 0
        direction = @campaign_gym_path[0]
        if navigation_move(direction)
          @campaign_gym_path.shift
          return
        end
        @campaign_gym_path = []
      end
    end

    # Fallback for puzzle/trainer obstruction: explore the Gym while allowing
    # trainer sight battles. Static event tiles remain blocked.
    direction = campaign_gym_explore_direction
    if direction
      navigation_move(direction)
    else
      navigation_stop("campaign_gym_no_path")
    end
  end

  def self.campaign_roster_score(pkmn, covered_types = [])
    base = safe_value(0.0) { owned_strategy_score(pkmn) }
    fit = safe_value({ :score => 0.0 }) { owned_style_fit(pkmn) }
    types = safe_value([]) { pkmn.types }.uniq
    diversity = types.inject(0.0) { |sum, type| sum + (covered_types.include?(type) ? 0.0 : 3.0) }
    return base + safe_value(0.0) { fit[:score] } + diversity
  end

  def self.campaign_select_best_owned_team(max_size = 6)
    pool = campaign_owned_entries.reject do |entry|
      safe_value(false) { entry[:pokemon].egg? }
    end
    chosen = []
    covered = []

    while chosen.length < max_size && pool.length > 0
      pool.sort_by! { |entry| -campaign_roster_score(entry[:pokemon], covered) }
      pick = pool.shift
      chosen.push(pick)
      safe_value([]) { pick[:pokemon].types }.each do |type|
        covered.push(type) if !covered.include?(type)
      end
    end
    return chosen
  rescue Exception
    return []
  end

  def self.campaign_apply_owned_team(selected)
    return false if !$Trainer || !$PokemonStorage
    return false if !selected || selected.length == 0

    old_party = safe_value([]) { $Trainer.party }.dup
    selected_ids = selected.map { |entry| entry[:pokemon].object_id }
    selected_pc = selected.select { |entry| entry[:where] == :pc }
    displaced = old_party.reject { |pkmn| selected_ids.include?(pkmn.object_id) }

    # Preflight storage capacity BEFORE mutating anything. Selected PC slots will
    # become free too. This guarantees a failed rebuild never loses a Pokemon.
    free_slots = 0
    for box in 0...$PokemonStorage.maxBoxes
      for slot in 0...$PokemonStorage.maxPokemon(box)
        free_slots += 1 if safe_value(nil) { $PokemonStorage[box, slot] }.nil?
      end
    end
    capacity_after_withdraw = free_slots + selected_pc.length
    if capacity_after_withdraw < displaced.length
      append_action_log(
        "CAMPAIGN_TEAM",
        "rebuild skipped: PC lacks #{displaced.length - capacity_after_withdraw} safe storage slot(s)"
      )
      return false
    end

    selected_pc.each do |entry|
      $PokemonStorage.pbDelete(entry[:box], entry[:slot])
    end

    displaced.each do |pkmn|
      stored = $PokemonStorage.pbStoreCaught(pkmn)
      if stored.nil? || stored < 0
        # This should be impossible after preflight; stop rather than continue
        # mutating the team if an unexpected storage rule disagrees.
        append_action_log("CAMPAIGN_TEAM", "unexpected PC store failure during rebuild")
        return false
      end
    end

    $Trainer.party.clear
    selected.each { |entry| $Trainer.party.push(entry[:pokemon]) }

    append_action_log(
      "CAMPAIGN_TEAM",
      "rebuilt party: " + $Trainer.party.map { |p| safe_value("unknown") { p.name } }.join(", ")
    )
    return true
  rescue Exception => e
    append_action_log("ERROR", "campaign apply team: #{e.class}: #{e.message}")
    return false
  end

  def self.campaign_write_team_review(selected = nil, reason = "review")
    selected ||= campaign_select_best_owned_team
    File.open(CAMPAIGN_TEAM_REVIEW_PATH, "wb") do |f|
      f.write("Pokemon Infinite Fusion Bot - Tactician Campaign Team Review\n")
      f.write("Time: #{Time.now}\n")
      f.write("Reason: #{reason}\n")
      f.write("Gym: #{campaign_next_gym ? campaign_next_gym[:leader] : "none"}\n")
      f.write("Level target: #{campaign_target_level}\n")
      f.write("Gym losses this cycle: #{@campaign_gym_losses || 0}\n")
      f.write("Owned Pokemon: #{campaign_owned_count}\n")
      f.write("Team style: #{safe_value("unknown") { tactician_team_style_key }}\n\n")
      f.write("Selected owned team:\n")
      selected.each_with_index do |entry, idx|
        pkmn = entry[:pokemon]
        f.write(
          "#{idx + 1}. #{safe_value("unknown") { pkmn.name }} | #{safe_value("?") { pkmn.species }} | " +
          "Lv#{safe_value("?") { pkmn.level }} | types #{safe_value([]) { pkmn.types }.join("/")} | " +
          "score #{format("%.2f", campaign_roster_score(pkmn, []))} | source #{entry[:where]}\n"
        )
      end
      f.write("\nFusion/team-item automation: authorized; execution layer is staged separately.\n")
    end
  rescue Exception
  end

  def self.campaign_rebuild_team
    selected = campaign_select_best_owned_team
    current_ids = campaign_selected_team.map { |pkmn| pkmn.object_id }
    selected_ids = selected.map { |entry| entry[:pokemon].object_id }
    materially_different = (current_ids - selected_ids).length >= 1 ||
                           (selected_ids - current_ids).length >= 1

    campaign_write_team_review(selected, "three_gym_losses")

    if materially_different && campaign_apply_owned_team(selected)
      @campaign_expand_until_owned_count = nil
      @campaign_expansion_reason = nil
      @campaign_gym_losses = 0
      @campaign_phase = :training
      append_action_log("CAMPAIGN_TEAM", "materially different owned team selected; retraining to cap")
      return
    end

    # If the existing owned roster cannot produce a different team, deliberately
    # broaden the collection before the next review. Capture scoring sees this
    # flag and accepts new non-duplicate roster options more readily.
    @campaign_expand_until_owned_count = campaign_owned_count + CAMPAIGN_EXPANSION_CATCH_TARGET
    @campaign_expansion_reason = :post_losses
    @campaign_gym_losses = 0
    @campaign_phase = :training
    append_action_log(
      "CAMPAIGN_TEAM",
      "owned roster lacks a different solution; catch unique Pokemon until owned count #{@campaign_expand_until_owned_count}"
    )
  end

  def self.campaign_battle_is_target_leader?(battle)
    return false if !battle || safe_value(true) { battle.wildBattle? }
    gym = campaign_next_gym
    return false if !gym

    opponents = safe_value([]) { battle.opponent }
    opponents = [opponents] if !opponents.is_a?(Array)
    opponents.compact.each do |trainer|
      trainer_type = safe_value(nil) { trainer.trainer_type }
      return true if trainer_type == gym[:trainer_type]
      type_id = safe_value(nil) { trainer.trainer_type.id }
      return true if type_id == gym[:trainer_type]
    end
    return false
  rescue Exception
    return false
  end

  def self.campaign_observe_battle(battle)
    return if !battle
    @campaign_seen_battles ||= {}
    key = battle.object_id
    return if @campaign_seen_battles[key]
    @campaign_seen_battles[key] = true

    @campaign_current_battle_gym_leader = campaign_battle_is_target_leader?(battle)
    @campaign_current_battle_target = campaign_next_gym
    if @campaign_current_battle_gym_leader
      append_action_log("CAMPAIGN_GYM", "battle started vs #{campaign_next_gym[:leader]}")
    end
  rescue Exception
  end

  def self.campaign_after_battle_result(decision)
    return if !campaign_active?
    was_leader = @campaign_current_battle_gym_leader == true
    target = @campaign_current_battle_target
    @campaign_current_battle_gym_leader = false
    @campaign_current_battle_target = nil
    return if !was_leader || !target

    case decision
    when 1
      @campaign_last_badge_count = safe_value(0) { $Trainer.badge_count }
      @campaign_phase = :await_badge
      @campaign_gym_losses = 0
      append_action_log("CAMPAIGN_GYM", "defeated #{target[:leader]}; waiting for badge/progression event")
    when 2, 5
      @campaign_gym_losses = (@campaign_gym_losses || 0) + 1
      append_action_log(
        "CAMPAIGN_GYM",
        "lost to #{target[:leader]} | attempt #{@campaign_gym_losses}/#{CAMPAIGN_REBUILD_LOSS_LIMIT}"
      )
      if @campaign_gym_losses >= CAMPAIGN_REBUILD_LOSS_LIMIT
        @campaign_phase = :rebuild_team
      else
        @campaign_phase = :recover_after_loss
      end
    end
    campaign_write_status("battle_result")
  rescue Exception => e
    append_action_log("ERROR", "campaign battle result: #{e.class}: #{e.message}")
  end

  def self.campaign_write_status(reason = "update")
    now = Time.now.to_f
    @campaign_last_status_write = now

    gym = campaign_next_gym
    File.open(CAMPAIGN_STATUS_PATH, "wb") do |f|
      f.write("Pokemon Infinite Fusion Bot - Campaign Mode\n")
      f.write("Time: #{Time.now}\n")
      f.write("Reason: #{reason}\n")
      f.write("Active: #{campaign_active?}\n")
      f.write("Phase: #{@campaign_phase || "none"}\n")
      f.write("Badges: #{safe_value("?") { $Trainer.badge_count }}\n")
      f.write("Next Gym: #{gym ? gym[:leader] : "none"}\n")
      f.write("Gym city: #{gym ? gym[:city] : "none"}\n")
      f.write("Target level: #{campaign_target_level}\n")
      f.write("Gym party size: #{campaign_gym_party_size}\n")
      f.write("Gym losses: #{@campaign_gym_losses || 0}/#{CAMPAIGN_REBUILD_LOSS_LIMIT}\n")
      f.write("Roster expansion active: #{campaign_expanding_roster?}\n")
      f.write("Roster expansion reason: #{@campaign_expansion_reason || "none"}\n")
      f.write("On encounter terrain: #{campaign_current_tile_has_encounters?}\n")
      f.write("Owned Pokemon: #{campaign_owned_count}\n")
      f.write("Route goal map: #{@campaign_route_goal_map || "none"}\n")
      f.write("Route remaining steps: #{(@campaign_route_path || []).length}\n")
      if $game_map
        f.write("Current map: #{safe_value("?") { $game_map.name }} (#{$game_map.map_id})\n")
      end
      f.write("Team:\n")
      campaign_selected_team.each do |pkmn|
        f.write("  #{safe_value("unknown") { pkmn.name }} Lv#{safe_value("?") { pkmn.level }}\n")
      end
    end
  rescue Exception
  end

  # ---------------------------------------------------------------------------
  # Overrides of the old F10 test harness. Existing event hooks dynamically call
  # these methods, so the old 10-battle behavior is discarded without adding a
  # second hotkey or parallel navigator.
  # ---------------------------------------------------------------------------

  def self.navigation_start
    return false if !$Trainer || !$game_map || !$game_player

    @nav_active = true
    @nav_pending_stop = false
    @nav_wild_battles = 0
    @nav_steps = 0
    @nav_start_map_id = safe_value(nil) { $game_map.map_id }
    @nav_start_map_name = safe_value("unknown") { $game_map.name }
    @nav_visit_counts = {}
    @nav_seen_battles = {}
    @nav_last_direction = nil
    @nav_stop_reason = nil
    @nav_randomizer_errors = 0
    @nav_randomizer_error_streak = 0
    @campaign_phase = nil
    @campaign_route_path = []
    @campaign_route_goal_map = nil
    @campaign_route_reason = nil
    @campaign_gym_path = []
    @campaign_gym_event_id = nil
    @campaign_seen_battles = {}
    @campaign_current_battle_gym_leader = false
    @campaign_last_badge_count = safe_value(0) { $Trainer.badge_count }
    @campaign_required_gym_party_size = nil
    @campaign_expand_until_owned_count = nil
    @campaign_expansion_reason = nil
    @campaign_training_path = []

    @nav_capture_history_offset = begin
      File.exist?(CAPTURE_HISTORY_PATH) ? File.size(CAPTURE_HISTORY_PATH) : 0
    rescue Exception
      0
    end
    @nav_action_log_offset = begin
      File.exist?(CONTROL_ACTION_LOG_PATH) ? File.size(CONTROL_ACTION_LOG_PATH) : 0
    rescue Exception
      0
    end
    @nav_history_offset = begin
      File.exist?(NAV_HISTORY_PATH) ? File.size(NAV_HISTORY_PATH) : 0
    rescue Exception
      0
    end

    @nav_visit_counts[navigation_tile_key($game_player.x, $game_player.y)] = 1

    gym = campaign_next_gym
    append_action_log(
      "CAMPAIGN",
      "F10 campaign started | map #{@nav_start_map_name} | next gym #{gym ? gym[:leader] : "none"} | cap #{campaign_target_level}"
    )
    navigation_log("CAMPAIGN START | #{@nav_start_map_name} | F10 stop")
    campaign_write_status("started")
    navigation_write_status("campaign_started")
    write_debug_report("campaign_start") if respond_to?(:write_debug_report)
    return true
  rescue Exception => e
    append_action_log("ERROR", "campaign start: #{e.class}: #{e.message}")
    return false
  end

  def self.navigation_stop(reason = "manual")
    # The legacy test harness used to stop on any non-Center map change.
    # Campaign mode expects map changes, so ignore that obsolete stop request.
    return false if reason == "map_change_event" && campaign_active?

    was_active = navigation_active? || @nav_pending_stop
    @nav_active = false
    @nav_pending_stop = false
    @nav_stop_reason = reason

    if was_active
      navigation_log("CAMPAIGN STOP | #{reason} | wild #{@nav_wild_battles || 0} | steps #{@nav_steps || 0}")
      append_action_log(
        "CAMPAIGN",
        "stopped: #{reason} | wild #{@nav_wild_battles || 0} | steps #{@nav_steps || 0}"
      )
    end
    campaign_write_status(reason)
    navigation_write_status(reason)
    navigation_write_summary(reason)
    write_debug_report("campaign_stop: #{reason}") if respond_to?(:write_debug_report)
    notify_navigation_stop(reason) if was_active && respond_to?(:notify_navigation_stop)
    return true
  rescue Exception
    return false
  end

  def self.navigation_record_wild_battle(battle)
    return if !campaign_active?
    return if !battle

    campaign_observe_battle(battle)
    return if !safe_value(false) { battle.wildBattle? }

    @nav_seen_battles ||= {}
    key = battle.object_id
    return if @nav_seen_battles[key]
    @nav_seen_battles[key] = true
    @nav_randomizer_error_streak = 0
    @nav_wild_battles = (@nav_wild_battles || 0) + 1
    navigation_log("CAMPAIGN WILD #{@nav_wild_battles} | steps #{@nav_steps || 0} | map #{safe_value("?") { $game_map.map_id }}")
    append_action_log("CAMPAIGN_TRAIN", "wild encounter #{@nav_wild_battles}")
    campaign_write_status("wild_battle")
  rescue Exception => e
    append_action_log("ERROR", "campaign battle observe: #{e.class}: #{e.message}")
  end

  def self.campaign_rotate_training_lead
    return false if !$Trainer
    return false if !campaign_active?
    return false if instance_variable_get(:@campaign_phase) != :training

    party = safe_value([]) { $Trainer.party }
    return false if !party || party.length < 2

    lead = party[0]
    return false if !lead

    lead_ratio = respond_to?(:navigation_hp_ratio) ? navigation_hp_ratio(lead) : begin
      total = [safe_value(1) { lead.totalhp }.to_f, 1.0].max
      safe_value(0) { lead.hp }.to_f / total
    end
    return false if lead_ratio >= 0.35 && !safe_value(false) { lead.fainted? }

    cap = campaign_target_level
    gym_ids = safe_value([]) { campaign_gym_team }.map { |pkmn| pkmn.object_id }

    candidates = []
    party.each_with_index do |pkmn, index|
      next if index == 0 || !pkmn
      next if !safe_value(false) { pkmn.able? }

      ratio = respond_to?(:navigation_hp_ratio) ? navigation_hp_ratio(pkmn) : begin
        total = [safe_value(1) { pkmn.totalhp }.to_f, 1.0].max
        safe_value(0) { pkmn.hp }.to_f / total
      end
      next if ratio < 0.60

      needs_levels = safe_value(0) { pkmn.level } < cap ? 1 : 0
      gym_member = gym_ids.include?(pkmn.object_id) ? 1 : 0
      score = safe_value(0.0) { tactician_score(pkmn)[:total] }
      candidates.push([index, pkmn, needs_levels, gym_member, ratio, score])
    end
    return false if candidates.length == 0

    candidates.sort_by! do |entry|
      [-entry[2], -entry[3], -entry[4], -entry[5]]
    end
    pick = candidates[0]
    moved = party.delete_at(pick[0])
    party.unshift(moved)

    append_action_log(
      "TRAINING_ROTATE",
      "#{safe_value("unknown") { lead.name }} at #{format("%.1f", lead_ratio * 100.0)}% HP -> " +
      "#{safe_value("unknown") { moved.name }} at #{format("%.1f", pick[4] * 100.0)}% HP"
    )
    return true
  rescue Exception => e
    append_action_log("ERROR", "training lead rotation: #{e.class}: #{e.message}")
    return false
  end

  def self.navigation_after_battle
    return if !campaign_active?
    campaign_rotate_training_lead
    navigation_log("CAMPAIGN RESUME | battle complete")
    campaign_write_status("battle_complete")
  rescue Exception
  end

  def self.navigation_move(direction)
    return false if !direction || !$game_player

    old_x = $game_player.x
    old_y = $game_player.y
    case direction
    when 2 then $game_player.move_down
    when 4 then $game_player.move_left
    when 6 then $game_player.move_right
    when 8 then $game_player.move_up
    else
      return false
    end

    if $game_player.x != old_x || $game_player.y != old_y
      @nav_steps = (@nav_steps || 0) + 1
      @nav_last_direction = direction
      key = navigation_tile_key($game_player.x, $game_player.y)
      @nav_visit_counts ||= {}
      @nav_visit_counts[key] = (@nav_visit_counts[key] || 0) + 1
      campaign_write_status("walking") if (@nav_steps % 50) == 0
      return true
    end
    return false
  rescue Exception => e
    append_action_log("ERROR", "campaign move: #{e.class}: #{e.message}")
    return false
  end

  def self.navigation_write_status(reason = "update")
    File.open(NAV_STATUS_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Campaign Navigation\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Reason: #{reason}\n\n")
      f.write("State: #{campaign_active? ? "ACTIVE" : "STOPPED"}\n")
      f.write("Toggle key: F10\n")
      f.write("Mode: CAMPAIGN\n")
      f.write("Phase: #{@campaign_phase || "none"}\n")
      f.write("Wild battles this session: #{@nav_wild_battles || 0}\n")
      f.write("Steps this session: #{@nav_steps || 0}\n")
      f.write("Next Gym: #{campaign_next_gym ? campaign_next_gym[:leader] : "none"}\n")
      f.write("Target level: #{campaign_target_level}\n")
      f.write("Gym losses: #{@campaign_gym_losses || 0}/#{CAMPAIGN_REBUILD_LOSS_LIMIT}\n")
      f.write("Last stop reason: #{@nav_stop_reason || "none"}\n")
    end
  rescue Exception
  end

  def self.navigation_write_summary(reason)
    File.open(NAV_SUMMARY_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Campaign Session Summary\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Result: #{reason}\n\n")
      f.write("Wild battles: #{@nav_wild_battles || 0}\n")
      f.write("Overworld steps: #{@nav_steps || 0}\n")
      f.write("Badges: #{safe_value("?") { $Trainer.badge_count }}\n")
      f.write("Next Gym: #{campaign_next_gym ? campaign_next_gym[:leader] : "none"}\n")
      f.write("Target level: #{campaign_target_level}\n")
      f.write("Phase: #{@campaign_phase || "none"}\n")
      f.write("Gym losses: #{@campaign_gym_losses || 0}\n")
    end
  rescue Exception
  end

  def self.campaign_refresh_phase
    gym = campaign_next_gym
    if !gym
      navigation_stop("campaign_kanto_gym_goal_complete")
      return
    end

    if @campaign_phase == :await_badge
      current_badges = safe_value(0) { $Trainer.badge_count }
      if current_badges > (@campaign_last_badge_count || -1)
        append_action_log("CAMPAIGN_GYM", "badge confirmed | total #{current_badges}")
        @campaign_last_badge_count = current_badges
        @campaign_gym_losses = 0
        @campaign_target_gym_map = nil
        @campaign_training_map = nil
        @campaign_required_gym_party_size = nil
        @campaign_expansion_reason = nil
        @campaign_training_path = []
        @campaign_phase = nil
      else
        return
      end
    end

    if @campaign_phase == :recover_after_loss
      return if safe_value(0) { $Trainer.able_pokemon_count } <= 0
      @campaign_phase = nil
    end

    if @campaign_phase == :rebuild_team
      campaign_rebuild_team
      return
    end

    # Never walk into the leader-selection screen with fewer usable roster
    # options than the Gym requires. The Brock debug exposed this immediately:
    # one owned Pokemon cannot satisfy a two-Pokemon Gym entry.
    required_party = campaign_gym_party_size
    if campaign_owned_count < required_party
      changed_requirement = (@campaign_expand_until_owned_count != required_party ||
                             @campaign_expansion_reason != :gym_minimum)
      @campaign_expand_until_owned_count = required_party
      @campaign_expansion_reason = :gym_minimum
      if changed_requirement
        append_action_log(
          "CAMPAIGN_TEAM",
          "next Gym requires #{required_party} Pokemon; owned #{campaign_owned_count}; collecting unique options"
        )
      end
    elsif campaign_selected_team.length < required_party
      selected = campaign_select_best_owned_team
      if selected.length >= required_party
        campaign_apply_owned_team(selected)
      end
    end

    if @campaign_expand_until_owned_count &&
       campaign_owned_count >= @campaign_expand_until_owned_count
      if @campaign_expansion_reason == :gym_minimum
        append_action_log(
          "CAMPAIGN_TEAM",
          "minimum Gym roster reached at #{campaign_owned_count}; stop catching and train the Gym team"
        )
        @campaign_expand_until_owned_count = nil
        @campaign_expansion_reason = nil
        @campaign_phase = nil
      else
        @campaign_phase = :rebuild_team
        return
      end
    end

    return if [:travel_training, :travel_gym, :gym].include?(@campaign_phase)

    # After a three-loss review determines that the owned roster has no
    # materially different answer, catching new unique options is the objective
    # even if the current party is already at the Gym level cap.
    if campaign_expanding_roster?
      if campaign_map_has_land_encounters?($game_map.map_id)
        @campaign_phase = :training
      else
        @campaign_training_map = campaign_find_nearest_training_map
        if !@campaign_training_map
          navigation_stop("campaign_no_expansion_area_route")
        elsif @campaign_training_map == $game_map.map_id
          @campaign_phase = :training
        elsif campaign_begin_route(@campaign_training_map, "travel to catch unique roster options")
          @campaign_phase = :travel_training
        else
          navigation_stop("campaign_expansion_route_unreachable")
        end
      end
      return
    end

    if !campaign_team_ready?
      if campaign_map_has_land_encounters?($game_map.map_id)
        @campaign_phase = :training
      else
        @campaign_training_map = campaign_find_nearest_training_map
        if !@campaign_training_map
          navigation_stop("campaign_no_training_area_route")
          return
        end
        if @campaign_training_map == $game_map.map_id
          @campaign_phase = :training
        elsif campaign_begin_route(@campaign_training_map, "travel to training area")
          @campaign_phase = :travel_training
        else
          navigation_stop("campaign_training_route_unreachable")
        end
      end
      return
    end

    @campaign_target_gym_map ||= campaign_find_gym_map(gym)
    if !@campaign_target_gym_map
      navigation_stop("campaign_gym_map_not_found")
      return
    end

    if $game_map.map_id == @campaign_target_gym_map
      @campaign_phase = :gym
      return
    end

    if campaign_begin_route(@campaign_target_gym_map, "travel to #{gym[:leader]} Gym")
      @campaign_phase = :travel_gym
    else
      navigation_stop("campaign_gym_route_unreachable")
    end
  end

  def self.navigation_update
    return if !campaign_active?
    return if respond_to?(:center_return_active?) && center_return_active?
    return if !navigation_can_update?

    if safe_value(0) { $Trainer.able_pokemon_count } <= 0
      return
    end

    healing_result = navigation_handle_healing
    return if healing_result == :center_return || healing_result == :stopped

    campaign_refresh_phase
    return if !campaign_active?

    case @campaign_phase
    when :training
      if campaign_team_ready? && !campaign_expanding_roster?
        @campaign_phase = nil
        campaign_refresh_phase
        return
      end
      direction = campaign_training_choose_direction
      if direction
        navigation_move(direction)
      else
        @campaign_training_map = campaign_find_nearest_training_map
        if @campaign_training_map && @campaign_training_map != $game_map.map_id &&
           campaign_begin_route(@campaign_training_map, "leave exhausted training tile set")
          @campaign_phase = :travel_training
        else
          navigation_stop("campaign_no_safe_training_moves")
        end
      end

    when :travel_training
      result = campaign_route_update
      if result == :arrived
        @campaign_phase = :training
      elsif result == :unreachable
        navigation_stop("campaign_training_route_blocked")
      end

    when :travel_gym
      result = campaign_route_update
      if result == :arrived
        @campaign_phase = :gym
        @campaign_gym_path = []
        @campaign_gym_event_id = nil
      elsif result == :unreachable
        navigation_stop("campaign_gym_route_blocked")
      end

    when :gym
      campaign_gym_update

    when :await_badge, :recover_after_loss
      # Event scripts/blackout processing own control until the phase can refresh.
      campaign_refresh_phase

    when :rebuild_team
      campaign_rebuild_team

    else
      campaign_refresh_phase
    end

    campaign_write_status("update") if (@nav_steps || 0) % 100 == 0
  rescue Exception => e
    append_action_log("ERROR", "campaign update: #{e.class}: #{e.message}")
    navigation_stop("campaign_error")
  end
end

# Gym battle result needs the battle decision; the older navigator's
# navigation_after_battle hook intentionally does not receive it.
Events.onEndBattle += proc { |_sender, e|
  PIFBot.campaign_after_battle_result(e[0]) if PIFBot.campaign_active?
}
