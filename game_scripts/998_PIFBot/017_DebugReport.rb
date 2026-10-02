# PIFBot one-file debug report v1
#
# Output:
#   Data/pif_bot_debug_latest.txt
#
# Goals:
# - Automatically regenerate after every F10 autonomous run.
# - F6 can regenerate it manually even while many game modal loops are active,
#   because the hook sits around Input.update itself.
# - Put the bot's decision state, navigation/Center state, party/inventory,
#   current-session logs and latest subsystem reports into ONE uploadable file.
#
# This is diagnostic only. It does not alter game decisions.

module PIFBot
  DEBUG_REPORT_PATH = "Data/pif_bot_debug_latest.txt"
  DEBUG_REPORT_ERROR_PATH = "Data/pif_bot_debug_error.txt"
  DEBUG_REPORT_VERSION = 1
  DEBUG_KEY_CODE = 0x75   # F6

  DEBUG_LATEST_REPORTS = [
    ["State snapshot",          "Data/pif_bot_state.txt"],
    ["Battle observer",        "Data/pif_bot_battle.txt"],
    ["Decision advisor",       "Data/pif_bot_decision.txt"],
    ["Capture advisor",        "Data/pif_bot_capture.txt"],
    ["Battle control",         "Data/pif_bot_control.txt"],
    ["Team style",             "Data/pif_bot_team_style.txt"],
    ["Campaign status",        "Data/pif_bot_campaign.txt"],
    ["Campaign team review",   "Data/pif_bot_team_review.txt"],
    ["Navigation status",      "Data/pif_bot_navigation.txt"],
    ["Campaign session summary","Data/pif_bot_test_summary.txt"]
  ]

  def self.debug_safe(default_value = nil)
    begin
      return yield
    rescue Exception
      return default_value
    end
  end

  def self.debug_write_heading(file, title)
    file.write("\n")
    file.write("=" * 78)
    file.write("\n")
    file.write(title)
    file.write("\n")
    file.write("=" * 78)
    file.write("\n")
  end

  def self.debug_read_file(path)
    return nil if !File.exist?(path)
    File.open(path, "rb") { |f| f.read }
  rescue Exception
    return nil
  end

  def self.debug_read_from_offset(path, offset, max_bytes = 160000)
    return nil if !File.exist?(path)
    File.open(path, "rb") do |f|
      size = debug_safe(0) { File.size(path) }
      pos = offset || 0
      pos = 0 if pos < 0 || pos > size
      f.seek(pos, IO::SEEK_SET)
      text = f.read
      if text && text.length > max_bytes
        text = "[...older session text truncated...]\n" + text[-max_bytes, max_bytes]
      end
      return text
    end
  rescue Exception
    return nil
  end

  def self.debug_tail(path, max_lines = 120)
    text = debug_read_file(path)
    return nil if !text
    lines = text.split(/\r?\n/)
    lines = lines[-max_lines, max_lines] if lines.length > max_lines
    return lines.join("\n") + "\n"
  rescue Exception
    return nil
  end

  def self.debug_write_text_section(file, title, text)
    debug_write_heading(file, title)
    if text && text.length > 0
      file.write(text)
      file.write("\n") if text[-1, 1] != "\n"
    else
      file.write("(none/unavailable)\n")
    end
  end

  def self.debug_runtime_section(file, reason)
    debug_write_heading(file, "RUNTIME")
    file.write("Report version: #{DEBUG_REPORT_VERSION}\n")
    file.write("Bot version: #{debug_safe("unknown") { VERSION }}\n")
    file.write("Generated: #{Time.now}\n")
    file.write("Reason: #{reason}\n")
    file.write("Tactician control: #{debug_safe("unknown") { tactician_auto_control? ? "ON" : "MANUAL" }}\n")
    file.write("F10 campaign active: #{debug_safe(false) { navigation_active? }}\n")
    file.write("F10 pending stop: #{debug_safe(false) { instance_variable_get(:@nav_pending_stop) == true }}\n")
    file.write("Center return active: #{debug_safe(false) { center_return_active? }}\n")
    file.write("Center heal requested: #{debug_safe(false) { center_heal_requested? }}\n")
    file.write("Center request reason: #{debug_safe("none") { center_heal_request_reason }}\n")

    if $game_map
      file.write("Map: #{debug_safe("?") { $game_map.name }} (#{debug_safe("?") { $game_map.map_id }})\n")
    else
      file.write("Map: unavailable\n")
    end
    if $game_player
      file.write(
        "Player: x=#{debug_safe("?") { $game_player.x }} " +
        "y=#{debug_safe("?") { $game_player.y }} " +
        "dir=#{debug_safe("?") { $game_player.direction }} " +
        "moving=#{debug_safe("?") { $game_player.moving? }} " +
        "move_route_forcing=#{debug_safe("?") { $game_player.move_route_forcing }}\n"
      )
    end

    file.write("Scene: #{debug_safe("none") { $scene.class.to_s }}\n")
    file.write("Interpreter running: #{debug_safe("?") { pbMapInterpreterRunning? }}\n")
    file.write("Message window showing: #{debug_safe("?") { $game_temp.message_window_showing }}\n")
    file.write("In menu: #{debug_safe("?") { $game_temp.in_menu }}\n")
  end

  def self.debug_navigation_section(file)
    debug_write_heading(file, "AUTONOMOUS NAVIGATION STATE")
    file.write("Campaign phase: #{debug_safe("none") { instance_variable_get(:@campaign_phase) }}\n")
    file.write("Wild battles this session: #{debug_safe(0) { instance_variable_get(:@nav_wild_battles) }}\n")
    file.write("Steps this session: #{debug_safe(0) { instance_variable_get(:@nav_steps) }}\n")
    file.write("Next Gym: #{debug_safe("none") { campaign_next_gym ? campaign_next_gym[:leader] : "none" }}\n")
    file.write("Target level: #{debug_safe("?") { campaign_target_level }}\n")
    file.write("Gym party size: #{debug_safe("?") { campaign_gym_party_size }}\n")
    file.write("Gym losses: #{debug_safe(0) { instance_variable_get(:@campaign_gym_losses) }}/#{debug_safe("?") { CAMPAIGN_REBUILD_LOSS_LIMIT }}\n")
    file.write("Roster expansion target: #{debug_safe("none") { instance_variable_get(:@campaign_expand_until_owned_count) || "none" }}\n")
    file.write("Roster expansion reason: #{debug_safe("none") { instance_variable_get(:@campaign_expansion_reason) || "none" }}\n")
    file.write("On encounter terrain: #{debug_safe("?") { campaign_current_tile_has_encounters? }}\n")
    file.write("Training connector steps: #{debug_safe([]) { instance_variable_get(:@campaign_training_path) || [] }.length}\n")
    file.write("Training rotation pending: #{debug_safe(false) { instance_variable_get(:@campaign_training_rotate_pending) == true }}\n")
    file.write("Training anchor map: #{debug_safe("none") { instance_variable_get(:@campaign_training_anchor_map) || "none" }}\n")
    current_training_map = debug_safe(nil) { $game_map ? $game_map.map_id : nil }
    if current_training_map && respond_to?(:campaign_training_map_stats)
      sample = debug_safe({}) { campaign_training_map_stats(current_training_map) }
      file.write("Current training-map encounters: #{sample[:encounters] || 0}\n")
      file.write("Current training-map unique seen: #{debug_safe({}) { sample[:seen] || {} }.length}\n")
      file.write("Current training-map stale streak: #{sample[:stale] || 0}\n")
    end
    gym_team = debug_safe([]) { campaign_gym_team }
    file.write("Planned Gym team: #{gym_team.map { |p| debug_safe("?") { p.name } }.join(", ")}\n")
    file.write("Campaign route goal map: #{debug_safe("none") { instance_variable_get(:@campaign_route_goal_map) }}\n")
    file.write("Campaign route remaining: #{debug_safe([]) { instance_variable_get(:@campaign_route_path) || [] }.length}\n")
    file.write("Start map ID: #{debug_safe("none") { instance_variable_get(:@nav_start_map_id) }}\n")
    file.write("Start map name: #{debug_safe("none") { instance_variable_get(:@nav_start_map_name) }}\n")
    file.write("Last direction: #{debug_safe("none") { instance_variable_get(:@nav_last_direction) }}\n")
    file.write("Stop reason: #{debug_safe("none") { instance_variable_get(:@nav_stop_reason) }}\n")
    file.write("Randomizer errors total: #{debug_safe(0) { instance_variable_get(:@nav_randomizer_errors) }}\n")
    file.write("Randomizer consecutive streak: #{debug_safe(0) { instance_variable_get(:@nav_randomizer_error_streak) }}/#{debug_safe("?") { NAV_RANDOMIZER_ERROR_LIMIT }}\n")

    visits = debug_safe({}) { instance_variable_get(:@nav_visit_counts) || {} }
    file.write("Unique visited tiles: #{visits.length}\n")
  end

  def self.debug_center_section(file)
    debug_write_heading(file, "POKEMON CENTER RETURN STATE")
    file.write("Active: #{debug_safe(false) { center_return_active? }}\n")
    file.write("Phase: #{debug_safe("none") { instance_variable_get(:@center_return_phase) }}\n")
    file.write("Replans: #{debug_safe(0) { instance_variable_get(:@center_return_replans) }}\n")
    file.write("Last Center plan time: #{format("%.1f", debug_safe(0.0) { instance_variable_get(:@center_last_plan_ms) || 0.0 })} ms\n")
    file.write("Off-current maps loaded for plan: #{debug_safe(0) { instance_variable_get(:@center_plan_map_loads) || 0 }}\n")

    target = debug_safe(nil) { instance_variable_get(:@center_return_target) }
    resume = debug_safe(nil) { instance_variable_get(:@center_return_resume) }
    path = debug_safe([]) { instance_variable_get(:@center_return_path) || [] }

    if target
      file.write("Target center: map #{target[:map_id]} @ #{target[:x]},#{target[:y]} dir=#{target[:direction]}\n")
    else
      file.write("Target center: none\n")
    end
    if resume
      file.write("Resume point: map #{resume[:map_id]} @ #{resume[:x]},#{resume[:y]}\n")
    else
      file.write("Resume point: none\n")
    end
    file.write("Remaining planned steps: #{path.length}\n")
    blocked_steps = debug_safe({}) { instance_variable_get(:@center_return_blocked_steps) || {} }
    file.write("Runtime-blocked route steps: #{blocked_steps.length}\n")
    blocked_steps.keys.sort.each do |key|
      file.write("  #{key}\n")
    end
    if path.length > 0
      preview = path[0, 80].map { |d| d.to_s }.join(",")
      preview += ",..." if path.length > 80
      file.write("Direction preview: #{preview}\n")
    end

    transfer_edges = debug_safe([]) { center_transfer_edges(debug_safe(-1) { $game_map.map_id }) }
    file.write("Current-map player-touch transfer edges: #{transfer_edges.length}\n")
    transfer_edges.each do |edge|
      dest_name = debug_safe("?") { $MapFactory.getMapNoAdd(edge[:map_id]).name }
      file.write(
        "  event #{edge[:event_id]} @ #{edge[:event_x]},#{edge[:event_y]} trigger=#{edge[:trigger]} -> " +
        "map #{edge[:map_id]} #{dest_name} @ #{edge[:x]},#{edge[:y]} dir=#{edge[:direction]}\n"
      )
    end

    centers = debug_safe([]) { known_centers }
    file.write("Known centers: #{centers.length}\n")
    centers.each_with_index do |center, index|
      route = debug_safe(nil) { center_map_route(debug_safe(-1) { $game_map.map_id }, center[:map_id]) }
      map_name = debug_safe("?") { $MapFactory.getMapNoAdd(center[:map_id]).name }
      file.write(
        "  #{index + 1}. map #{center[:map_id]} #{map_name} @ #{center[:x]},#{center[:y]} " +
        "dir=#{center[:direction]} | source=#{center[:source] || "unknown"} | " +
        "map_route=#{route ? route.join("->") : "unreachable"}\n"
      )
    end

    if $PokemonGlobal
      file.write(
        "Game healingSpot: #{debug_safe("nil") { $PokemonGlobal.healingSpot.inspect }}\n"
      )
      file.write(
        "Game registered center: map #{debug_safe("?") { $PokemonGlobal.pokecenterMapId }} " +
        "@ #{debug_safe("?") { $PokemonGlobal.pokecenterX }},#{debug_safe("?") { $PokemonGlobal.pokecenterY }} " +
        "dir=#{debug_safe("?") { $PokemonGlobal.pokecenterDirection }}\n"
      )
      file.write(
        "Common-map entrance: map #{debug_safe("none") { $PokemonGlobal.common_map_entrance_id }} " +
        "pos=#{debug_safe("none") { $PokemonGlobal.common_map_entrance_position.inspect }}\n"
      )
    end
  end

  def self.debug_party_section(file)
    debug_write_heading(file, "PARTY")
    party = debug_safe([]) { $Trainer ? $Trainer.party : [] }
    if !party || party.length == 0
      file.write("(party unavailable/empty)\n")
      return
    end

    party.each_with_index do |pkmn, index|
      next if !pkmn
      total = [debug_safe(1) { pkmn.totalhp }.to_f, 1.0].max
      hp = debug_safe(0) { pkmn.hp }.to_f
      ratio = hp / total
      file.write(
        "#{index + 1}. #{debug_safe("unknown") { pkmn.name }} | " +
        "species=#{debug_safe("?") { pkmn.species }} | Lv#{debug_safe("?") { pkmn.level }} | " +
        "HP #{hp.to_i}/#{total.to_i} (#{format("%.1f", ratio * 100.0)}%) | " +
        "status=#{debug_safe("?") { pkmn.status }} | fainted=#{debug_safe("?") { pkmn.fainted? }} | " +
        "types=#{debug_safe([]) { pkmn.types }.join("/")}\n"
      )

      moves = debug_safe([]) { pkmn.moves }
      move_text = moves.map do |move|
        next nil if !move
        "#{debug_safe("?") { move.name }}[#{debug_safe("?") { move.pp }}/#{debug_safe("?") { move.total_pp }}]"
      end.compact.join(", ")
      file.write("    moves: #{move_text}\n")
    end
  end

  def self.debug_inventory_section(file)
    debug_write_heading(file, "RELEVANT BAG INVENTORY")
    if !$PokemonBag
      file.write("(bag unavailable)\n")
      return
    end

    if respond_to?(:ball_inventory)
      balls = debug_safe([]) { ball_inventory }
      file.write("Poke Balls:\n")
      if balls.length == 0
        file.write("  none\n")
      else
        balls.each do |entry|
          file.write("  #{entry[0]} | #{entry[1]} | qty=#{entry[2]}\n")
        end
      end
    end

    file.write("Healing items:\n")
    healing_ids = if const_defined?(:EMERGENCY_HEALS)
                    EMERGENCY_HEALS.map { |entry| entry[0] }
                  else
                    [:POTION, :SUPERPOTION, :FRESHWATER, :SODAPOP, :LEMONADE,
                     :MOOMOOMILK, :HYPERPOTION, :MAXPOTION, :FULLRESTORE]
                  end
    any = false
    healing_ids.uniq.each do |item_id|
      qty = debug_safe(0) { $PokemonBag.pbQuantity(item_id) }
      next if qty <= 0
      any = true
      file.write("  #{item_id} | #{debug_safe(item_id.to_s) { GameData::Item.get(item_id).name }} | qty=#{qty}\n")
    end
    file.write("  none\n") if !any
  end

  def self.debug_nearby_events_section(file)
    debug_write_heading(file, "NEARBY MAP EVENTS")
    if !$game_map || !$game_player
      file.write("(map/player unavailable)\n")
      return
    end

    events = debug_safe({}) { $game_map.events }
    px = debug_safe(0) { $game_player.x }
    py = debug_safe(0) { $game_player.y }
    nearby = []

    events.each_value do |event|
      next if !event
      ex = debug_safe(0) { event.x }
      ey = debug_safe(0) { event.y }
      distance = (ex - px).abs + (ey - py).abs
      next if distance > 12
      nearby.push([distance, event])
    end
    nearby.sort_by! { |entry| entry[0] }

    if nearby.length == 0
      file.write("(none within 12 tiles)\n")
      return
    end

    nearby.each do |entry|
      distance = entry[0]
      event = entry[1]
      file.write(
        "id=#{debug_safe("?") { event.id }} | " +
        "name=#{debug_safe("?") { event.name }} | " +
        "pos=#{debug_safe("?") { event.x }},#{debug_safe("?") { event.y }} | " +
        "dist=#{distance} | trigger=#{debug_safe("?") { event.trigger }} | " +
        "through=#{debug_safe("?") { event.through }} | " +
        "graphic=#{debug_safe("") { event.character_name }}\n"
      )
    end
  end

  def self.debug_subsystem_reports(file)
    DEBUG_LATEST_REPORTS.each do |entry|
      title = entry[0]
      path = entry[1]
      debug_write_text_section(file, "LATEST REPORT: #{title}", debug_read_file(path))
    end
  end

  def self.debug_current_session_logs(file)
    action_offset = debug_safe(nil) { instance_variable_get(:@nav_action_log_offset) }
    capture_offset = debug_safe(nil) { instance_variable_get(:@nav_capture_history_offset) }
    nav_offset = debug_safe(nil) { instance_variable_get(:@nav_history_offset) }

    if action_offset
      debug_write_text_section(
        file,
        "CURRENT F10 SESSION: ACTION LOG",
        debug_read_from_offset(CONTROL_ACTION_LOG_PATH, action_offset)
      )
    else
      debug_write_text_section(file, "RECENT ACTION LOG", debug_tail(CONTROL_ACTION_LOG_PATH, 160))
    end

    if capture_offset
      debug_write_text_section(
        file,
        "CURRENT F10 SESSION: CAPTURE HISTORY",
        debug_read_from_offset(CAPTURE_HISTORY_PATH, capture_offset)
      )
    else
      debug_write_text_section(file, "RECENT CAPTURE HISTORY", debug_tail(CAPTURE_HISTORY_PATH, 100))
    end

    if nav_offset
      debug_write_text_section(
        file,
        "CURRENT F10 SESSION: NAVIGATION HISTORY",
        debug_read_from_offset(NAV_HISTORY_PATH, nav_offset)
      )
    else
      debug_write_text_section(file, "RECENT NAVIGATION HISTORY", debug_tail(NAV_HISTORY_PATH, 160))
    end
  end

  def self.debug_errors_section(file)
    debug_write_heading(file, "BOT ERROR FILES")
    paths = debug_safe([]) { Dir.glob("Data/pif_bot*_error.txt") }
    if !paths || paths.length == 0
      file.write("(no PIFBot error files present)\n")
      return
    end

    paths.sort.each do |path|
      file.write("\n--- #{path} ---\n")
      text = debug_read_file(path)
      file.write(text && text.length > 0 ? text : "(empty)\n")
      file.write("\n") if text && text.length > 0 && text[-1, 1] != "\n"
    end
  end

  def self.write_debug_report(reason = "manual")
    # Refresh the ordinary state snapshot first so the aggregate contains the
    # newest party/map state when that subsystem is available.
    debug_safe(nil) { write_state_snapshot("debug_report") if respond_to?(:write_state_snapshot) }

    File.open(DEBUG_REPORT_PATH, "wb") do |file|
      file.write("Pokemon Infinite Fusion Bot - Diagnostic Report\n")
      file.write("Upload this ONE file after a run or after pressing F6 while stuck.\n")

      debug_runtime_section(file, reason)
      debug_navigation_section(file)
      debug_center_section(file)
      debug_party_section(file)
      debug_inventory_section(file)
      debug_nearby_events_section(file)
      debug_current_session_logs(file)
      debug_subsystem_reports(file)
      debug_errors_section(file)
    end

    return true
  rescue Exception => e
    begin
      File.open(DEBUG_REPORT_ERROR_PATH, "wb") do |file|
        file.write("#{Time.now}\n")
        file.write("#{e.class}: #{e.message}\n")
        file.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
    return false
  end
end

# F6 should work in ordinary map play, battle UI and many blocking/modal loops.
# Infinite Fusion's own Input.update wrapper is preserved first, including F8
# screenshot handling, then we inspect the F6 edge.
module Input
  class << self
    unless method_defined?(:pifbot_debug_original_update)
      alias_method :pifbot_debug_original_update, :update
    end

    def update
      pifbot_debug_original_update
      begin
        if triggerex?(PIFBot::DEBUG_KEY_CODE)
          PIFBot.write_debug_report("manual_F6")
        end
      rescue Exception
      end
    end
  end
end

# Keep a useful near-current diagnostic even if the next failure happens before
# the autonomous run reaches its normal stop condition.
Events.onStartBattle += proc { |_sender|
  PIFBot.write_debug_report("battle_start")
}

Events.onEndBattle += proc { |_sender, _event_data|
  PIFBot.write_debug_report("battle_end")
}
