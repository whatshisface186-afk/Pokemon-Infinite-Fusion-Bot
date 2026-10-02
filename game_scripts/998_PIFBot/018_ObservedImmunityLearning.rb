# PIFBot observed immunity learning v0.1
#
# Player-knowledge behavior:
# - Do NOT inspect a hidden opponent ability to plan ahead.
# - If the battle engine visibly blocks one of the player's damaging moves
#   because of an opponent ability, remember that exact move as ineffective
#   against that currently observed opponent.
# - Future Tactician decisions in the same battle avoid repeating that move.
#
# This fixes loops such as repeatedly using Scratch into an opponent whose
# revealed battle effect prevents Scratch from dealing damage.

module PIFBot
  def self.ensure_battle_knowledge_entry(pkmn)
    return nil if !pkmn
    key = battle_key_for(pkmn)
    BATTLE_KNOWLEDGE[key] ||= {
      :species_name => safe_value("unknown") { pkmn.speciesName },
      :moves => []
    }
    BATTLE_KNOWLEDGE[key][:blocked_player_moves] ||= []
    return BATTLE_KNOWLEDGE[key]
  rescue Exception
    return nil
  end

  def self.record_observed_move_immunity(user, target, move)
    return if !user || !target || !move
    return if !user.pokemon || !target.pokemon
    battle = safe_value(nil) { user.battle }
    return if !battle
    return if !safe_value(false) { battle.pbOwnedByPlayer?(user.index) }
    return if !safe_value(false) { battle.opposes?(target.index) }
    return if safe_value(false) { move.statusMove? }

    knowledge = ensure_battle_knowledge_entry(target.pokemon)
    return if !knowledge

    move_id = safe_value(nil) { move.id }
    return if !move_id
    unless knowledge[:blocked_player_moves].include?(move_id)
      knowledge[:blocked_player_moves].push(move_id)
      append_action_log(
        "LEARNED_IMMUNITY",
        "#{safe_value("unknown") { target.name }} visibly blocked " +
        "#{safe_value(move_id.to_s) { move.name }}; Tactician will not repeat that move against this opponent"
      )
    end
  rescue Exception => e
    append_action_log("ERROR", "record immunity: #{e.class}: #{e.message}")
  end

  def self.observed_move_blocked?(target_pkmn, move_id)
    return false if !target_pkmn || !move_id
    key = battle_key_for(target_pkmn)
    knowledge = BATTLE_KNOWLEDGE[key]
    return false if !knowledge
    blocked = knowledge[:blocked_player_moves] || []
    return blocked.include?(move_id)
  rescue Exception
    return false
  end

  def self.observed_blocked_move_names(target_pkmn)
    return [] if !target_pkmn
    key = battle_key_for(target_pkmn)
    knowledge = BATTLE_KNOWLEDGE[key]
    return [] if !knowledge
    ids = knowledge[:blocked_player_moves] || []
    return ids.map do |move_id|
      safe_value(move_id.to_s) { GameData::Move.get(move_id).name }
    end
  rescue Exception
    return []
  end
end

class PokeBattle_Move
  unless method_defined?(:pifbot_immunity_original_pbImmunityByAbility)
    alias_method :pifbot_immunity_original_pbImmunityByAbility, :pbImmunityByAbility

    def pbImmunityByAbility(user, target)
      blocked = pifbot_immunity_original_pbImmunityByAbility(user, target)
      if blocked
        PIFBot.record_observed_move_immunity(user, target, self)
      end
      return blocked
    end
  end
end
