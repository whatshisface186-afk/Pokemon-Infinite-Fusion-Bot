# Read-only live-state diagnostic for the spectator bot.
# Writes a snapshot whenever the player enters a different map.
# This file does not press buttons, move the player, or change game state.

module PIFBot
  STATE_SNAPSHOT_PATH = "Data/pif_bot_state.txt"

  def self.safe_value(fallback = "unknown")
    begin
      value = yield
      return fallback if value.nil?
      return value
    rescue Exception
      return fallback
    end
  end

  def self.write_state_snapshot(reason = "unknown")
    return if !$Trainer

    File.open(STATE_SNAPSHOT_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - State Snapshot\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Reason: #{reason}\n")
      f.write("Time: #{Time.now}\n")
      f.write("\n")

      if $game_map
        f.write("Map ID: #{$game_map.map_id}\n")
        f.write("Map name: #{safe_value { $game_map.name }}\n")
      else
        f.write("Map: unavailable\n")
      end

      if $game_player
        f.write("Player X: #{safe_value { $game_player.x }}\n")
        f.write("Player Y: #{safe_value { $game_player.y }}\n")
        f.write("Player direction: #{safe_value { $game_player.direction }}\n")
      end

      f.write("\n")
      party = safe_value([]) { $Trainer.party }
      f.write("Party count: #{party.length}\n")

      party.each_with_index do |pkmn, index|
        next if !pkmn
        f.write("\n")
        f.write("[Party #{index + 1}]\n")
        f.write("Name: #{safe_value { pkmn.name }}\n")
        f.write("Species name: #{safe_value { pkmn.speciesName }}\n")
        f.write("Species ID: #{safe_value { pkmn.species.inspect }}\n")
        f.write("Level: #{safe_value { pkmn.level }}\n")
        f.write("HP: #{safe_value { pkmn.hp }}/#{safe_value { pkmn.totalhp }}\n")
        f.write("Status: #{safe_value { pkmn.status.inspect }}\n")

        species_data = safe_value(nil) { GameData::Species.get(pkmn.species) }
        if species_data
          f.write("Types: #{safe_value { species_data.types.join(", ") }}\n")
        end

        moves = safe_value([]) { pkmn.moves }
        move_text = []
        moves.each do |move|
          next if !move
          move_name = safe_value { move.name }
          move_pp   = safe_value { move.pp }
          total_pp  = safe_value { move.total_pp }
          move_text.push("#{move_name} (#{move_pp}/#{total_pp} PP)")
        end
        f.write("Moves: #{move_text.join(", ")}\n")
      end
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_state_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end
end

Events.onMapChange += proc { |_sender, _event_data|
  PIFBot.write_state_snapshot("map_change")
}
