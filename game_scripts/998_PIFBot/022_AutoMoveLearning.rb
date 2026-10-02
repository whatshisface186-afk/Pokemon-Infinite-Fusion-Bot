# PIFBot automatic Tactician move learning v0.1
#
# Infinite Fusion's normal level-up flow opens an interactive "forget a move"
# UI when a Pokemon already knows four moves. In F10 Campaign Mode, Tactician
# evaluates the current four-move set against each possible replacement and
# chooses automatically. Manual/F7 play keeps the game's original UI.

module PIFBot
  AUTO_MOVE_MIN_IMPROVEMENT = 2.0

  def self.auto_move_learning?
    return false if !respond_to?(:campaign_active?) || !campaign_active?
    return false if !respond_to?(:tactician_auto_control?) || !tactician_auto_control?
    return true
  rescue Exception
    return false
  end

  def self.auto_move_group_bonus(move_id)
    return 0.0 if !defined?(STYLE_MOVE_GROUPS)
    bonus = 0.0
    key = safe_value(nil) { tactician_team_style_key }

    # General utility value.
    bonus += 14.0 if (STYLE_MOVE_GROUPS[:recovery] || []).include?(move_id)
    bonus += 8.0  if (STYLE_MOVE_GROUPS[:drain] || []).include?(move_id)
    bonus += 10.0 if (STYLE_MOVE_GROUPS[:status] || []).include?(move_id)
    bonus += 9.0  if (STYLE_MOVE_GROUPS[:protect] || []).include?(move_id)
    bonus += 9.0  if (STYLE_MOVE_GROUPS[:hazards] || []).include?(move_id)
    bonus += 7.0  if (STYLE_MOVE_GROUPS[:phazing] || []).include?(move_id)
    bonus += 7.0  if (STYLE_MOVE_GROUPS[:pivot] || []).include?(move_id)
    bonus += 6.0  if (STYLE_MOVE_GROUPS[:priority] || []).include?(move_id)

    # Personality/style-specific emphasis. This intentionally reuses the same
    # move groups as the team-style planner rather than inventing a second
    # unrelated preference system.
    case key
    when :STALL
      bonus += 12.0 if (STYLE_MOVE_GROUPS[:recovery] || []).include?(move_id)
      bonus += 10.0 if (STYLE_MOVE_GROUPS[:status] || []).include?(move_id)
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:passive] || []).include?(move_id)
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:protect] || []).include?(move_id)
      bonus += 6.0 if (STYLE_MOVE_GROUPS[:phazing] || []).include?(move_id)
    when :HYPER_OFFENSE, :SETUP_SWEEP
      bonus += 10.0 if (STYLE_MOVE_GROUPS[:setup] || []).include?(move_id)
      bonus += 7.0 if (STYLE_MOVE_GROUPS[:priority] || []).include?(move_id)
    when :HAZARD_STACK
      bonus += 12.0 if (STYLE_MOVE_GROUPS[:hazards] || []).include?(move_id)
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:phazing] || []).include?(move_id)
    when :PIVOT_MOMENTUM
      bonus += 12.0 if (STYLE_MOVE_GROUPS[:pivot] || []).include?(move_id)
    when :STATUS_CONTROL
      bonus += 12.0 if (STYLE_MOVE_GROUPS[:status] || []).include?(move_id)
    when :RAIN
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:rain] || []).include?(move_id)
    when :SUN
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:sun] || []).include?(move_id)
    when :SAND
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:sand] || []).include?(move_id)
    when :HAIL
      bonus += 8.0 if (STYLE_MOVE_GROUPS[:hail] || []).include?(move_id)
    when :TRICK_ROOM
      bonus += 12.0 if (STYLE_MOVE_GROUPS[:trick_room] || []).include?(move_id)
    end

    return bonus
  rescue Exception
    return 0.0
  end

  def self.auto_move_individual_score(pkmn, move_id)
    data = safe_value(nil) { GameData::Move.get(move_id) }
    return -999.0 if !data

    category = safe_value(2) { data.category }
    power = safe_value(0) { data.base_damage }
    accuracy = safe_value(0) { data.accuracy }
    accuracy_factor = accuracy && accuracy > 0 ? accuracy / 100.0 : 1.0
    types = safe_value([]) { pkmn.types }

    if category != 2 && power > 0
      physical = (category == 0)
      attack_stat = physical ? safe_value(1) { pkmn.attack } : safe_value(1) { pkmn.spatk }
      best_attack = [
        safe_value(1) { pkmn.attack },
        safe_value(1) { pkmn.spatk },
        1
      ].max.to_f
      stat_factor = 0.75 + 0.5 * (attack_stat.to_f / best_attack)
      stab = types.include?(safe_value(nil) { data.type }) ? 1.35 : 1.0

      score = power.to_f * accuracy_factor * stat_factor * stab
      score += auto_move_group_bonus(move_id)
      score += 6.0 if safe_value(0) { data.priority } > 0
      return score
    end

    # Generic status moves retain modest value, while recognized Tactician
    # utility moves gain substantially more through the shared style groups.
    return 18.0 + auto_move_group_bonus(move_id)
  rescue Exception
    return 0.0
  end

  def self.auto_move_set_score(pkmn, move_ids)
    ids = move_ids.compact
    return -9999.0 if ids.length == 0

    score = ids.inject(0.0) { |sum, id| sum + auto_move_individual_score(pkmn, id) }

    damaging = ids.select do |id|
      data = safe_value(nil) { GameData::Move.get(id) }
      data && safe_value(0) { data.base_damage } > 0 && safe_value(2) { data.category } != 2
    end
    score -= 100.0 if damaging.length == 0

    damaging_types = damaging.map { |id| safe_value(nil) { GameData::Move.get(id).type } }.compact.uniq
    score += damaging_types.length * 5.0

    stab_types = damaging_types.select { |type| safe_value([]) { pkmn.types }.include?(type) }
    score += stab_types.length * 7.0

    # Evaluate the complete move set through the same persisted team-style
    # planner used elsewhere by Tactician.
    species_data = safe_value(nil) { GameData::Species.get(pkmn.species) }
    ability_id = safe_value(nil) { pkmn.ability_id }
    if species_data && respond_to?(:tactician_style_fit)
      fit = tactician_style_fit(species_data, ids, ability_id)
      score += safe_value(0.0) { fit[:score] } * 3.0
    end

    return score
  rescue Exception
    return -9999.0
  end

  def self.auto_move_choice(pkmn, new_move)
    current = safe_value([]) { pkmn.moves }.map { |m| safe_value(nil) { m.id } }.compact
    return { :learn => true, :forget => nil, :before => 0.0, :after => 0.0 } if current.length < Pokemon::MAX_MOVES

    before = auto_move_set_score(pkmn, current)
    best = { :learn => false, :forget => nil, :before => before, :after => before }

    current.each_index do |idx|
      # Never erase an HM/field move automatically; those can be required for
      # campaign progression later.
      old_data = safe_value(nil) { GameData::Move.get(current[idx]) }
      next if old_data && safe_value(false) { old_data.hidden_move? }

      candidate = current.dup
      candidate[idx] = new_move
      score = auto_move_set_score(pkmn, candidate)
      if score > best[:after]
        best = {
          :learn => score >= before + AUTO_MOVE_MIN_IMPROVEMENT,
          :forget => idx,
          :before => before,
          :after => score
        }
      end
    end
    return best
  rescue Exception => e
    append_action_log("ERROR", "auto move choice: #{e.class}: #{e.message}")
    return { :learn => false, :forget => nil, :before => 0.0, :after => 0.0 }
  end
end

class PokeBattle_Battle
  unless method_defined?(:pifbot_auto_move_original_pbLearnMove)
    alias_method :pifbot_auto_move_original_pbLearnMove, :pbLearnMove
  end

  def pbLearnMove(idxParty, newMove)
    return pifbot_auto_move_original_pbLearnMove(idxParty, newMove) if !PIFBot.auto_move_learning?

    pkmn = pbParty(0)[idxParty]
    return if !pkmn
    return if pkmn.moves.any? { |m| m && m.id == newMove }

    move_data = GameData::Move.get(newMove)
    move_name = move_data.name
    battler = pbFindBattler(idxParty)

    # Space available: preserve the engine's normal data changes, just skip the
    # blocking presentation.
    if pkmn.moves.length < Pokemon::MAX_MOVES
      move = Pokemon::Move.new(newMove)
      pkmn.moves.push(move)
      pkmn.add_learned_move(move)
      if battler
        battler.moves.push(PokeBattle_Move.from_pokemon_move(self, pkmn.moves.last))
        battler.pbCheckFormOnMovesetChange
      end
      PIFBot.append_action_log("MOVE_LEARN", "#{pkmn.name} learned #{move_name} in empty slot")
      return
    end

    choice = PIFBot.auto_move_choice(pkmn, newMove)
    if !choice[:learn] || choice[:forget].nil?
      PIFBot.append_action_log(
        "MOVE_SKIP",
        "#{pkmn.name} skipped #{move_name} | moveset #{format("%.1f", choice[:before])} -> #{format("%.1f", choice[:after])}"
      )
      return
    end

    forget_index = choice[:forget]
    old_name = pkmn.moves[forget_index].name
    pkmn.moves[forget_index] = Pokemon::Move.new(newMove)
    pkmn.add_learned_move(newMove)
    if battler
      battler.moves[forget_index] = PokeBattle_Move.from_pokemon_move(self, pkmn.moves[forget_index])
      battler.pbCheckFormOnMovesetChange
    end

    PIFBot.append_action_log(
      "MOVE_LEARN",
      "#{pkmn.name} learned #{move_name}; forgot #{old_name} | " +
      "moveset #{format("%.1f", choice[:before])} -> #{format("%.1f", choice[:after])}"
    )
    return
  rescue Exception => e
    begin
      PIFBot.append_action_log("ERROR", "auto move learning: #{e.class}: #{e.message}")
    rescue Exception
    end
    return pifbot_auto_move_original_pbLearnMove(idxParty, newMove)
  end
end
