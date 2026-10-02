# PIFBot Pokemon Center return navigation v0.1
#
# When autonomous navigation detects an injured party between battles, this
# state machine walks to the closest KNOWN/REACHABLE Pokemon Center entrance,
# heals without consuming items, and walks back to the point where grinding
# was interrupted.
#
# "Closest" is selected by actual planned walking-path length among centers the
# save has previously registered. The game's existing pokecenterMapId/X/Y is
# used as a fallback for saves created before this bot started recording centers.
#
# Scope:
# - Uses connected-map walking only; no hidden teleport to the Center.
# - Does not intentionally solve scripted doors/caves/warps yet.
# - If no known Center has a connected walking path, F10 stops safely.
# - If the normal Center entrance event transfers the player inside, heal there
#   and use the game's normal exit_pokemon_center path to return outside.
# - Otherwise, reaching the recorded entrance coordinate is treated as reaching
#   the Center and heals the party there.
#
# This is the first cross-map navigation primitive and will later be reusable
# for normal story/progression routing.

class PokemonGlobalMetadata
  attr_accessor :pifbot_known_centers
end

module PIFBot
  CENTER_PATH_MAX_NODES = 20000

  @center_return_active = false
  @center_return_phase = nil
  @center_return_target = nil
  @center_return_resume = nil
  @center_return_path = []
  @center_return_replans = 0

  def self.center_return_active?
    return @center_return_active == true
  end

  def self.center_key(center)
    return "#{center[:map_id]},#{center[:x]},#{center[:y]}"
  end

  def self.known_centers
    return [] if !$PokemonGlobal
    centers = safe_value(nil) { $PokemonGlobal.pifbot_known_centers }
    centers = [] if !centers.is_a?(Array)

    # Backward-compatible fallback: Infinite Fusion already remembers the last
    # registered Pokemon Center location in these save fields.
    fallback_map = safe_value(-1) { $PokemonGlobal.pokecenterMapId }
    if fallback_map && fallback_map >= 0
      fallback = {
        :map_id => fallback_map,
        :x => safe_value(-1) { $PokemonGlobal.pokecenterX },
        :y => safe_value(-1) { $PokemonGlobal.pokecenterY },
        :direction => safe_value(2) { $PokemonGlobal.pokecenterDirection }
      }
      if fallback[:x] >= 0 && fallback[:y] >= 0 &&
         !centers.any? { |c| center_key(c) == center_key(fallback) }
        centers = centers + [fallback]
      end
    end
    return centers
  rescue Exception
    return []
  end

  def self.record_known_center
    return if !$PokemonGlobal || !$game_map || !$game_player

    center = {
      :map_id => $game_map.map_id,
      :x => $game_player.x,
      :y => $game_player.y,
      :direction => $game_player.direction
    }

    list = safe_value([]) { $PokemonGlobal.pifbot_known_centers }
    list = [] if !list.is_a?(Array)
    list.reject! { |entry| center_key(entry) == center_key(center) }
    list.push(center)
    $PokemonGlobal.pifbot_known_centers = list

    append_action_log(
      "CENTER_MEMORY",
      "registered map #{center[:map_id]} at #{center[:x]},#{center[:y]}"
    )
  rescue Exception => e
    append_action_log("ERROR", "record center: #{e.class}: #{e.message}")
  end

  def self.center_map_neighbors(map_id)
    ret = []
    conns = safe_value([]) { MapFactoryHelper.getMapConnections[map_id] }
    return ret if !conns
    conns.each do |conn|
      other = (conn[0] == map_id) ? conn[3] : conn[0]
      ret.push(other) if other && !ret.include?(other)
    end
    return ret
  rescue Exception
    return []
  end

  def self.center_map_route(start_map, goal_map)
    return [start_map] if start_map == goal_map

    queue = [start_map]
    parent = { start_map => nil }
    head = 0
    found = false

    while head < queue.length
      current = queue[head]
      head += 1
      center_map_neighbors(current).each do |neighbor|
        next if parent.has_key?(neighbor)
        parent[neighbor] = current
        if neighbor == goal_map
          found = true
          break
        end
        queue.push(neighbor)
      end
      break if found
    end

    return nil if !parent.has_key?(goal_map)

    route = []
    cur = goal_map
    while cur
      route.unshift(cur)
      cur = parent[cur]
    end
    return route
  rescue Exception
    return nil
  end

  def self.center_state_key(state)
    return "#{state[0]},#{state[1]},#{state[2]}"
  end

  def self.center_connected_destination(map_id, raw_x, raw_y)
    map = safe_value(nil) { $MapFactory.getMapNoAdd(map_id) }
    return nil if !map
    return [map_id, raw_x, raw_y] if map.valid?(raw_x, raw_y)

    conns = safe_value([]) { MapFactoryHelper.getMapConnections[map_id] }
    return nil if !conns

    conns.each do |conn|
      if conn[0] == map_id
        new_x = raw_x + conn[4] - conn[1]
        new_y = raw_y + conn[5] - conn[2]
        other_id = conn[3]
      else
        new_x = raw_x + conn[1] - conn[4]
        new_y = raw_y + conn[2] - conn[5]
        other_id = conn[0]
      end

      dims = safe_value([0, 0]) { MapFactoryHelper.getMapDims(other_id) }
      next if new_x < 0 || new_y < 0
      next if new_x >= dims[0] || new_y >= dims[1]
      return [other_id, new_x, new_y]
    end

    return nil
  rescue Exception
    return nil
  end

  def self.center_destination_event_blocked?(map, x, y)
    safe_value({}) { map.events }.each_value do |event|
      next if !event
      next if safe_value(true) { event.through }
      next if safe_value("") { event.character_name } == ""
      return true if safe_value(false) { event.at_coordinate?(x, y) }
    end
    return false
  rescue Exception
    return true
  end

  def self.center_neighbor(state, direction, allowed_maps, goal = nil)
    map_id, x, y = state
    map = safe_value(nil) { $MapFactory.getMapNoAdd(map_id) }
    return nil if !map

    raw_x = x + (direction == 6 ? 1 : direction == 4 ? -1 : 0)
    raw_y = y + (direction == 2 ? 1 : direction == 8 ? -1 : 0)

    dest = center_connected_destination(map_id, raw_x, raw_y)
    return nil if !dest
    return nil if !allowed_maps.include?(dest[0])

    dest_map = safe_value(nil) { $MapFactory.getMapNoAdd(dest[0]) }
    return nil if !dest_map

    # Match the core directional tile checks used by Game_Character#passable?.
    return nil if !safe_value(false) { map.passable?(x, y, direction, $game_player) }
    return nil if !safe_value(false) {
      dest_map.passable?(dest[1], dest[2], 10 - direction, $game_player)
    }
    unless goal && dest[0] == goal[0] && dest[1] == goal[1] && dest[2] == goal[2]
      return nil if center_destination_event_blocked?(dest_map, dest[1], dest[2])
    end

    return dest
  rescue Exception
    return nil
  end

  def self.plan_center_path(center, from_state = nil)
    return nil if !$MapFactory || !$game_map || !$game_player || !center

    start = from_state || [$game_map.map_id, $game_player.x, $game_player.y]
    goal = [center[:map_id], center[:x], center[:y]]
    return [] if start == goal

    map_route = center_map_route(start[0], goal[0])
    return nil if !map_route
    allowed_maps = map_route

    queue = [start]
    head = 0
    parent = {}
    parent[center_state_key(start)] = nil
    state_by_key = { center_state_key(start) => start }
    direction_from_parent = {}
    goal_key = center_state_key(goal)
    visited = 0

    while head < queue.length && visited < CENTER_PATH_MAX_NODES
      current = queue[head]
      head += 1
      visited += 1
      current_key = center_state_key(current)

      [2, 4, 6, 8].each do |direction|
        neighbor = center_neighbor(current, direction, allowed_maps, goal)
        next if !neighbor
        nkey = center_state_key(neighbor)
        next if parent.has_key?(nkey)

        parent[nkey] = current_key
        state_by_key[nkey] = neighbor
        direction_from_parent[nkey] = direction

        if nkey == goal_key
          directions = []
          walk_key = nkey
          while parent[walk_key]
            directions.unshift(direction_from_parent[walk_key])
            walk_key = parent[walk_key]
          end
          return directions
        end

        queue.push(neighbor)
      end
    end

    return nil
  rescue Exception => e
    append_action_log("ERROR", "center path: #{e.class}: #{e.message}")
    return nil
  end

  def self.closest_reachable_center
    candidates = known_centers
    return nil if candidates.length == 0

    best = nil
    candidates.each do |center|
      path = plan_center_path(center)
      next if !path
      entry = { :center => center, :path => path, :distance => path.length }
      best = entry if !best || entry[:distance] < best[:distance]
    end
    return best
  rescue Exception
    return nil
  end

  def self.begin_center_return(pkmn = nil)
    return true if center_return_active?
    return false if !$game_map || !$game_player || !$Trainer

    best = closest_reachable_center
    return false if !best

    @center_return_active = true
    @center_return_phase = :to_center
    @center_return_target = best[:center]
    @center_return_resume = {
      :map_id => $game_map.map_id,
      :x => $game_player.x,
      :y => $game_player.y
    }
    @center_return_path = best[:path]
    @center_return_replans = 0

    append_action_log(
      "CENTER_RETURN",
      "#{pkmn ? safe_value("party") { pkmn.name } : "party"} low HP | " +
      "walking #{best[:distance]} planned steps to center on map #{@center_return_target[:map_id]}"
    )
    navigation_log(
      "CENTER RETURN START | target map #{@center_return_target[:map_id]} " +
      "#{@center_return_target[:x]},#{@center_return_target[:y]} | planned #{best[:distance]} steps"
    )
    navigation_write_status("returning_to_pokemon_center")
    return true
  rescue Exception => e
    append_action_log("ERROR", "begin center return: #{e.class}: #{e.message}")
    return false
  end

  def self.center_current_target
    return @center_return_target if @center_return_phase == :to_center
    return @center_return_resume if @center_return_phase == :to_resume
    return nil
  end

  def self.center_at_target?(target)
    return false if !target || !$game_map || !$game_player
    return $game_map.map_id == target[:map_id] &&
           $game_player.x == target[:x] &&
           $game_player.y == target[:y]
  end

  def self.center_inside_target_center?
    return false if @center_return_phase != :to_center
    return false if !$PokemonGlobal || !@center_return_target
    entrance_map = safe_value(nil) { $PokemonGlobal.common_map_entrance_id }
    entrance_pos = safe_value(nil) { $PokemonGlobal.common_map_entrance_position }
    return false if entrance_map != @center_return_target[:map_id]
    return false if !entrance_pos || entrance_pos.length < 2
    return entrance_pos[0] == @center_return_target[:x] &&
           entrance_pos[1] == @center_return_target[:y]
  rescue Exception
    return false
  end

  def self.center_perform_heal
    if $PokemonSystem && $PokemonSystem.respond_to?(:no_pokemon_center) &&
       safe_value(false) { $PokemonSystem.no_pokemon_center }
      append_action_log("CENTER_HEAL", "Pokemon Center healing disabled by challenge options")
      navigation_stop("pokemon_center_healing_disabled")
      @center_return_active = false
      return false
    end

    before = safe_value([]) { $Trainer.party }.map do |pkmn|
      [safe_value("unknown") { pkmn.name }, safe_value(0) { pkmn.hp }, safe_value(0) { pkmn.totalhp }]
    end

    $Trainer.heal_party
    clear_center_heal_request if respond_to?(:clear_center_heal_request)

    append_action_log(
      "CENTER_HEAL",
      "healed party at known Pokemon Center | before " +
      before.map { |e| "#{e[0]} #{e[1]}/#{e[2]}" }.join(", ")
    )
    navigation_log("CENTER HEAL | party restored")
    return true
  rescue Exception => e
    append_action_log("ERROR", "center heal: #{e.class}: #{e.message}")
    navigation_stop("pokemon_center_heal_error")
    @center_return_active = false
    return false
  end

  def self.center_begin_resume
    @center_return_phase = :to_resume
    @center_return_path = plan_center_path(@center_return_resume)
    @center_return_replans = 0

    if !@center_return_path
      append_action_log("CENTER_RETURN", "healed, but no walking path back to resume point")
      navigation_stop("center_no_return_path")
      @center_return_active = false
      return false
    end

    append_action_log(
      "CENTER_RETURN",
      "healed; returning #{@center_return_path.length} planned steps to interrupted position"
    )
    navigation_write_status("returning_from_pokemon_center")
    return true
  end

  def self.center_finish_return
    append_action_log("CENTER_RETURN", "returned to interrupted position; autonomous test resumed")
    navigation_log("CENTER RETURN COMPLETE | resumed test")
    @center_return_active = false
    @center_return_phase = nil
    @center_return_target = nil
    @center_return_resume = nil
    @center_return_path = []
    @center_return_replans = 0
    navigation_write_status("pokemon_center_trip_complete")
  end

  def self.center_replan
    target = center_current_target
    return false if !target
    @center_return_path = plan_center_path(target)
    @center_return_replans ||= 0
    @center_return_replans += 1
    return !@center_return_path.nil?
  end

  def self.center_return_update
    return if !center_return_active?
    return if !navigation_active?
    return if !navigation_can_update?

    if center_inside_target_center?
      return if !center_perform_heal
      # Leave through the game's normal common-Center exit before walking back.
      safe_value(nil) { exit_pokemon_center() }
      @center_return_path = []
      @center_return_phase = :to_resume
      return
    end

    target = center_current_target
    return if !target

    if center_at_target?(target)
      if @center_return_phase == :to_center
        return if !center_perform_heal
        center_begin_resume
      else
        center_finish_return
      end
      return
    end

    if !@center_return_path || @center_return_path.length == 0
      if !center_replan
        append_action_log("CENTER_RETURN", "no connected walking path to current center-trip target")
        navigation_stop("center_path_unreachable")
        @center_return_active = false
        return
      end
    end

    direction = @center_return_path[0]
    old_map = $game_map.map_id
    old_x = $game_player.x
    old_y = $game_player.y

    moved = navigation_move(direction)
    if moved
      @center_return_path.shift
      return
    end

    @center_return_path = []
    if @center_return_replans >= 4
      append_action_log(
        "CENTER_RETURN",
        "blocked repeatedly near map #{old_map} #{old_x},#{old_y}; stopping safely"
      )
      navigation_stop("center_path_blocked")
      @center_return_active = false
    end
  rescue Exception => e
    append_action_log("ERROR", "center return update: #{e.class}: #{e.message}")
    navigation_stop("center_return_error")
    @center_return_active = false
  end
end

# Remember every Pokemon Center entrance the save actually uses. This grows a
# trustworthy set of known destinations instead of giving the bot omniscient
# knowledge of unvisited Centers.
class Object
  if private_method_defined?(:pbSetPokemonCenter) &&
     !private_method_defined?(:pifbot_original_pbSetPokemonCenter)
    alias_method :pifbot_original_pbSetPokemonCenter, :pbSetPokemonCenter
  end

  def pbSetPokemonCenter
    PIFBot.record_known_center
    if respond_to?(:pifbot_original_pbSetPokemonCenter, true)
      return pifbot_original_pbSetPokemonCenter
    end

    # Defensive fallback mirrors the game's save fields.
    $PokemonGlobal.pokecenterMapId = $game_map.map_id
    $PokemonGlobal.pokecenterX = $game_player.x
    $PokemonGlobal.pokecenterY = $game_player.y
    $PokemonGlobal.pokecenterDirection = $game_player.direction
  end
  private :pbSetPokemonCenter
end

Events.onMapUpdate += proc { |_sender, _event_data|
  PIFBot.center_return_update
}

Events.onMapChange += proc { |_sender, _event_data|
  if PIFBot.center_return_active?
    PIFBot.instance_variable_set(:@center_return_path, [])
  end
}
