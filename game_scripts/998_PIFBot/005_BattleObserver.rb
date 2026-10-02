# Tactician battle observer - player-knowledge model.
# Read-only: does not choose commands or modify battle state.
#
# Opponent information recorded before decisions:
# - currently visible species/fusion
# - level
# - HP/status
# - types
#
# Hidden information is NOT read into Tactician's knowledge:
# - unrevealed moves
# - ability
# - held item
#
# Opponent moves are learned only after the opponent actually uses them.

module PIFBot
  BATTLE_REPORT_PATH = "Data/pif_bot_battle.txt"
  BATTLE_KNOWLEDGE = {}
  @battle_turn = 0

  def self.reset_battle_knowledge
    BATTLE_KNOWLEDGE.clear
    @battle_turn = 0
  end

  def self.battle_key_for(pkmn)
    return "unknown" if !pkmn
    personal_id = safe_value("unknown") { pkmn.personalID }
    species = safe_value("unknown") { pkmn.species.inspect }
    return "#{species}:#{personal_id}"
  end

  def self.record_observed_move(battler, choice)
    return if !battler || !battler.pokemon
    return if !battler.battle
    return if !battler.battle.opposes?(battler.index)

    move = safe_value(nil) { choice[2] }
    return if !move

    key = battle_key_for(battler.pokemon)
    BATTLE_KNOWLEDGE[key] ||= {
      :species_name => safe_value("unknown") { battler.pokemon.speciesName },
      :moves => []
    }

    move_name = safe_value("unknown") { move.name }
    BATTLE_KNOWLEDGE[key][:moves].push(move_name) if !BATTLE_KNOWLEDGE[key][:moves].include?(move_name)
  rescue Exception
  end

  def self.visible_battler_line(f, battler, label)
    return if !battler || !battler.pokemon
    pkmn = battler.pokemon

    f.write("\n[#{label}]\n")
    f.write("Name: #{safe_value { pkmn.name }}\n")
    f.write("Species: #{safe_value { pkmn.speciesName }} (#{safe_value { pkmn.species.inspect }})\n")
    f.write("Level: #{safe_value { pkmn.level }}\n")
    f.write("HP: #{safe_value { battler.hp }}/#{safe_value { battler.totalhp }}\n")
    f.write("Status: #{safe_value { battler.status.inspect }}\n")
    f.write("Types: #{safe_value { pkmn.types.join(", ") }}\n")

    if battler.battle.opposes?(battler.index)
      key = battle_key_for(pkmn)
      knowledge = BATTLE_KNOWLEDGE[key]
      observed_moves = knowledge ? knowledge[:moves] : []
      f.write("Observed moves: #{observed_moves.length > 0 ? observed_moves.join(", ") : "none yet"}\n")
      blocked_names = respond_to?(:observed_blocked_move_names) ? observed_blocked_move_names(pkmn) : []
      f.write("Own moves visibly blocked by opponent: #{blocked_names.length > 0 ? blocked_names.join(", ") : "none observed"}\n")
      f.write("Ability: hidden until revealed\n")
      f.write("Held item: hidden until revealed\n")
    else
      f.write("Ability: #{safe_value { pkmn.ability.name }}\n")
      held_item = safe_value(nil) { pkmn.item_id }
      held_name = held_item ? safe_value { GameData::Item.get(held_item).name } : "None"
      f.write("Held item: #{held_name}\n")
      own_moves = safe_value([]) { pkmn.moves }.map { |m| safe_value("unknown") { m.name } }
      f.write("Moves: #{own_moves.join(", ")}\n")
    end
  end

  def self.write_battle_report(battle)
    return if !battle

    @battle_turn ||= 0
    @battle_turn += 1

    File.open(BATTLE_REPORT_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Tactician Battle Observer\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Observed command phase: #{@battle_turn}\n")
      f.write("Battle type: #{safe_value("unknown") { battle.wildBattle? ? "WILD" : "TRAINER" }}\n")

      if !safe_value(true) { battle.wildBattle? }
        opponents = safe_value([]) { battle.opponent }
        opponent_names = []
        opponents.each do |trainer|
          next if !trainer
          opponent_names.push(safe_value("unknown") { trainer.full_name })
        end
        f.write("Opponent trainer: #{opponent_names.join(", ")}\n") if opponent_names.length > 0
      end

      player_count = 0
      opponent_count = 0
      safe_value([]) { battle.battlers }.each do |battler|
        next if !battler || !battler.pokemon
        if battle.opposes?(battler.index)
          opponent_count += 1
          visible_battler_line(f, battler, "Visible Opponent #{opponent_count}")
        elsif battler.pbOwnedByPlayer?
          player_count += 1
          visible_battler_line(f, battler, "Player Active #{player_count}")
        end
      end

      f.write("\n")
      f.write("PLAYER-KNOWLEDGE RULE: unrevealed enemy moves, abilities, and held items are intentionally hidden.\n")
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_battle_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end
end

Events.onStartBattle += proc { |_sender|
  PIFBot.reset_battle_knowledge
}

class PokeBattle_Battle
  unless method_defined?(:pifbot_original_pbCommandPhase)
    alias_method :pifbot_original_pbCommandPhase, :pbCommandPhase

    def pbCommandPhase
      PIFBot.write_battle_report(self)
      pifbot_original_pbCommandPhase
    end
  end
end

class PokeBattle_Battler
  unless method_defined?(:pifbot_original_pbUseMove)
    alias_method :pifbot_original_pbUseMove, :pbUseMove

    def pbUseMove(choice, specialUsage = false)
      PIFBot.record_observed_move(self, choice)
      pifbot_original_pbUseMove(choice, specialUsage)
    end
  end
end
