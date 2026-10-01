# Tactician v0.1 - read-only candidate scoring.
# This does not press buttons, move the player, change the party, or modify Pokemon.
# It ranks currently owned Pokemon by opponent-independent combat readiness.
#
# IMPORTANT: This is only the baseline portion of Tactician's eventual decision.
# Gym/opponent matchup, team synergy, fusion options, and training cost are separate
# layers and will be added later.

module PIFBot
  TACTICIAN_REPORT_PATH = "Data/pif_bot_tactician.txt"

  def self.tactician_owned_pokemon
    owned = []

    if $Trainer && $Trainer.party
      $Trainer.party.each_with_index do |pkmn, index|
        owned.push([pkmn, "Party #{index + 1}"]) if pkmn
      end
    end

    if $PokemonStorage
      for box_index in 0...$PokemonStorage.maxBoxes
        for slot_index in 0...$PokemonStorage.maxPokemon(box_index)
          pkmn = $PokemonStorage[box_index, slot_index]
          next if !pkmn
          owned.push([pkmn, "PC Box #{box_index + 1} Slot #{slot_index + 1}"])
        end
      end
    end

    return owned
  end

  def self.tactician_move_profile(pkmn)
    pokemon_types = safe_value([]) { pkmn.types }
    damaging_types = []
    damaging_moves = []
    status_count = 0
    stab_count = 0

    safe_value([]) { pkmn.moves }.each do |move|
      next if !move
      data = safe_value(nil) { GameData::Move.get(move.id) }
      next if !data

      if data.base_damage && data.base_damage > 0
        accuracy_factor = (data.accuracy && data.accuracy > 0) ? data.accuracy / 100.0 : 1.0
        quality = data.base_damage * accuracy_factor
        is_stab = pokemon_types.include?(data.type)
        quality *= 1.20 if is_stab

        damaging_types.push(data.type) if !damaging_types.include?(data.type)
        stab_count += 1 if is_stab
        damaging_moves.push({
          :name => move.name,
          :type => data.type,
          :power => data.base_damage,
          :accuracy => data.accuracy,
          :stab => is_stab,
          :quality => quality
        })
      else
        status_count += 1
      end
    end

    best = damaging_moves.max_by { |m| m[:quality] }

    return {
      :damaging_moves => damaging_moves,
      :unique_damage_types => damaging_types.length,
      :status_moves => status_count,
      :stab_moves => stab_count,
      :best_move => best
    }
  end

  def self.tactician_score(pkmn)
    base_stats = safe_value({}) { pkmn.baseStats }

    hp_base  = safe_value(1) { base_stats[:HP] }
    atk_base = safe_value(1) { base_stats[:ATTACK] }
    def_base = safe_value(1) { base_stats[:DEFENSE] }
    spa_base = safe_value(1) { base_stats[:SPECIAL_ATTACK] }
    spd_base = safe_value(1) { base_stats[:SPECIAL_DEFENSE] }
    spe_base = safe_value(1) { base_stats[:SPEED] }

    # 0-20: strongest offensive route, independent of physical/special preference.
    offense = [[atk_base, spa_base].max / 200.0 * 20.0, 20.0].min

    # 0-15: average natural bulk.
    bulk_average = (hp_base + def_base + spd_base) / 3.0
    bulk = [bulk_average / 200.0 * 15.0, 15.0].min

    # 0-10: speed.
    speed = [spe_base / 200.0 * 10.0, 10.0].min

    profile = tactician_move_profile(pkmn)
    best_quality = profile[:best_move] ? profile[:best_move][:quality] : 0.0

    # 0-15: best currently usable damaging move, including accuracy and STAB.
    best_move = [best_quality / 180.0 * 15.0, 15.0].min

    # 0-5: rewards actually having a STAB attack right now.
    stab = profile[:stab_moves] > 0 ? 5.0 : 0.0

    # 0-7.5: rewards multiple damaging types without overvaluing huge movepools.
    extra_types = [profile[:unique_damage_types] - 1, 0].max
    coverage = [[extra_types, 3].min * 2.5, 7.5].min

    # 0-2.5: small reward for tactical status/utility options.
    utility = [profile[:status_moves], 2].min * 1.25

    # 0-15: early-game readiness. Caps at level 15 so this doesn't become
    # "pick the highest-level Pokemon forever."
    level = safe_value(1) { pkmn.level }
    readiness = [[level, 15].min / 15.0 * 15.0, 15.0].min

    # 0-5: current health condition.
    hp = safe_value(0) { pkmn.hp }
    totalhp = safe_value(1) { pkmn.totalhp }
    health = totalhp > 0 ? [[hp.to_f / totalhp, 0.0].max, 1.0].min * 5.0 : 0.0

    total = offense + bulk + speed + best_move + stab + coverage + utility + readiness + health

    return {
      :total => total,
      :offense => offense,
      :bulk => bulk,
      :speed => speed,
      :best_move => best_move,
      :stab => stab,
      :coverage => coverage,
      :utility => utility,
      :readiness => readiness,
      :health => health,
      :profile => profile
    }
  end

  def self.tactician_switch_state(constant_name)
    begin
      return "unknown" if !Object.const_defined?(constant_name)
      switch_id = Object.const_get(constant_name)
      return "unknown" if !$game_switches
      return $game_switches[switch_id] ? "ON" : "OFF"
    rescue Exception
      return "unknown"
    end
  end

  def self.write_tactician_report(reason = "unknown")
    return if !$Trainer

    candidates = tactician_owned_pokemon.map do |entry|
      pkmn = entry[0]
      source = entry[1]
      [pkmn, source, tactician_score(pkmn)]
    end
    candidates.sort_by! { |entry| -entry[2][:total] }

    File.open(TACTICIAN_REPORT_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Tactician Baseline Report\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Reason: #{reason}\n")
      f.write("Time: #{Time.now}\n")
      f.write("\n")
      f.write("Game mode: #{safe_value("unknown") { getCurrentGameModeSymbol }}\n")
      f.write("Random starters: #{tactician_switch_state(:SWITCH_RANDOM_STARTERS)}\n")
      f.write("Random wild Pokemon: #{tactician_switch_state(:SWITCH_RANDOM_WILD)}\n")
      f.write("Random trainers: #{tactician_switch_state(:SWITCH_RANDOM_TRAINERS)}\n")
      f.write("Gyms randomized separately: #{tactician_switch_state(:SWITCH_RANDOMIZE_GYMS_SEPARATELY)}\n")
      f.write("\n")
      f.write("Candidate count: #{candidates.length}\n")
      f.write("NOTE: These are opponent-independent baseline scores only.\n")
      f.write("Final team selection will also consider the upcoming opponent, team synergy, fusion options, and training cost.\n")

      candidates.each_with_index do |entry, rank|
        pkmn = entry[0]
        source = entry[1]
        score = entry[2]
        profile = score[:profile]
        best = profile[:best_move]

        f.write("\n")
        f.write("Rank #{rank + 1}: #{safe_value { pkmn.name }}\n")
        f.write("Source: #{source}\n")
        f.write("Species: #{safe_value { pkmn.speciesName }} (#{safe_value { pkmn.species.inspect }})\n")
        f.write("Level: #{safe_value { pkmn.level }}\n")
        f.write("Types: #{safe_value { pkmn.types.join(", ") }}\n")
        f.write("Ability: #{safe_value { pkmn.ability.name }}\n")
        f.write("Baseline score: #{format("%.2f", score[:total])}/100\n")
        f.write("  Offense: #{format("%.2f", score[:offense])}/20\n")
        f.write("  Bulk: #{format("%.2f", score[:bulk])}/15\n")
        f.write("  Speed: #{format("%.2f", score[:speed])}/10\n")
        f.write("  Best current attack: #{format("%.2f", score[:best_move])}/15\n")
        f.write("  STAB access: #{format("%.2f", score[:stab])}/5\n")
        f.write("  Coverage: #{format("%.2f", score[:coverage])}/7.5\n")
        f.write("  Utility: #{format("%.2f", score[:utility])}/2.5\n")
        f.write("  Early-game readiness: #{format("%.2f", score[:readiness])}/15\n")
        f.write("  Current health: #{format("%.2f", score[:health])}/5\n")
        if best
          f.write("Best damaging move: #{best[:name]} | #{best[:type]} | Power #{best[:power]} | Accuracy #{best[:accuracy]} | STAB #{best[:stab] ? "yes" : "no"}\n")
        else
          f.write("Best damaging move: none\n")
        end
        f.write("Damaging type coverage count: #{profile[:unique_damage_types]}\n")
        f.write("Status/utility move count: #{profile[:status_moves]}\n")
      end
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_tactician_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end
end

Events.onMapChange += proc { |_sender, _event_data|
  PIFBot.write_tactician_report("map_change")
}
