# PIFBot emergency in-battle healing v0.1
#
# Policy:
# - Never use healing items in the overworld for routine sustain.
# - In battle, only consider a healing item when the active Pokemon is below 40% HP.
# - Use the weakest available standard healing item that can restore the user to
#   at least 70% HP when possible; otherwise use the strongest available standard heal.
# - Respect Infinite Fusion's normal battle-item legality/challenge rules.
#
# This registers the item through the game's native battle action system.

module PIFBot
  EMERGENCY_HEAL_RATIO = 0.40
  EMERGENCY_HEAL_TARGET_RATIO = 0.70

  EMERGENCY_HEALS = [
    [:POTION, 20],
    [:SUPERPOTION, 50],
    [:FRESHWATER, 50],
    [:SODAPOP, 60],
    [:LEMONADE, 80],
    [:MOOMOOMILK, 100],
    [:HYPERPOTION, 200],
    [:MAXPOTION, :FULL],
    [:FULLRESTORE, :FULL]
  ]

  def self.emergency_heal_amount(entry, pkmn)
    amount = entry[1]
    return safe_value(0) { pkmn.totalhp - pkmn.hp } if amount == :FULL
    return amount.to_i
  end

  def self.available_emergency_heals(pkmn)
    return [] if !$PokemonBag || !pkmn

    ret = []
    EMERGENCY_HEALS.each do |entry|
      item_id = entry[0]
      next if !safe_value(false) { GameData::Item.exists?(item_id) }
      quantity = safe_value(0) { $PokemonBag.pbQuantity(item_id) }
      next if quantity <= 0
      amount = emergency_heal_amount(entry, pkmn)
      next if amount <= 0
      ret.push({
        :id => item_id,
        :amount => amount,
        :quantity => quantity,
        :name => safe_value(item_id.to_s) { GameData::Item.get(item_id).name }
      })
    end
    return ret
  rescue Exception
    return []
  end

  def self.choose_emergency_heal(pkmn)
    heals = available_emergency_heals(pkmn)
    return nil if heals.length == 0

    total = [safe_value(1) { pkmn.totalhp }.to_f, 1.0].max
    target_hp = (total * EMERGENCY_HEAL_TARGET_RATIO).ceil
    need = [target_hp - safe_value(0) { pkmn.hp }, 0].max

    adequate = heals.select { |entry| entry[:amount] >= need }
    if adequate.length > 0
      adequate.sort_by! { |entry| [entry[:amount], -entry[:quantity]] }
      return adequate[0]
    end

    heals.sort_by! { |entry| [-entry[:amount], -entry[:quantity]] }
    return heals[0]
  end

  def self.try_tactician_emergency_heal(battle, idx_battler, user)
    return false if !battle || !user || !user.pokemon
    return false if user.fainted?
    return false if !tactician_auto_control?

    total_hp = [safe_value(1) { user.totalhp }.to_f, 1.0].max
    hp = safe_value(0) { user.hp }.to_f
    ratio = hp / total_hp
    return false if ratio >= EMERGENCY_HEAL_RATIO

    heal = choose_emergency_heal(user.pokemon)
    if !heal
      append_action_log(
        "EMERGENCY_HEAL_SKIP",
        "#{safe_value("unknown") { user.name }} at #{format("%.1f", ratio * 100.0)}% HP; no healing item available"
      )
      return false
    end

    party_index = safe_value(-1) { user.pokemonIndex }
    return false if party_index < 0

    can_use = safe_value(false) {
      ItemHandlers.triggerCanUseInBattle(
        heal[:id],
        user.pokemon,
        user,
        nil,
        true,
        battle,
        battle.scene,
        false
      )
    }
    if !can_use
      append_action_log(
        "EMERGENCY_HEAL_SKIP",
        "#{safe_value("unknown") { user.name }} at #{format("%.1f", ratio * 100.0)}% HP; #{heal[:name]} not legal now"
      )
      return false
    end

    if battle.pbRegisterItem(idx_battler, heal[:id], party_index, nil)
      append_action_log(
        "EMERGENCY_HEAL",
        "#{safe_value("unknown") { user.name }} | HP #{safe_value("?") { user.hp }}/#{safe_value("?") { user.totalhp }} " +
        "(#{format("%.1f", ratio * 100.0)}%) | using #{heal[:name]} | target >= #{(EMERGENCY_HEAL_TARGET_RATIO * 100).to_i}%"
      )
      return true
    end

    append_action_log(
      "EMERGENCY_HEAL_SKIP",
      "#{safe_value("unknown") { user.name }} | failed to register #{heal[:name]}"
    )
    return false
  rescue Exception => e
    append_action_log("ERROR", "emergency heal: #{e.class}: #{e.message}")
    return false
  end
end
