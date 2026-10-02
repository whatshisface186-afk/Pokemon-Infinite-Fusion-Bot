# PIFBot selective automatic capture v0.1
#
# Uses the existing style-aware capture evaluator and Infinite Fusion's native
# item registration/capture path. No bag/menu automation is used.
#
# Current policy:
# - Wild battles only.
# - Very-selective advisor must say YES.
# - Single active player battler only (safe first scope).
# - Up to 3 ball attempts per worthwhile encounter.
# - Chooses among ordinary Poké Balls by estimated catch chance.
# - Preserves Master Ball and unusual/custom balls for later explicit logic.
# - If no acceptable ball/action is available, normal Tactician combat resumes.
#
# Player-knowledge:
# Catch probability uses public species catch rate, visible HP/status, current
# turn/environment and owned ball inventory. It does not inspect hidden IVs,
# nature, unrevealed moves, held item or ability.

module PIFBot
  AUTO_CAPTURE_MAX_ATTEMPTS = 3
  AUTO_CAPTURE_GOOD_CHANCE = 0.65

  AUTO_CAPTURE_STANDARD_BALLS = [
    :POKEBALL, :PREMIERBALL, :GREATBALL, :ULTRABALL,
    :NETBALL, :DIVEBALL, :NESTBALL, :REPEATBALL, :TIMERBALL,
    :DUSKBALL, :QUICKBALL, :FASTBALL, :LEVELBALL, :LUREBALL,
    :HEAVYBALL, :LOVEBALL, :MOONBALL, :DREAMBALL
  ]

  @auto_capture_attempts = {}
  @auto_capture_postprocess = false

  def self.reset_auto_capture_runtime
    @auto_capture_attempts = {}
    @auto_capture_postprocess = false
  end

  def self.auto_capture_postprocess?
    return @auto_capture_postprocess == true
  end

  def self.auto_capture_attempt_count(battle)
    @auto_capture_attempts ||= {}
    return @auto_capture_attempts[battle.object_id] || 0
  end

  def self.increment_auto_capture_attempt(battle)
    @auto_capture_attempts ||= {}
    key = battle.object_id
    @auto_capture_attempts[key] = (@auto_capture_attempts[key] || 0) + 1
    return @auto_capture_attempts[key]
  end

  def self.auto_capture_single_player_battler?(battle)
    count = 0
    safe_value([]) { battle.battlers }.each do |b|
      next if !b || !b.pokemon || b.fainted?
      count += 1 if safe_value(false) { battle.pbOwnedByPlayer?(b.index) }
    end
    return count == 1
  rescue Exception
    return false
  end

  def self.auto_capture_ultra_beast?(species)
    return [
      :NIHILEGO, :BUZZWOLE, :PHEROMOSA, :XURKITREE, :CELESTEELA,
      :KARTANA, :GUZZLORD, :POIPOLE, :NAGANADEL, :STAKATAKA,
      :BLACEPHALON
    ].include?(species)
  end

  def self.estimated_ball_chance(battle, target, ball_id)
    return 0.0 if !battle || !target || !target.pokemon

    if safe_value(false) { BallHandlers.isUnconditional?(ball_id, battle, target) }
      return 1.0
    end

    pkmn = target.pokemon
    catch_rate = safe_value(0.0) { pkmn.species_data.catch_rate.to_f }
    return 0.0 if catch_rate <= 0

    ultra_beast = auto_capture_ultra_beast?(safe_value(nil) { pkmn.species })
    if !ultra_beast || ball_id == :BEASTBALL
      catch_rate = safe_value(catch_rate) {
        BallHandlers.modifyCatchRate(ball_id, catch_rate, battle, target, ultra_beast).to_f
      }
    else
      catch_rate /= 10.0
    end

    total_hp = [safe_value(1) { target.totalhp }.to_f, 1.0].max
    hp = [[safe_value(1) { target.hp }.to_f, 0.0].max, total_hp].min
    x = ((3.0 * total_hp - 2.0 * hp) * catch_rate) / (3.0 * total_hp)

    status = safe_value(:NONE) { target.status }
    if status == :SLEEP || status == :FROZEN
      x *= 2.5
    elsif status != :NONE
      x *= 1.5
    end

    x = x.floor
    x = 1 if x < 1
    return 1.0 if x >= 255

    y = (65536.0 / ((255.0 / x) ** 0.1875))
    per_shake = [[y / 65536.0, 0.0].max, 1.0].min
    chance = per_shake ** 4
    return [[chance, 0.0].max, 1.0].min
  rescue Exception => e
    append_action_log("ERROR", "capture chance estimate: #{e.class}: #{e.message}")
    return 0.0
  end

  def self.available_auto_capture_balls(battle, target)
    ret = []
    ball_inventory.each do |entry|
      ball_id = entry[0]
      ball_name = entry[1]
      quantity = entry[2]
      next if quantity <= 0
      next if !AUTO_CAPTURE_STANDARD_BALLS.include?(ball_id)

      chance = estimated_ball_chance(battle, target, ball_id)
      ret.push({
        :id => ball_id,
        :name => ball_name,
        :quantity => quantity,
        :chance => chance
      })
    end
    return ret
  rescue Exception
    return []
  end

  def self.choose_auto_capture_ball(battle, target)
    balls = available_auto_capture_balls(battle, target)
    return nil if balls.length == 0

    adequate = balls.select { |entry| entry[:chance] >= AUTO_CAPTURE_GOOD_CHANCE }
    if adequate.length > 0
      # Preserve stronger balls: use the weakest ball that still clears the
      # desired estimated catch chance.
      adequate.sort_by! { |entry| [entry[:chance], -entry[:quantity]] }
      return adequate[0]
    end

    # If none clear the target chance, use the best ordinary ball available.
    balls.sort_by! { |entry| [-entry[:chance], -entry[:quantity]] }
    return balls[0]
  end

  def self.try_tactician_auto_capture(battle, idx_battler, target)
    return false if !battle || !target || !target.pokemon
    return false if !safe_value(false) { battle.wildBattle? }
    return false if !tactician_auto_control?
    return false if !auto_capture_single_player_battler?(battle)
    return false if auto_capture_attempt_count(battle) >= AUTO_CAPTURE_MAX_ATTEMPTS

    evaluation = capture_evaluation(target.pokemon)
    return false if !evaluation || !evaluation[:worth_catching]

    # First implementation keeps full-party team replacement out of battle
    # automation. A successful catch can still be stored directly to PC below.
    ball = choose_auto_capture_ball(battle, target)
    if !ball
      append_action_log(
        "CAPTURE_SKIP",
        "#{safe_value("unknown") { target.name }} worth catching, but no ordinary ball available"
      )
      return false
    end

    user = safe_value(nil) { battle.battlers[idx_battler] }
    return false if !user

    can_use = safe_value(false) {
      ItemHandlers.triggerCanUseInBattle(
        ball[:id],
        target.pokemon,
        target,
        nil,
        true,
        battle,
        battle.scene,
        false
      )
    }
    if !can_use
      append_action_log(
        "CAPTURE_SKIP",
        "#{safe_value("unknown") { target.name }} | #{ball[:name]} cannot be used now"
      )
      return false
    end

    if battle.pbRegisterItem(idx_battler, ball[:id], target.index, nil)
      attempt = increment_auto_capture_attempt(battle)
      @auto_capture_postprocess = true
      append_action_log(
        "CAPTURE",
        "#{safe_value("unknown") { target.name }} | attempt #{attempt}/#{AUTO_CAPTURE_MAX_ATTEMPTS} | " +
        "#{ball[:name]} | estimated #{format("%.1f", ball[:chance] * 100.0)}% | " +
        "style #{evaluation[:style_key]} | effective delta #{format("%+.2f", evaluation[:effective_delta])}"
      )
      return true
    end

    append_action_log(
      "CAPTURE_SKIP",
      "#{safe_value("unknown") { target.name }} | failed to register #{ball[:name]}"
    )
    return false
  rescue Exception => e
    append_action_log("ERROR", "auto capture: #{e.class}: #{e.message}")
    return false
  end
end

Events.onStartBattle += proc { |_sender|
  PIFBot.reset_auto_capture_runtime
}

Events.onEndBattle += proc { |_sender, _event_data|
  PIFBot.instance_variable_set(:@auto_capture_postprocess, false)
}

# Automatic catches should not stop on the optional nickname prompt.
class PokeBattle_Battle
  unless method_defined?(:pifbot_capture_store_original_pbStorePokemon)
    alias_method :pifbot_capture_store_original_pbStorePokemon, :pbStorePokemon

    def pbStorePokemon(pkmn)
      if PIFBot.auto_capture_postprocess? && $PokemonSystem
        old_prompt = $PokemonSystem.prompt_nicknames
        begin
          $PokemonSystem.prompt_nicknames = false
          return pifbot_capture_store_original_pbStorePokemon(pkmn)
        ensure
          $PokemonSystem.prompt_nicknames = old_prompt
        end
      end
      pifbot_capture_store_original_pbStorePokemon(pkmn)
    end
  end
end

# If the party is already full, preserve the newly caught Pokemon in the PC
# rather than opening the manual swap/fuse/store menu. A future team-builder
# pass will choose the active six from all owned Pokemon.
class Object
  unless private_method_defined?(:pifbot_capture_original_promptCaughtPokemonAction)
    alias_method :pifbot_capture_original_promptCaughtPokemonAction, :promptCaughtPokemonAction

    def promptCaughtPokemonAction(pokemon)
      if PIFBot.auto_capture_postprocess?
        return pbStorePokemon(pokemon)
      end
      return pifbot_capture_original_promptCaughtPokemonAction(pokemon)
    end
    private :promptCaughtPokemonAction
  end
end

# The Pokédex has already been registered before this display call. Skip only
# the interactive "new Pokédex entry" screen for autonomous catches.
class PokeBattle_Scene
  unless method_defined?(:pifbot_capture_original_pbShowPokedex)
    alias_method :pifbot_capture_original_pbShowPokedex, :pbShowPokedex

    def pbShowPokedex(pokemon)
      if PIFBot.auto_capture_postprocess?
        PIFBot.append_action_log(
          "CAPTURE",
          "skipped interactive Pokédex entry display for #{pokemon.name}"
        )
        return
      end
      pifbot_capture_original_pbShowPokedex(pokemon)
    end
  end
end
