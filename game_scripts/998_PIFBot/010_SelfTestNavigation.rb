# PIFBot autonomous self-test navigation v0.1
#
# F10 starts/stops a conservative current-map testing loop.
# Goal: let the player load a save and hand off repetitive wild-encounter tests.
#
# Safety/initial scope:
# - Never intentionally leaves the current map.
# - Never intentionally steps onto map events/doors/NPCs.
# - Uses the game's native movement/passability and normal step encounter logic.
# - Counts wild battles only.
# - Stops automatically after 10 wild battles.
# - Stops if the party has no usable Pokemon, the map changes, no safe move
#   exists, or a generous step safety limit is reached.
#
# This is NOT story navigation yet. It is deliberately a small, testable
# navigation layer for autonomous battle/capture-data collection.

module PIFBot
  NAV_STATUS_PATH = "Data/pif_bot_navigation.txt"
  NAV_HISTORY_PATH = "Data/pif_bot_navigation_history.txt"
  NAV_SUMMARY_PATH = "Data/pif_bot_test_summary.txt"

  NAV_TARGET_WILD_BATTLES = 10
  NAV_MAX_STEPS = 1500
  NAV_KEY_CODE = 0x79   # F10

  @nav_active = false
  @nav_pending_stop = false
  @nav_wild_battles = 0
  @nav_steps = 0
  @nav_start_map_id = nil
  @nav_start_map_name = nil
  @nav_visit_counts = {}
  @nav_seen_battles = {}
  @nav_last_direction = nil
  @nav_stop_reason = nil

  def self.navigation_active?
    return @nav_active == true
  end

  def self.navigation_f10_triggered?
    begin
      return Input.triggerex?(NAV_KEY_CODE)
    rescue Exception
      return false
    end
  end

  def self.navigation_tile_key(x, y)
    return "#{x},#{y}"
  end

  def self.navigation_log(text)
    begin
      File.open(NAV_HISTORY_PATH, "a") do |f|
        f.write("#{Time.now} | #{text}\n")
      end
    rescue Exception
    end
  end

  def self.navigation_start
    return false if !$Trainer || !$game_map || !$game_player

    if safe_value(0) { $Trainer.able_pokemon_count } <= 0
      navigation_log("START BLOCKED | no usable Pokemon")
      navigation_write_status("start_blocked_no_usable_pokemon")
      return false
    end

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

    start_key = navigation_tile_key($game_player.x, $game_player.y)
    @nav_visit_counts[start_key] = 1

    navigation_log(
      "START | map #{@nav_start_map_id} #{@nav_start_map_name} | " +
      "target #{NAV_TARGET_WILD_BATTLES} wild battles | F10 stop"
    )
    append_action_log(
      "NAV",
      "self-test started on #{@nav_start_map_name}; " +
      "target #{NAV_TARGET_WILD_BATTLES} wild battles"
    )
    navigation_write_status("started")
    return true
  rescue Exception => e
    navigation_log("ERROR start | #{e.class}: #{e.message}")
    return false
  end

  def self.navigation_stop(reason = "manual")
    was_active = navigation_active? || @nav_pending_stop
    @nav_active = false
    @nav_pending_stop = false
    @nav_stop_reason = reason

    if was_active
      navigation_log(
        "STOP | #{reason} | wild #{@nav_wild_battles}/#{NAV_TARGET_WILD_BATTLES} | " +
        "steps #{@nav_steps}"
      )
      append_action_log(
        "NAV",
        "self-test stopped: #{reason} | wild #{@nav_wild_battles}/#{NAV_TARGET_WILD_BATTLES} | " +
        "steps #{@nav_steps}"
      )
    end

    navigation_write_status(reason)
    navigation_write_summary(reason)
    return true
  rescue Exception
    return false
  end

  def self.navigation_toggle
    if navigation_active? || @nav_pending_stop
      navigation_stop("manual_F10")
    else
      navigation_start
    end
  end

  def self.navigation_event_on_tile?(x, y)
    events = safe_value({}) { $game_map.events }
    events.each_value do |event|
      next if !event
      begin
        return true if event.at_coordinate?(x, y)
      rescue Exception
        return true if event.x == x && event.y == y
      end
    end
    return false
  rescue Exception
    # Conservative: if event inspection itself fails, don't move into the tile.
    return true
  end

  def self.navigation_destination(x, y, direction)
    nx = x
    ny = y
    nx -= 1 if direction == 4
    nx += 1 if direction == 6
    ny -= 1 if direction == 8
    ny += 1 if direction == 2
    return [nx, ny]
  end

  def self.navigation_safe_direction?(direction)
    return false if !$game_map || !$game_player

    x = $game_player.x
    y = $game_player.y
    dest = navigation_destination(x, y, direction)
    nx = dest[0]
    ny = dest[1]

    # This deliberately blocks connected-map edge traversal.
    return false if !safe_value(false) { $game_map.valid?(nx, ny) }

    # Don't intentionally step onto NPCs, doors, transfers or other events.
    return false if navigation_event_on_tile?(nx, ny)

    # Use the game's own collision/passability rules.
    return false if !safe_value(false) { $game_player.passable?(x, y, direction) }

    return true
  rescue Exception
    return false
  end

  def self.navigation_choose_direction
    directions = [2, 4, 6, 8]
    safe = directions.select { |dir| navigation_safe_direction?(dir) }
    return nil if safe.length == 0

    # Explore rather than oscillate: prefer the least-visited destination.
    # Tie-break toward continuing straight, then use a deterministic rotation.
    rotated = directions.rotate(@nav_steps % directions.length)
    safe.sort_by! do |dir|
      dest = navigation_destination($game_player.x, $game_player.y, dir)
      visits = @nav_visit_counts[navigation_tile_key(dest[0], dest[1])] || 0
      straight_penalty = (dir == @nav_last_direction) ? 0 : 1
      order = rotated.index(dir) || 99
      [visits, straight_penalty, order]
    end

    return safe[0]
  rescue Exception
    return nil
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

    # move_generic updates tile coordinates immediately when the move begins.
    if $game_player.x != old_x || $game_player.y != old_y
      @nav_steps += 1
      @nav_last_direction = direction
      key = navigation_tile_key($game_player.x, $game_player.y)
      @nav_visit_counts[key] = (@nav_visit_counts[key] || 0) + 1

      navigation_write_status("walking") if (@nav_steps % 25) == 0

      if @nav_steps >= NAV_MAX_STEPS
        navigation_stop("step_safety_limit")
      end
      return true
    end

    return false
  rescue Exception => e
    navigation_log("ERROR move | #{e.class}: #{e.message}")
    return false
  end

  def self.navigation_can_update?
    return false if !navigation_active?
    return false if @nav_pending_stop
    return false if !$Trainer || !$game_map || !$game_player
    return false if !$scene || !$scene.is_a?(Scene_Map)

    # Don't interfere with scripts, messages, menus, forced movement or a
    # movement animation that is already in progress.
    return false if safe_value(false) { pbMapInterpreterRunning? }
    return false if safe_value(false) { $game_temp.message_window_showing }
    return false if safe_value(false) { $game_temp.in_menu }
    return false if safe_value(false) { $PokemonTemp.miniupdate }
    return false if safe_value(false) { $game_player.move_route_forcing }
    return false if safe_value(false) { $game_player.moving? }
    return false if safe_value(false) { $game_player.jumping? }

    return false if safe_value(0) { $Trainer.able_pokemon_count } <= 0
    return true
  rescue Exception
    return false
  end

  def self.navigation_update
    return if !navigation_active?

    # Map identity is a hard boundary for this first test navigator.
    current_map = safe_value(nil) { $game_map.map_id }
    if @nav_start_map_id && current_map != @nav_start_map_id
      navigation_stop("map_changed")
      return
    end

    if safe_value(0) { $Trainer.able_pokemon_count } <= 0
      navigation_stop("no_usable_pokemon")
      return
    end

    return if !navigation_can_update?

    direction = navigation_choose_direction
    if !direction
      navigation_stop("no_safe_moves")
      return
    end

    navigation_move(direction)
  rescue Exception => e
    navigation_log("ERROR update | #{e.class}: #{e.message}")
    navigation_stop("navigation_error")
  end

  def self.navigation_record_wild_battle(battle)
    return if !navigation_active? && !@nav_pending_stop
    return if !battle
    return if !safe_value(false) { battle.wildBattle? }

    @nav_seen_battles ||= {}
    key = battle.object_id
    return if @nav_seen_battles[key]
    @nav_seen_battles[key] = true

    @nav_wild_battles += 1
    navigation_log(
      "WILD #{@nav_wild_battles}/#{NAV_TARGET_WILD_BATTLES} | " +
      "steps #{@nav_steps} | map #{safe_value("?") { $game_map.map_id }}"
    )
    append_action_log(
      "NAV_TEST",
      "wild encounter #{@nav_wild_battles}/#{NAV_TARGET_WILD_BATTLES}"
    )
    navigation_write_status("wild_battle")

    if @nav_wild_battles >= NAV_TARGET_WILD_BATTLES
      # Finish the current battle, then stop on the battle-end event.
      @nav_pending_stop = true
      @nav_active = false
      navigation_log("TARGET REACHED | waiting for current battle to finish")
    end
  rescue Exception => e
    navigation_log("ERROR wild count | #{e.class}: #{e.message}")
  end

  def self.navigation_after_battle
    if @nav_pending_stop
      navigation_stop("target_wild_battles_complete")
    elsif navigation_active?
      navigation_write_status("battle_complete_resume")
      navigation_log("RESUME | battle complete")
    end
  rescue Exception
  end

  def self.navigation_write_status(reason = "update")
    File.open(NAV_STATUS_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Self-Test Navigation\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Reason: #{reason}\n\n")

      state = if @nav_pending_stop
                "FINISHING_CURRENT_BATTLE"
              elsif navigation_active?
                "ACTIVE"
              else
                "STOPPED"
              end
      f.write("State: #{state}\n")
      f.write("Toggle key: F10\n")
      f.write("Mode: CURRENT MAP WILD-ENCOUNTER TEST\n")
      f.write("Wild battles: #{@nav_wild_battles || 0}/#{NAV_TARGET_WILD_BATTLES}\n")
      f.write("Steps: #{@nav_steps || 0}/#{NAV_MAX_STEPS}\n")
      f.write("Start map ID: #{@nav_start_map_id || "none"}\n")
      f.write("Start map name: #{@nav_start_map_name || "none"}\n")
      if $game_map
        f.write("Current map ID: #{safe_value("unknown") { $game_map.map_id }}\n")
        f.write("Current map name: #{safe_value("unknown") { $game_map.name }}\n")
      end
      if $game_player
        f.write("Position: #{safe_value("?") { $game_player.x }}, #{safe_value("?") { $game_player.y }}\n")
      end
      f.write("Unique tiles visited: #{(@nav_visit_counts || {}).length}\n")
      f.write("Last stop reason: #{@nav_stop_reason || "none"}\n\n")

      f.write("Safety rules:\n")
      f.write("  - stays on starting map\n")
      f.write("  - blocks destination tiles containing map events\n")
      f.write("  - uses native passability/collision\n")
      f.write("  - pauses for menus/messages/scripts/battles\n")
      f.write("  - stops after #{NAV_TARGET_WILD_BATTLES} wild battles\n")
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_navigation_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end

  def self.navigation_write_summary(reason)
    File.open(NAV_SUMMARY_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Autonomous Test Summary\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Result: #{reason}\n\n")
      f.write("Wild battles completed: #{@nav_wild_battles || 0}/#{NAV_TARGET_WILD_BATTLES}\n")
      f.write("Overworld steps: #{@nav_steps || 0}\n")
      f.write("Unique tiles visited: #{(@nav_visit_counts || {}).length}\n")
      f.write("Map: #{@nav_start_map_name || "unknown"} (#{@nav_start_map_id || "?"})\n")

      style_key = safe_value(nil) { tactician_team_style_key }
      style = style_key ? TEAM_STYLES[style_key] : nil
      f.write("Tactician team style: #{style ? style[:name] : style_key || "unknown"}\n\n")

      f.write("Useful companion files:\n")
      f.write("  Data/pif_bot_capture_history.txt\n")
      f.write("  Data/pif_bot_actions.txt\n")
      f.write("  Data/pif_bot_navigation_history.txt\n")
      f.write("  Data/pif_bot_team_style.txt\n")
    end
  rescue Exception
  end
end

# Run the navigator from the engine's normal per-frame map-update event.
Events.onMapUpdate += proc { |_sender, _event_data|
  if PIFBot.navigation_f10_triggered?
    PIFBot.navigation_toggle
  end
  PIFBot.navigation_update
}

# If something external/scripted changes maps despite our conservative movement
# rules, stop instead of following it into another area.
Events.onMapChange += proc { |_sender, _event_data|
  if PIFBot.navigation_active? || PIFBot.instance_variable_get(:@nav_pending_stop)
    PIFBot.navigation_stop("map_change_event")
  end
}

# Count each wild battle once. This wraps the already-hooked command phase so
# existing observer/advisor/capture/controller behavior remains chained.
class PokeBattle_Battle
  unless method_defined?(:pifbot_nav_original_pbCommandPhase)
    alias_method :pifbot_nav_original_pbCommandPhase, :pbCommandPhase

    def pbCommandPhase
      PIFBot.navigation_record_wild_battle(self)
      pifbot_nav_original_pbCommandPhase
    end
  end
end

Events.onEndBattle += proc { |_sender, _event_data|
  PIFBot.navigation_after_battle
}
