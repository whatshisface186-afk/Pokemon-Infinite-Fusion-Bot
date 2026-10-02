# Tactician battle control v0.1
# Automatic spectator-style battle control using the game's own command
# registration/execution APIs. F7 toggles AI control <-> manual control.
#
# F6 is intentionally left free for the future debug-bundle hotkey.
#
# Current scope:
# - Automatically chooses and registers legal moves using Tactician's
#   player-knowledge decision advisor.
# - Automatically chooses a legal replacement after a faint/forced switch.
# - In wild battles, selectively catches worthwhile Pokemon before ordinary move selection.
# - If not catching, switches to a teammate that can deal damage; runs only if the whole usable team cannot.
# - Uses healing items only as an emergency in battle when HP is below 40%.
# - Does NOT yet make general voluntary tactical switches or final fusion/team-management decisions.
#
# The game engine still executes all selected actions normally.

module PIFBot
  CONTROL_STATUS_PATH = "Data/pif_bot_control.txt"
  CONTROL_ACTION_LOG_PATH = "Data/pif_bot_actions.txt"

  @tactician_auto_control = true

  def self.tactician_auto_control?
    return @tactician_auto_control != false
  end

  def self.reset_tactician_control
    @tactician_auto_control = true
    write_control_status(nil, "new_battle")
  end

  def self.toggle_tactician_control(battle = nil)
    @tactician_auto_control = !tactician_auto_control?
    battle.controlPlayer = tactician_auto_control? if battle
    write_control_status(battle, "F7_toggle")
    append_action_log("CONTROL", tactician_auto_control? ? "TACTICIAN" : "MANUAL")
  end

  def self.f7_triggered?
    begin
      # Windows virtual-key code for F7. Infinite Fusion's extended input
      # accepts raw key codes (same mapping used by its controls code).
      return Input.triggerex?(0x76)
    rescue Exception
      return false
    end
  end

  def self.write_control_status(battle = nil, reason = "update")
    File.open(CONTROL_STATUS_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Battle Control\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Time: #{Time.now}\n")
      f.write("Reason: #{reason}\n")
      f.write("Control mode: #{tactician_auto_control? ? "TACTICIAN" : "MANUAL"}\n")
      f.write("Toggle key: F7\n")
      f.write("F6 reserved for future debug bundle\n")
      if battle
        f.write("Battle controlPlayer: #{safe_value("unknown") { battle.controlPlayer }}\n")
      end
    end
  rescue Exception
  end

  def self.append_action_log(kind, text)
    File.open(CONTROL_ACTION_LOG_PATH, "a") do |f|
      f.write("#{Time.now} | #{kind} | #{text}\n")
    end
  rescue Exception
  end

  def self.tactician_target_candidates(battle, user, move)
    target_data = safe_value(nil) { move.pbTarget(user) }
    return [] if !target_data
    return [[nil, nil]] if target_data.num_targets == 0 || target_data.num_targets > 1

    ret = []
    safe_value([]) { battle.battlers }.each do |target|
      next if !target || !target.pokemon || target.fainted?
      next if !safe_value(false) { battle.pbMoveCanTarget?(user.index, target.index, target_data) }
      ret.push([target, target.index])
    end
    return ret
  end

  # Returns the best known direct-damage option a party Pokemon has against
  # the visible target. Bench Pokemon are evaluated from their known moves,
  # remaining PP and visible type matchup only.
  def self.party_pokemon_damage_option(pkmn, target_pkmn)
    return nil if !pkmn || safe_value(true) { pkmn.fainted? }

    best = nil
    safe_value([]) { pkmn.moves }.each_with_index do |move, move_index|
      next if !move
      next if safe_value(0) { move.pp } <= 0

      data = safe_value(nil) { GameData::Move.get(move.id) }
      next if !data
      next if data.category == 2   # Status move; cannot directly hurt the foe.
      if respond_to?(:observed_move_blocked?) &&
         observed_move_blocked?(target_pkmn, move.id)
        next
      end

      type_mult = visible_type_multiplier(data.type, target_pkmn)
      next if type_mult <= 0.0

      # This is only for deciding whether damage is possible and which bench
      # Pokemon is the most useful emergency switch. It is deliberately simple.
      power = safe_value(1) { data.base_damage }
      power = 1 if power <= 0   # Fixed/special damaging functions still count.
      stab = safe_value([]) { pkmn.types }.include?(data.type) ? 1.5 : 1.0
      accuracy = (data.accuracy && data.accuracy > 0) ? data.accuracy / 100.0 : 1.0
      potential = power * type_mult * stab * accuracy

      entry = {
        :move_index => move_index,
        :move_name => safe_value("unknown") { move.name },
        :type_mult => type_mult,
        :potential => potential
      }
      best = entry if !best || entry[:potential] > best[:potential]
    end
    return best
  rescue Exception
    return nil
  end

  # Finds a legal teammate switch that can deal visible direct damage.
  # Returns nil if no switchable, non-fainted teammate has such a move.
  def self.best_team_damage_switch(battle, idx_battler, target)
    return nil if !battle || !target || !target.pokemon

    party = safe_value([]) { battle.pbParty(idx_battler) }
    best = nil

    party.each_with_index do |pkmn, party_index|
      next if !pkmn || safe_value(true) { pkmn.fainted? }
      next if !safe_value(false) { battle.pbCanSwitch?(idx_battler, party_index) }

      damage = party_pokemon_damage_option(pkmn, target.pokemon)
      next if !damage

      entry = {
        :party_index => party_index,
        :pokemon => pkmn,
        :damage => damage
      }
      if !best || damage[:potential] > best[:damage][:potential]
        best = entry
      end
    end

    return best
  rescue Exception => e
    append_action_log("ERROR", "team damage scan: #{e.class}: #{e.message}")
    return nil
  end

  def self.choose_tactician_command(battle, idx_battler)
    user = safe_value(nil) { battle.battlers[idx_battler] }
    return false if !user || !user.pokemon || user.fainted?

    opponents = safe_value([]) { battle.battlers }.select do |b|
      b && b.pokemon && !b.fainted? && safe_value(false) { battle.opposes?(b.index) }
    end
    visible_opponent = opponents[0]

    # Emergency in-battle healing is implemented in 015_EmergencyBattleHealing.rb.
    # It deliberately runs before capture/move choice so a critically injured
    # active Pokemon can survive long enough to keep executing the plan.
    if respond_to?(:try_tactician_emergency_heal) &&
       try_tactician_emergency_heal(battle, idx_battler, user)
      return true
    end

    # If this wild battle interrupted an active Pokemon Center trip, survival
    # and reaching the Center take priority over grinding/catching. Emergency
    # healing above already had first chance to act when HP is critical.
    if safe_value(false) { battle.wildBattle? } &&
       respond_to?(:center_return_active?) &&
       center_return_active?
      append_action_log(
        "RUN_TO_CENTER",
        "wild battle interrupted active Center trip; attempting escape"
      )
      run_result = safe_value(0) { battle.pbRun(idx_battler) }
      if run_result != 0
        append_action_log(
          "RUN_TO_CENTER",
          "escape resolved | result #{run_result}"
        )
        return true
      end
      append_action_log(
        "RUN_TO_CENTER",
        "escape failed/unavailable; falling back to normal Tactician action for this turn"
      )
    end

    # Selective auto-capture is implemented in 012_AutoCapture.rb. Keep this
    # controller usable even if that optional layer fails to load.
    if visible_opponent &&
       respond_to?(:try_tactician_auto_capture) &&
       try_tactician_auto_capture(battle, idx_battler, visible_opponent)
      return true
    end

    candidates = []

    user.moves.each_with_index do |move, move_index|
      next if !move
      next if !safe_value(false) { battle.pbCanChooseMove?(idx_battler, move_index, false) }

      target_candidates = tactician_target_candidates(battle, user, move)
      next if target_candidates.length == 0

      target_candidates.each do |target_entry|
        target = target_entry[0]
        target_index = target_entry[1]

        # For untargeted/multi-target actions, evaluate against the first visible
        # foe while letting the battle engine handle target resolution.
        advice_target = target || visible_opponent
        next if !advice_target

        if safe_value(false) { battle.opposes?(advice_target.index) }
          advice = tactician_move_advice(battle, user, advice_target, move_index)
          next if !advice
          candidates.push([advice, target_index])
        else
          # Ally/self-targeted move support is intentionally conservative in
          # this first controller. It remains legal, but is scored below a good
          # direct opponent action unless no better legal action exists.
          candidates.push([
            {
              :index => move_index,
              :name => safe_value("unknown") { move.name },
              :kind => "ALLY_OR_SELF",
              :score => 5.0,
              :reason => "legal ally/self action fallback"
            },
            target_index
          ])
        end
      end
    end

    # If the active Pokemon cannot deal visible direct damage, scan the whole
    # usable team before deciding to flee. In wild battles:
    #   1) switch to a teammate that can hurt the foe, if one is legally usable;
    #   2) only run if nobody on the usable team can hurt it.
    damage_candidates = candidates.select do |entry|
      advice = entry[0]
      advice[:expected_damage] && advice[:expected_damage] > 0.0 &&
        (!advice[:type_mult] || advice[:type_mult] > 0.0)
    end

    if safe_value(false) { battle.wildBattle? } &&
       visible_opponent &&
       damage_candidates.length == 0
      opponent_name = safe_value("unknown") { visible_opponent.name }
      team_switch = best_team_damage_switch(battle, idx_battler, visible_opponent)

      if team_switch
        switched = safe_value(false) {
          battle.pbRegisterSwitch(idx_battler, team_switch[:party_index])
        }
        if switched
          append_action_log(
            "SWITCH_NO_DAMAGE",
            "#{safe_value("unknown") { user.name }} cannot hurt #{opponent_name}; " +
            "switching to #{safe_value("unknown") { team_switch[:pokemon].name }} " +
            "which can use #{team_switch[:damage][:move_name]} " +
            "(effectiveness #{format("%.2f", team_switch[:damage][:type_mult])}x)"
          )
          return true
        end
      end

      append_action_log(
        "RUN",
        "no usable team member can deal visible direct damage to #{opponent_name}; attempting escape"
      )

      run_result = safe_value(0) { battle.pbRun(idx_battler) }
      if run_result != 0
        append_action_log(
          "RUN",
          "escape attempt resolved | result #{run_result}"
        )
        return true
      end

      # A hard trapping effect can make pbRun return 0 without consuming the
      # turn. In that case fall through to the best legal non-damaging action
      # rather than hanging the command phase.
      append_action_log(
        "RUN",
        "escape unavailable/trapped; falling back to legal move"
      )
    end

    if candidates.length == 0
      append_action_log("MOVE", "#{safe_value("unknown") { user.name }} -> no scored move; auto fallback")
      battle.pbAutoChooseMove(idx_battler)
      return true
    end

    candidates.sort_by! { |entry| -entry[0][:score] }
    best = candidates[0]
    advice = best[0]
    target_index = best[1]

    if battle.pbRegisterMove(idx_battler, advice[:index], false)
      battle.pbRegisterTarget(idx_battler, target_index) if !target_index.nil?
      target_name = target_index.nil? ? "engine_targeting" : safe_value("unknown") { battle.battlers[target_index].name }
      append_action_log(
        "MOVE",
        "#{safe_value("unknown") { user.name }} -> #{advice[:name]} | score #{format("%.2f", advice[:score])} | target #{target_name}"
      )
      return true
    end

    append_action_log("MOVE", "#{safe_value("unknown") { user.name }} -> registration failed; auto fallback")
    battle.pbAutoChooseMove(idx_battler)
    return true
  rescue Exception => e
    append_action_log("ERROR", "choose command: #{e.class}: #{e.message}")
    begin
      battle.pbAutoChooseMove(idx_battler)
      return true
    rescue Exception
      return false
    end
  end

  def self.choose_tactician_replacement(battle, idx_battler)
    party = safe_value([]) { battle.pbParty(idx_battler) }
    choices = []

    party.each_with_index do |pkmn, party_index|
      next if !pkmn
      next if !safe_value(false) { battle.pbCanSwitch?(idx_battler, party_index) }
      score = safe_value(0.0) { tactician_score(pkmn)[:total] }
      choices.push([party_index, pkmn, score])
    end

    return -1 if choices.length == 0

    choices.sort_by! { |entry| -entry[2] }
    best = choices[0]
    append_action_log(
      "FORCED_SWITCH",
      "party #{best[0] + 1} #{safe_value("unknown") { best[1].name }} | baseline #{format("%.2f", best[2])}"
    )
    return best[0]
  rescue Exception => e
    append_action_log("ERROR", "replacement: #{e.class}: #{e.message}")
    return -1
  end
end

Events.onStartBattle += proc { |_sender|
  PIFBot.reset_tactician_control
}

class PokeBattle_AI
  unless method_defined?(:pifbot_control_original_pbDefaultChooseEnemyCommand)
    alias_method :pifbot_control_original_pbDefaultChooseEnemyCommand, :pbDefaultChooseEnemyCommand

    def pbDefaultChooseEnemyCommand(idxBattler)
      if @battle.pbOwnedByPlayer?(idxBattler) && PIFBot.tactician_auto_control?
        return PIFBot.choose_tactician_command(@battle, idxBattler)
      end
      pifbot_control_original_pbDefaultChooseEnemyCommand(idxBattler)
    end
  end
end

class PokeBattle_Battle
  unless method_defined?(:pifbot_control_original_pbCommandPhase)
    alias_method :pifbot_control_original_pbCommandPhase, :pbCommandPhase

    def pbCommandPhase
      self.controlPlayer = PIFBot.tactician_auto_control?
      PIFBot.write_control_status(self, "command_phase")
      pifbot_control_original_pbCommandPhase
    end
  end

  unless method_defined?(:pifbot_control_original_pbSwitchInBetween)
    alias_method :pifbot_control_original_pbSwitchInBetween, :pbSwitchInBetween

    def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
      if PIFBot.tactician_auto_control? && pbOwnedByPlayer?(idxBattler)
        replacement = PIFBot.choose_tactician_replacement(self, idxBattler)
        return replacement if replacement && replacement >= 0
      end
      pifbot_control_original_pbSwitchInBetween(idxBattler, checkLaxOnly, canCancel)
    end
  end
end

class PokeBattle_Scene
  unless method_defined?(:pifbot_control_original_pbInputUpdate)
    alias_method :pifbot_control_original_pbInputUpdate, :pbInputUpdate

    def pbInputUpdate
      pifbot_control_original_pbInputUpdate
      if PIFBot.f7_triggered?
        PIFBot.toggle_tactician_control(@battle)
      end
    end
  end
end
