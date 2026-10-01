# Tactician selective capture advisor v0.1
# Read-only. Evaluates whether a visible wild Pokemon is worth spending a ball on.
# Does NOT throw Poké Balls yet.
#
# Personality rule: VERY SELECTIVE
# Catch only when the wild Pokemon materially improves the owned roster through
# direct strength, complementary typing, or strong fusion potential.
#
# Player-knowledge rule:
# - Uses visible species/fusion, level, HP/status/types.
# - Uses only enemy moves already observed in battle.
# - Does NOT inspect hidden ability, item, nature, IVs/EVs or unrevealed moves.

module PIFBot
  CAPTURE_REPORT_PATH = "Data/pif_bot_capture.txt"

  def self.capture_known_move_ids(pkmn)
    key = battle_key_for(pkmn)
    knowledge = BATTLE_KNOWLEDGE[key]
    return [] if !knowledge || !knowledge[:moves]
    ids = []
    knowledge[:moves].each do |move_name|
      begin
        GameData::Move.each do |move_data|
          if move_data.name == move_name
            ids.push(move_data.id)
            break
          end
        end
      rescue Exception
      end
    end
    return ids
  end

  def self.species_strategy_score(species_data, level = 1, known_move_ids = [])
    return 0.0 if !species_data

    stats = safe_value({}) { species_data.base_stats }
    hp  = safe_value(1) { stats[:HP] }
    atk = safe_value(1) { stats[:ATTACK] }
    dfn = safe_value(1) { stats[:DEFENSE] }
    spa = safe_value(1) { stats[:SPECIAL_ATTACK] }
    spd = safe_value(1) { stats[:SPECIAL_DEFENSE] }
    spe = safe_value(1) { stats[:SPEED] }

    bst = hp + atk + dfn + spa + spd + spe
    bst_score = [[bst / 720.0 * 35.0, 0.0].max, 35.0].min

    offense_score = [[[atk, spa].max / 180.0 * 15.0, 0.0].max, 15.0].min
    bulk_average = (hp + dfn + spd) / 3.0
    bulk_score = [[bulk_average / 180.0 * 15.0, 0.0].max, 15.0].min
    speed_score = [[spe / 180.0 * 10.0, 0.0].max, 10.0].min

    types = safe_value([]) { species_data.types }
    typing_score = types.uniq.length >= 2 ? 5.0 : 2.5

    # Level matters a little for immediate usability, but not enough to reject
    # a strategically excellent low-level catch.
    level_score = [[level.to_f / 20.0 * 5.0, 0.0].max, 5.0].min

    move_score = 0.0
    known_move_ids.each do |move_id|
      data = safe_value(nil) { GameData::Move.get(move_id) }
      next if !data || data.base_damage <= 0
      accuracy = (data.accuracy && data.accuracy > 0) ? data.accuracy / 100.0 : 1.0
      quality = data.base_damage * accuracy
      quality *= 1.2 if types.include?(data.type)
      candidate = [[quality / 150.0 * 5.0, 0.0].max, 5.0].min
      move_score = candidate if candidate > move_score
    end

    return bst_score + offense_score + bulk_score + speed_score +
           typing_score + level_score + move_score
  end

  def self.owned_strategy_score(pkmn)
    species_data = safe_value(nil) { GameData::Species.get(pkmn.species) }
    move_ids = safe_value([]) { pkmn.moves }.map { |m| safe_value(nil) { m.id } }.compact
    return species_strategy_score(species_data, safe_value(1) { pkmn.level }, move_ids)
  end

  def self.owned_type_set
    ret = []
    tactician_owned_pokemon.each do |entry|
      pkmn = entry[0]
      safe_value([]) { pkmn.types }.each do |type|
        ret.push(type) if !ret.include?(type)
      end
    end
    return ret
  end

  def self.ball_inventory
    ret = []
    return ret if !$PokemonBag

    GameData::Item.each do |item|
      next if !safe_value(false) { item.is_poke_ball? }
      quantity = safe_value(0) { $PokemonBag.pbQuantity(item.id) }
      next if quantity <= 0
      ret.push([item.id, item.name, quantity])
    end
    return ret
  rescue Exception
    return []
  end

  def self.best_fusion_opportunity(candidate_pkmn)
    return nil if !candidate_pkmn
    return nil if safe_value(false) { candidate_pkmn.isFusion? }

    candidate_species = safe_value(nil) { candidate_pkmn.species }
    return nil if !candidate_species

    best = nil
    tactician_owned_pokemon.each do |entry|
      partner = entry[0]
      next if !partner
      next if safe_value(false) { partner.isFusion? }

      [
        [partner.species, candidate_species, "owned body + candidate head"],
        [candidate_species, partner.species, "candidate body + owned head"]
      ].each do |fusion_def|
        begin
          fused_data = getFusionSpecies(fusion_def[0], fusion_def[1])
          score = species_strategy_score(fused_data, [partner.level, candidate_pkmn.level].max, [])
          if !best || score > best[:score]
            best = {
              :score => score,
              :species => fused_data,
              :partner => partner,
              :orientation => fusion_def[2]
            }
          end
        rescue Exception
        end
      end
    end
    return best
  end

  def self.capture_evaluation(candidate_pkmn)
    owned = tactician_owned_pokemon
    known_move_ids = capture_known_move_ids(candidate_pkmn)
    candidate_data = safe_value(nil) { GameData::Species.get(candidate_pkmn.species) }
    candidate_score = species_strategy_score(
      candidate_data,
      safe_value(1) { candidate_pkmn.level },
      known_move_ids
    )

    owned_scores = owned.map { |entry| [entry[0], owned_strategy_score(entry[0])] }
    best_owned_entry = owned_scores.max_by { |entry| entry[1] }
    best_owned_score = best_owned_entry ? best_owned_entry[1] : 0.0
    direct_delta = candidate_score - best_owned_score

    owned_types = owned_type_set
    candidate_types = safe_value([]) { candidate_pkmn.types }.uniq
    new_types = candidate_types.select { |type| !owned_types.include?(type) }

    duplicate = owned.any? do |entry|
      safe_value(false) { entry[0].species == candidate_pkmn.species }
    end

    fusion = best_fusion_opportunity(candidate_pkmn)
    fusion_delta = fusion ? fusion[:score] - best_owned_score : -999.0

    reasons = []
    worth_catching = false

    # "Very selective" thresholds. A catch must clear at least one meaningful
    # improvement test rather than merely being different.
    if direct_delta >= 8.0
      worth_catching = true
      reasons.push("direct strategic score is at least 8 points above current best")
    end

    if new_types.length >= 1 && direct_delta >= 3.0
      worth_catching = true
      reasons.push("adds new team typing while also improving direct score")
    end

    if new_types.length >= 2 && candidate_score >= best_owned_score
      worth_catching = true
      reasons.push("adds two new team types without sacrificing strategic score")
    end

    if fusion && fusion_delta >= 10.0
      worth_catching = true
      reasons.push("best available fusion projects at least 10 points above current best")
    end

    # Duplicates need an even stronger reason in selective mode.
    if duplicate && direct_delta < 12.0 && fusion_delta < 14.0
      worth_catching = false
      reasons = ["duplicate species/fusion without a large enough improvement"]
    end

    reasons.push("no substantial roster improvement detected") if reasons.length == 0

    return {
      :worth_catching => worth_catching,
      :candidate_score => candidate_score,
      :best_owned_score => best_owned_score,
      :best_owned => best_owned_entry ? best_owned_entry[0] : nil,
      :direct_delta => direct_delta,
      :new_types => new_types,
      :duplicate => duplicate,
      :fusion => fusion,
      :fusion_delta => fusion_delta,
      :reasons => reasons,
      :known_move_ids => known_move_ids
    }
  end

  def self.write_capture_report(battle)
    return if !battle
    return if !safe_value(false) { battle.wildBattle? }

    candidate_battler = safe_value([]) { battle.battlers }.find do |b|
      b && b.pokemon && !b.fainted? && safe_value(false) { battle.opposes?(b.index) }
    end
    return if !candidate_battler

    candidate = candidate_battler.pokemon
    evaluation = capture_evaluation(candidate)
    balls = ball_inventory
    total_balls = balls.inject(0) { |sum, entry| sum + entry[2] }

    File.open(CAPTURE_REPORT_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Selective Capture Advisor\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Mode: READ-ONLY\n")
      f.write("Personality: TACTICIAN / VERY SELECTIVE\n")
      f.write("Knowledge model: PLAYER-KNOWLEDGE\n")
      f.write("\n")

      f.write("Wild candidate: #{safe_value { candidate.name }}\n")
      f.write("Species: #{safe_value { candidate.speciesName }} (#{safe_value { candidate.species.inspect }})\n")
      f.write("Level: #{safe_value { candidate.level }}\n")
      f.write("HP: #{safe_value { candidate_battler.hp }}/#{safe_value { candidate_battler.totalhp }}\n")
      f.write("Status: #{safe_value { candidate_battler.status.inspect }}\n")
      f.write("Types: #{safe_value { candidate.types.join(", ") }}\n")
      f.write("Observed moves used in evaluation: ")
      known_names = evaluation[:known_move_ids].map { |id| safe_value(id.to_s) { GameData::Move.get(id).name } }
      f.write("#{known_names.length > 0 ? known_names.join(", ") : "none"}\n")
      f.write("Hidden ability/item/nature/IVs/EVs/unrevealed moves consulted: NO\n")
      f.write("\n")

      f.write("Candidate strategic score: #{format("%.2f", evaluation[:candidate_score])}\n")
      if evaluation[:best_owned]
        f.write("Current best owned: #{safe_value { evaluation[:best_owned].name }} | #{format("%.2f", evaluation[:best_owned_score])}\n")
      else
        f.write("Current best owned: none\n")
      end
      f.write("Direct improvement delta: #{format("%+.2f", evaluation[:direct_delta])}\n")
      f.write("New team types: #{evaluation[:new_types].length > 0 ? evaluation[:new_types].join(", ") : "none"}\n")
      f.write("Duplicate species/fusion: #{evaluation[:duplicate] ? "YES" : "NO"}\n")

      if evaluation[:fusion]
        fusion = evaluation[:fusion]
        f.write("Best projected fusion: #{safe_value { fusion[:species].name }}\n")
        f.write("Fusion partner: #{safe_value { fusion[:partner].name }}\n")
        f.write("Fusion orientation: #{fusion[:orientation]}\n")
        f.write("Projected fusion score: #{format("%.2f", fusion[:score])}\n")
        f.write("Fusion improvement delta: #{format("%+.2f", evaluation[:fusion_delta])}\n")
      else
        f.write("Best projected fusion: unavailable/not evaluated\n")
      end

      f.write("\n")
      f.write("Worth catching: #{evaluation[:worth_catching] ? "YES" : "NO"}\n")
      f.write("Reason: #{evaluation[:reasons].join("; ")}\n")
      f.write("\n")

      f.write("Poké Balls available: #{total_balls}\n")
      balls.each do |entry|
        f.write("  #{entry[1]}: #{entry[2]}\n")
      end
      if evaluation[:worth_catching] && total_balls == 0
        f.write("Capture action state: WORTH CATCHING, BUT NO BALLS AVAILABLE\n")
      elsif evaluation[:worth_catching]
        f.write("Capture action state: ELIGIBLE FOR FUTURE AUTO-CAPTURE\n")
      else
        f.write("Capture action state: DO NOT SPEND A BALL\n")
      end
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_capture_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end
end

class PokeBattle_Battle
  unless method_defined?(:pifbot_capture_original_pbCommandPhase)
    alias_method :pifbot_capture_original_pbCommandPhase, :pbCommandPhase

    def pbCommandPhase
      PIFBot.write_capture_report(self)
      pifbot_capture_original_pbCommandPhase
    end
  end
end
