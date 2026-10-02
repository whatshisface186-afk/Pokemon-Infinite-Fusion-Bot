# PIFBot autonomous self-test navigation v0.1
#
# F10 starts/stops a conservative current-map testing loop.
# Goal: let the player load a save and hand off repetitive wild-encounter tests.
#
# Safety/initial scope:
# - Normal grinding stays on the starting map; an intentional Pokemon Center
#   healing trip may cross connected maps and then return.
# - Never intentionally steps onto map events/doors/NPCs.
# - Uses the game's native movement/passability and normal step encounter logic.
# - Counts wild battles only.
# - Stops automatically after 10 wild battles.
# - Stops if the party has no usable Pokemon, an unexpected map change occurs,
#   no safe move exists, or a generous step safety limit is reached.
#
# This is NOT story navigation yet. It is deliberately a small, testable
# navigation layer for autonomous battle/capture-data collection.

module PIFBot
  NAV_STATUS_PATH = "Data/pif_bot_navigation.txt"
  NAV_HISTORY_PATH = "Data/pif_bot_navigation_history.txt"
  NAV_SUMMARY_PATH = "Data/pif_bot_test_summary.txt"

  NAV_TARGET_WILD_BATTLES = 10
  NAV_MAX_STEPS = 1500
  NAV_RANDOMIZER_ERROR_LIMIT = 3
  NAV_CENTER_RETURN_BELOW_RATIO = 0.70
  CAMPAIGN_CENTER_PARTY_HP_RATIO = 0.45
  CAMPAIGN_CENTER_LOW_USABLE_FRACTION = 0.50
  CAMPAIGN_PRE_GYM_HP_RATIO = 0.90
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
  @nav_capture_history_offset = 0
  @nav_action_log_offset = 0
  @nav_history_offset = 0
  @nav_randomizer_errors = 0
  @nav_randomizer_error_streak = 0
  @nav_last_f10_trigger_at = 0.0

  def self.navigation_active?
    return @nav_active == true
  end

  def self.navigation_f10_triggered?
    begin
      return false if !Input.triggerex?(NAV_KEY_CODE)

      # Some Infinite Fusion input layers can emit more than one raw F-key edge
      # from a single physical press. Use a simple cooldown instead of relying
      # on Input.time? for raw virtual-key codes, which is not consistently
      # exposed for F10.
      now = Time.now.to_f
      last = @nav_last_f10_trigger_at || 0.0
      return false if now - last < 1.5

      @nav_last_f10_trigger_at = now
      return true
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
    @nav_randomizer_errors = 0
    @nav_randomizer_error_streak = 0
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
    write_debug_report("navigation_start") if respond_to?(:write_debug_report)
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
    write_debug_report("navigation_stop: #{reason}") if respond_to?(:write_debug_report)
    if was_active && respond_to?(:notify_navigation_stop)
      notify_navigation_stop(reason)
    end
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

  def self.navigation_trainer_sight_tile?(x, y)
    events = safe_value({}) { $game_map.events }
    proxy_class = Struct.new(:x, :y)
    proxy = proxy_class.new(x, y)

    events.each_value do |event|
      next if !event
      name = safe_value("") { event.name }
      next if !name
      match = name.match(/(?:trainer|sight)\((\d+)\)/i)
      next if !match

      distance = match[1].to_i
      next if distance <= 0
      return true if safe_value(false) { pbEventCanReachPlayer?(event, proxy, distance) }
    end
    return false
  rescue Exception
    # If trainer sight prediction fails, don't block all navigation.
    return false
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

    # Avoid route trainer/sight events before entering their normal line-of-sight
    # trigger. This keeps self-test mode focused on wild encounters.
    return false if navigation_trainer_sight_tile?(nx, ny)

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

  def self.navigation_hp_ratio(pkmn)
    return 0.0 if !pkmn
    total = [safe_value(1) { pkmn.totalhp }.to_f, 1.0].max
    return safe_value(0) { pkmn.hp }.to_f / total
  rescue Exception
    return 0.0
  end

  def self.navigation_campaign_pre_gym_heal_pokemon(party)
    return nil if !respond_to?(:campaign_active?) || !campaign_active?
    phase = instance_variable_get(:@campaign_phase)
    return nil if phase != :travel_gym && phase != :gym
    return nil if !respond_to?(:campaign_gym_team)

    team = safe_value([]) { campaign_gym_team }.compact
    return nil if team.length == 0

    team.each do |pkmn|
      return pkmn if safe_value(false) { pkmn.fainted? }
      return pkmn if navigation_hp_ratio(pkmn) < CAMPAIGN_PRE_GYM_HP_RATIO
      status = safe_value(:NONE) { pkmn.status }
      return pkmn if status && status != :NONE
    end
    return nil
  rescue Exception
    return nil
  end

  def self.navigation_low_hp_pokemon
    return nil if !$Trainer
    party = safe_value([]) { $Trainer.party }.compact
    return nil if party.length == 0

    usable = party.select { |pkmn| safe_value(false) { pkmn.able? } }
    return nil if usable.length == 0

    # Campaign grinding should not abandon a route just because one Pokemon is
    # hurt. Rotate that Pokemon out and keep training while the party still has
    # plenty of healthy depth. A Center trip is reserved for party-wide
    # depletion, or for topping up the selected team immediately before a Gym.
    if respond_to?(:campaign_active?) && campaign_active?
      pre_gym = navigation_campaign_pre_gym_heal_pokemon(party)
      return pre_gym if pre_gym

      total_hp = party.inject(0.0) { |sum, pkmn| sum + safe_value(0) { pkmn.hp }.to_f }
      total_max = party.inject(0.0) do |sum, pkmn|
        sum + [safe_value(1) { pkmn.totalhp }.to_f, 1.0].max
      end
      party_ratio = total_max > 0.0 ? total_hp / total_max : 0.0
      usable_fraction = usable.length.to_f / [party.length, 1].max.to_f

      if party_ratio <= CAMPAIGN_CENTER_PARTY_HP_RATIO ||
         usable_fraction <= CAMPAIGN_CENTER_LOW_USABLE_FRACTION
        return party.min_by { |pkmn| navigation_hp_ratio(pkmn) }
      end
      return nil
    end

    # Legacy self-test behavior outside campaign mode.
    fainted = party.find { |pkmn| safe_value(false) { pkmn.fainted? } }
    return fainted if fainted

    pkmn = usable.min_by { |entry| navigation_hp_ratio(entry) }
    return nil if !pkmn || navigation_hp_ratio(pkmn) >= NAV_CENTER_RETURN_BELOW_RATIO
    return pkmn
  rescue Exception
    return nil
  end

  def self.navigation_handle_healing
    requested = respond_to?(:center_heal_requested?) && center_heal_requested?
    pkmn = navigation_low_hp_pokemon

    # An emergency item used during campaign grinding no longer forces an
    # immediate Center trip by itself. Keep grinding if the rest of the party
    # is healthy; party-wide depletion/pre-Gym recovery is handled by pkmn.
    if requested && respond_to?(:campaign_active?) && campaign_active? && !pkmn
      append_action_log("CENTER_RETURN_DEFER", "single-Pokemon battle damage; healthy party depth remains")
      clear_center_heal_request if respond_to?(:clear_center_heal_request)
      requested = false
    end

    return :not_needed if !requested && !pkmn

    reason = if requested && respond_to?(:center_heal_request_reason)
               center_heal_request_reason
             elsif pkmn && respond_to?(:campaign_active?) && campaign_active?
               phase = instance_variable_get(:@campaign_phase)
               if phase == :travel_gym || phase == :gym
                 "pre-Gym team recovery"
               else
                 "party-wide depletion"
               end
             elsif pkmn
               "#{safe_value("unknown") { pkmn.name }} below #{(NAV_CENTER_RETURN_BELOW_RATIO * 100).to_i}% HP"
             else
               "party needs healing"
             end

    if respond_to?(:begin_center_return) && begin_center_return(pkmn)
      append_action_log("CENTER_RETURN", "armed immediately | #{reason}")
      return :center_return
    end

    append_action_log(
      "CENTER_RETURN",
      "requested (#{reason}) but no reachable known Pokemon Center is available"
    )
    navigation_stop("low_hp_no_reachable_center")
    return :stopped
  rescue Exception => e
    navigation_log("ERROR center-return check | #{e.class}: #{e.message}")
    navigation_stop("center_return_error")
    return :stopped
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

    # A dedicated center-return state machine temporarily owns movement and may
    # cross connected maps. Normal self-test exploration waits until it returns.
    if respond_to?(:center_return_active?) && center_return_active?
      return
    end

    # Map identity is a hard boundary for normal self-test exploration.
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

    healing_result = navigation_handle_healing
    return if healing_result == :center_return || healing_result == :stopped

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

    @nav_randomizer_error_streak = 0
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

  def self.navigation_handle_randomizer_error(caller_lines = [])
    @nav_randomizer_errors ||= 0
    @nav_randomizer_error_streak ||= 0
    @nav_randomizer_errors += 1
    @nav_randomizer_error_streak += 1

    compact_caller = safe_value("") {
      caller_lines[0, 6].join(" <- ").gsub(/[\r\n]+/, " ")
    }

    navigation_log(
      "RANDOMIZER_ERROR total #{@nav_randomizer_errors} | streak " +
      "#{@nav_randomizer_error_streak}/#{NAV_RANDOMIZER_ERROR_LIMIT}" +
      (compact_caller.length > 0 ? " | #{compact_caller}" : "")
    )
    append_action_log(
      "RANDOMIZER_ERROR",
      "recovered total #{@nav_randomizer_errors} | streak " +
      "#{@nav_randomizer_error_streak}/#{NAV_RANDOMIZER_ERROR_LIMIT}" +
      (compact_caller.length > 0 ? " | #{compact_caller}" : "")
    )

    navigation_write_status("randomizer_error_recovered")

    # Randomizer encounter-generation faults are recoverable in campaign mode:
    # the game can generate a valid battle immediately afterward. Never kill a
    # long spectator campaign for these warnings. If several occur in a row
    # while training, use them as another signal to leave this encounter map.
    if respond_to?(:campaign_active?) && campaign_active?
      if @nav_randomizer_error_streak >= NAV_RANDOMIZER_ERROR_LIMIT &&
         safe_value(nil) { @campaign_phase } == :training
        unless @campaign_training_rotate_pending
          @campaign_training_rotate_pending = true
          append_action_log(
            "CAMPAIGN_TRAIN",
            "rotation queued after #{@nav_randomizer_error_streak} consecutive randomizer encounter errors"
          )
        end
      end
      return true
    end

    # Keep the conservative limit for the legacy standalone self-test.
    if @nav_randomizer_error_streak >= NAV_RANDOMIZER_ERROR_LIMIT
      navigation_stop("consecutive_randomizer_errors")
      return false
    end

    return true
  rescue Exception => e
    navigation_log("ERROR randomizer recovery | #{e.class}: #{e.message}")
    return false
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
      f.write("Randomizer errors recovered: total #{@nav_randomizer_errors || 0} | consecutive #{@nav_randomizer_error_streak || 0}/#{NAV_RANDOMIZER_ERROR_LIMIT}\n")
      f.write("Last stop reason: #{@nav_stop_reason || "none"}\n\n")

      f.write("Safety rules:\n")
      f.write("  - normal grinding stays on starting map\n")
      f.write("  - Pokemon Center trips may cross connected maps, then return\n")
      f.write("  - blocks destination tiles containing map events\n")
      f.write("  - avoids normal trainer/sight-event lines of sight\n")
      f.write("  - uses native passability/collision\n")
      f.write("  - pauses for menus/messages/scripts/battles\n")
      f.write("  - returns to a known reachable Pokemon Center below #{(NAV_CENTER_RETURN_BELOW_RATIO * 100).to_i}% HP\n")
      f.write("  - any emergency in-battle heal forces a Center trip after the battle\n")
      f.write("  - does not spend healing items in the overworld\n")
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
      f.write("Randomizer errors recovered: #{@nav_randomizer_errors || 0}/#{NAV_RANDOMIZER_ERROR_LIMIT}\n")
      f.write("Map: #{@nav_start_map_name || "unknown"} (#{@nav_start_map_id || "?"})\n")

      style_key = safe_value(nil) { tactician_team_style_key }
      style = style_key ? TEAM_STYLES[style_key] : nil
      f.write("Tactician team style: #{style ? style[:name] : style_key || "unknown"}\n\n")

      f.write("[Capture decisions from this autonomous session]\n")
      begin
        if File.exist?(CAPTURE_HISTORY_PATH)
          File.open(CAPTURE_HISTORY_PATH, "r") do |capture_file|
            offset = @nav_capture_history_offset || 0
            offset = 0 if offset < 0 || offset > File.size(CAPTURE_HISTORY_PATH)
            capture_file.seek(offset, IO::SEEK_SET)
            session_text = capture_file.read
            if session_text && session_text.length > 0
              f.write(session_text)
              f.write("\n") if session_text[-1, 1] != "\n"
            else
              f.write("No capture-history entries were written during this session.\n")
            end
          end
        else
          f.write("Capture history file unavailable.\n")
        end
      rescue Exception => e
        f.write("Could not embed capture history: #{e.class}: #{e.message}\n")
      end

      f.write("\n[Bot actions from this autonomous session]\n")
      begin
        if File.exist?(CONTROL_ACTION_LOG_PATH)
          File.open(CONTROL_ACTION_LOG_PATH, "r") do |action_file|
            offset = @nav_action_log_offset || 0
            offset = 0 if offset < 0 || offset > File.size(CONTROL_ACTION_LOG_PATH)
            action_file.seek(offset, IO::SEEK_SET)
            action_text = action_file.read
            if action_text && action_text.length > 0
              f.write(action_text)
              f.write("\n") if action_text[-1, 1] != "\n"
            else
              f.write("No action-log entries were written during this session.\n")
            end
          end
        else
          f.write("Action log unavailable.\n")
        end
      rescue Exception => e
        f.write("Could not embed action log: #{e.class}: #{e.message}\n")
      end

      f.write("\nUseful companion files:\n")
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
  center_trip = PIFBot.respond_to?(:center_return_active?) && PIFBot.center_return_active?
  if !center_trip &&
     (PIFBot.navigation_active? || PIFBot.instance_variable_get(:@nav_pending_stop))
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
