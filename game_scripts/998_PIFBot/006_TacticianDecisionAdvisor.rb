# Tactician decision advisor v0.1
# Read-only. Scores currently usable moves against the visible active opponent
# and explains the recommendation. It does NOT register a command.
#
# Player-knowledge rule:
# - Own exact stats/moves are allowed.
# - Opponent visible species/fusion, level, HP/status and types are allowed.
# - Opponent hidden IVs/EVs/nature/ability/item/unrevealed moves are NOT used.
# - Opponent defensive stats are estimated from species base stats + visible level.

module PIFBot
  TACTICIAN_DECISION_PATH = "Data/pif_bot_decision.txt"

  def self.estimated_visible_defense(pkmn, stat_key)
    base_stats = safe_value({}) { pkmn.baseStats }
    base = safe_value(50) { base_stats[stat_key] }
    level = safe_value(1) { pkmn.level }
    # Neutral estimate with midpoint IV (15), zero EVs and no hidden nature use.
    return ((((2 * base) + 15) * level / 100.0) + 5).floor
  end

  def self.visible_type_multiplier(move_type, target_pkmn)
    types = safe_value([]) { target_pkmn.types }
    type1 = types[0]
    type2 = types[1]
    raw = Effectiveness.calculate(move_type, type1, type2)
    return raw.to_f / Effectiveness::NORMAL_EFFECTIVE
  rescue Exception
    return 1.0
  end

  def self.tactician_move_advice(battle, user, target, move_index)
    move = user.moves[move_index]
    return nil if !move
    return nil if !battle.pbCanChooseMove?(user.index, move_index, false)

    data = safe_value(nil) { GameData::Move.get(move.id) }
    return nil if !data

    if data.category != 2 && data.base_damage > 0 &&
       respond_to?(:observed_move_blocked?) &&
       observed_move_blocked?(target.pokemon, move.id)
      return {
        :index => move_index,
        :name => move.name,
        :kind => "OBSERVED_BLOCKED",
        :score => -1000.0,
        :expected_damage => 0.0,
        :ko_pressure => 0.0,
        :type_mult => visible_type_multiplier(data.type, target.pokemon),
        :stab => safe_value([]) { user.pokemon.types }.include?(data.type),
        :accuracy => (data.accuracy && data.accuracy > 0) ? data.accuracy / 100.0 : 1.0,
        :estimated_defense => nil,
        :reason => "observed battle effect blocked this move against this opponent"
      }
    end

    if data.category == 2 || data.base_damage <= 0
      # Deliberately simple for the first advisor. Move-specific tactical
      # status logic will be added after the action pipeline is validated.
      target_hp_fraction = target.totalhp > 0 ? target.hp.to_f / target.totalhp : 1.0
      score = target_hp_fraction > 0.45 ? 18.0 : 8.0
      return {
        :index => move_index,
        :name => move.name,
        :kind => "STATUS",
        :score => score,
        :reason => "utility/status heuristic; no hidden opponent information used"
      }
    end

    physical = (data.category == 0)
    attack_stat = physical ? safe_value(1) { user.attack } : safe_value(1) { user.spatk }
    defense_key = physical ? :DEFENSE : :SPECIAL_DEFENSE
    estimated_defense = [estimated_visible_defense(target.pokemon, defense_key), 1].max

    level = safe_value(1) { user.level }
    power = data.base_damage
    accuracy = (data.accuracy && data.accuracy > 0) ? data.accuracy / 100.0 : 1.0
    stab = safe_value([]) { user.pokemon.types }.include?(data.type) ? 1.5 : 1.0
    type_mult = visible_type_multiplier(data.type, target.pokemon)

    # Gen-style deterministic center estimate, intentionally omitting hidden
    # target ability/item/nature/IV/EV information and random damage variance.
    base_damage = (((((2.0 * level / 5.0) + 2.0) * power * attack_stat / estimated_defense) / 50.0) + 2.0)
    expected_damage = base_damage * stab * type_mult * accuracy
    ko_pressure = target.hp > 0 ? expected_damage / target.hp.to_f : 1.0

    # Score primarily by expected immediate pressure. This is not the final
    # battle AI; switching, setup value, risk and learned enemy moves come later.
    score = [expected_damage * 4.0, 80.0].min
    score += 20.0 if ko_pressure >= 1.0
    score += 6.0 if type_mult > 1.0
    score -= 18.0 if type_mult == 0.0

    return {
      :index => move_index,
      :name => move.name,
      :kind => physical ? "PHYSICAL" : "SPECIAL",
      :score => score,
      :expected_damage => expected_damage,
      :ko_pressure => ko_pressure,
      :type_mult => type_mult,
      :stab => stab > 1.0,
      :accuracy => accuracy,
      :estimated_defense => estimated_defense,
      :reason => "visible matchup estimate"
    }
  end

  def self.write_tactician_decision(battle)
    return if !battle

    players = safe_value([]) { battle.battlers }.select do |b|
      b && b.pokemon && b.pbOwnedByPlayer? && !b.fainted?
    end
    opponents = safe_value([]) { battle.battlers }.select do |b|
      b && b.pokemon && battle.opposes?(b.index) && !b.fainted?
    end
    return if players.length == 0 || opponents.length == 0

    File.open(TACTICIAN_DECISION_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Tactician Decision Advisor\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Mode: READ-ONLY ADVISOR\n")
      f.write("Knowledge model: PLAYER-KNOWLEDGE\n")
      f.write("\n")

      players.each_with_index do |user, pidx|
        # First version evaluates the nearest/first visible active opponent.
        # Multi-target tactical selection will be added later.
        target = opponents[0]

        f.write("[Decision #{pidx + 1}]\n")
        f.write("User: #{safe_value { user.name }} Lv#{safe_value { user.level }}\n")
        f.write("Target: #{safe_value { target.name }} Lv#{safe_value { target.level }} | HP #{safe_value { target.hp }}/#{safe_value { target.totalhp }} | Types #{safe_value { target.pokemon.types.join(", ") }}\n")

        advice = []
        user.moves.each_with_index do |_move, move_index|
          entry = tactician_move_advice(battle, user, target, move_index)
          advice.push(entry) if entry
        end
        advice.sort_by! { |entry| -entry[:score] }

        if advice.length == 0
          f.write("Recommendation: no usable move found\n")
        else
          best = advice[0]
          f.write("Recommendation: MOVE #{best[:index] + 1} - #{best[:name]}\n")
          f.write("Recommendation score: #{format("%.2f", best[:score])}\n")
          f.write("\nMove ranking:\n")

          advice.each_with_index do |entry, rank|
            f.write("#{rank + 1}. #{entry[:name]} | #{entry[:kind]} | score #{format("%.2f", entry[:score])}")
            if !entry[:expected_damage].nil?
              f.write(" | est damage #{format("%.2f", entry[:expected_damage])}")
              f.write(" | target-HP pressure #{format("%.2f", entry[:ko_pressure])}x")
              f.write(" | effectiveness #{format("%.2f", entry[:type_mult])}x") if entry[:type_mult]
              f.write(" | STAB #{entry[:stab] ? "yes" : "no"}") if entry.has_key?(:stab)
              f.write(" | accuracy #{format("%.0f", entry[:accuracy] * 100)}%") if entry[:accuracy]
              f.write(" | est target defense #{entry[:estimated_defense]}") if entry[:estimated_defense]
            end
            f.write(" | #{entry[:reason]}\n")
          end
        end

        key = battle_key_for(target.pokemon)
        knowledge = BATTLE_KNOWLEDGE[key]
        observed_moves = knowledge ? knowledge[:moves] : []
        f.write("\nObserved enemy moves available to Tactician: #{observed_moves.length > 0 ? observed_moves.join(", ") : "none yet"}\n")
        blocked_names = respond_to?(:observed_blocked_move_names) ? observed_blocked_move_names(target.pokemon) : []
        f.write("Own moves visibly blocked by this opponent: #{blocked_names.length > 0 ? blocked_names.join(", ") : "none observed"}\n")
        f.write("Enemy ability/item/unrevealed moves consulted: NO\n")
        f.write("\n")
      end
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_decision_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end
end

class PokeBattle_Battle
  unless method_defined?(:pifbot_advisor_original_pbCommandPhase)
    alias_method :pifbot_advisor_original_pbCommandPhase, :pbCommandPhase

    def pbCommandPhase
      PIFBot.write_tactician_decision(self)
      pifbot_advisor_original_pbCommandPhase
    end
  end
end
