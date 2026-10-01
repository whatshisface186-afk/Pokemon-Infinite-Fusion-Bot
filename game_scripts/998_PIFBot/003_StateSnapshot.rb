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

  def self.describe_pokemon(f, pkmn, label)
    return if !pkmn
    f.write("\n[#{label}]\n")
    f.write("Name: #{safe_value { pkmn.name }}\n")
    f.write("Species name: #{safe_value { pkmn.speciesName }}\n")
    f.write("Species ID: #{safe_value { pkmn.species.inspect }}\n")
    f.write("Level: #{safe_value { pkmn.level }}\n")
    f.write("HP: #{safe_value { pkmn.hp }}/#{safe_value { pkmn.totalhp }}\n")
    f.write("Status: #{safe_value { pkmn.status.inspect }}\n")
    f.write("Types: #{safe_value { pkmn.types.join(", ") }}\n")
    f.write("Ability: #{safe_value { pkmn.ability.name }}\n")
    f.write("Nature: #{safe_value { pkmn.nature.name }}\n")
    held_item = safe_value(nil) { pkmn.item_id }
    item_name = held_item ? safe_value { GameData::Item.get(held_item).name } : "None"
    f.write("Held item: #{item_name}\n")
    f.write("Stats: HP #{safe_value { pkmn.totalhp }}, Atk #{safe_value { pkmn.attack }}, Def #{safe_value { pkmn.defense }}, SpA #{safe_value { pkmn.spatk }}, SpD #{safe_value { pkmn.spdef }}, Spe #{safe_value { pkmn.speed }}\n")

    moves = safe_value([]) { pkmn.moves }
    if moves.length == 0
      f.write("Moves: none\n")
    else
      moves.each_with_index do |move, move_index|
        next if !move
        move_data = safe_value(nil) { GameData::Move.get(move.id) }
        if move_data
          f.write("Move #{move_index + 1}: #{safe_value { move.name }} | Type #{safe_value { move_data.type }} | Category #{safe_value { move_data.category }} | Power #{safe_value { move_data.base_damage }} | Accuracy #{safe_value { move_data.accuracy }} | PP #{safe_value { move.pp }}/#{safe_value { move.total_pp }}\n")
        else
          f.write("Move #{move_index + 1}: #{safe_value { move.name }} | PP #{safe_value { move.pp }}/#{safe_value { move.total_pp }}\n")
        end
      end
    end
  end

  def self.write_state_snapshot(reason = "unknown")
    return if !$Trainer

    File.open(STATE_SNAPSHOT_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - State Snapshot\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Reason: #{reason}\n")
      f.write("Time: #{Time.now}\n\n")

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
      party.each_with_index { |pkmn, index| describe_pokemon(f, pkmn, "Party #{index + 1}") }

      f.write("\n[PC Storage]\n")
      storage_count = 0
      if $PokemonStorage
        for box_index in 0...$PokemonStorage.maxBoxes
          for slot_index in 0...$PokemonStorage.maxPokemon(box_index)
            stored = $PokemonStorage[box_index, slot_index]
            next if !stored
            storage_count += 1
            describe_pokemon(f, stored, "PC #{storage_count} - Box #{box_index + 1} Slot #{slot_index + 1}")
          end
        end
      end
      f.write("\nPC Pokemon count: #{storage_count}\n")
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
