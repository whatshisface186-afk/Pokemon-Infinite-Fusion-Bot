# Tactician team-style planner v0.1
# Rolls one strategic archetype per save/run and stores it in PokemonGlobalMetadata.
# This file only selects/persists/reports the plan. Catch/fusion/team scoring will
# consume the selected style in the next stage.

class PokemonGlobalMetadata
  attr_accessor :pifbot_tactician_team_style
  attr_accessor :pifbot_tactician_team_style_version
end

module PIFBot
  TEAM_STYLE_REPORT_PATH = "Data/pif_bot_team_style.txt"
  TEAM_STYLE_VERSION = 2

  TEAM_STYLES = {
    :BALANCE => {
      :name => "Balance",
      :identity => "Flexible team with offense, bulk, speed, coverage and safe switching.",
      :core => ["broad offensive coverage", "defensive type synergy", "mixed speed tiers", "reliable switch-ins"],
      :signals => ["coverage", "bulk", "recovery", "pivoting", "few severe shared weaknesses"]
    },
    :HYPER_OFFENSE => {
      :name => "Hyper Offense",
      :identity => "Win through speed, immediate pressure and setup before the opponent stabilizes.",
      :core => ["fast attackers", "setup sweepers", "high damage", "minimal passive play"],
      :signals => ["high Attack/Sp. Atk", "high Speed", "setup moves", "priority", "strong STAB"]
    },
    :BULKY_OFFENSE => {
      :name => "Bulky Offense",
      :identity => "Use durable attackers that can absorb hits without giving up pressure.",
      :core => ["strong bulk", "meaningful damage", "good defensive typing", "recovery or sustain"],
      :signals => ["HP/Defense/Sp. Def", "resistances", "draining/recovery moves", "strong neutral damage"]
    },
    :STALL => {
      :name => "Stall",
      :identity => "Win through longevity, status, recovery, disruption and passive damage.",
      :core => ["recovery", "status", "defensive synergy", "passive damage"],
      :signals => ["Toxic/burn", "healing", "Protect-like effects", "Leech Seed", "phazing", "high bulk"]
    },
    :HAZARD_STACK => {
      :name => "Hazard Stack",
      :identity => "Accumulate entry hazards and repeatedly force or exploit switches.",
      :core => ["Stealth Rock", "Spikes/Toxic Spikes", "phazing", "switch pressure"],
      :signals => ["hazard setters", "Roar/Whirlwind-like effects", "spin pressure", "durable setters"]
    },
    :RAIN => {
      :name => "Rain",
      :identity => "Build around Rain and Pokemon that gain offensive, defensive or speed advantages from it.",
      :core => ["reliable rain", "Water payoff", "rain abilities", "weather-compatible coverage"],
      :signals => ["Drizzle", "Rain Dance", "Swift Swim", "Dry Skin", "Thunder", "Water STAB"]
    },
    :SUN => {
      :name => "Sun",
      :identity => "Build around harsh sunlight and Pokemon that exploit Fire/Grass/weather interactions.",
      :core => ["reliable sun", "Fire payoff", "sun abilities", "Solar-move synergy"],
      :signals => ["Drought", "Sunny Day", "Chlorophyll", "Solar Beam", "Fire STAB", "sun healing"]
    },
    :SAND => {
      :name => "Sand",
      :identity => "Use Sandstorm plus Rock/Ground/Steel and sand-benefiting abilities for durable pressure.",
      :core => ["reliable sand", "sand-safe core", "sand abilities", "residual pressure"],
      :signals => ["Sand Stream", "Sandstorm", "Sand Rush", "Sand Force", "Rock/Ground/Steel typing"]
    },
    :HAIL => {
      :name => "Hail",
      :identity => "Use Hail and Ice-focused synergies, especially accurate Blizzard and weather abilities.",
      :core => ["reliable hail", "Ice payoff", "weather abilities", "coverage for Ice weaknesses"],
      :signals => ["Snow Warning", "Hail", "Blizzard", "Ice Body", "Slush Rush", "Ice STAB"]
    },
    :TRICK_ROOM => {
      :name => "Trick Room",
      :identity => "Reverse speed control so slow, powerful Pokemon move first.",
      :core => ["reliable Trick Room", "slow attackers", "bulky setters", "high immediate power"],
      :signals => ["Trick Room", "low Speed", "high offense", "bulk", "slow fusion combinations"]
    },
    :SETUP_SWEEP => {
      :name => "Setup Sweep",
      :identity => "Create safe setup opportunities and convert boosts into a sweep.",
      :core => ["setup moves", "setup opportunities", "sweepers", "support for setup"],
      :signals => ["Swords Dance", "Dragon Dance", "Calm Mind", "Quiver Dance", "Nasty Plot", "Shell Smash"]
    },
    :PRIORITY_OFFENSE => {
      :name => "Priority Offense",
      :identity => "Use strong priority and offensive pressure to reduce dependence on raw Speed.",
      :core => ["priority attacks", "high offense", "cleanup roles", "good STAB priority"],
      :signals => ["Extreme Speed", "Bullet Punch", "Mach Punch", "Aqua Jet", "Sucker Punch", "Ice Shard"]
    },
    :PIVOT_MOMENTUM => {
      :name => "Pivot / Momentum",
      :identity => "Keep advantageous matchups through repeated switching and pivot moves.",
      :core => ["pivot moves", "switch synergy", "resistances", "matchup control"],
      :signals => ["U-turn", "Volt Switch", "Parting Shot", "Regenerator-like sustain", "complementary resistances"]
    },
    :STATUS_CONTROL => {
      :name => "Status Control",
      :identity => "Cripple opponents with sleep, paralysis, burn or poison and exploit the resulting tempo.",
      :core => ["reliable status", "status exploitation", "defensive support", "safe finishing power"],
      :signals => ["sleep", "paralysis", "burn", "poison", "Hex-like payoff", "speed control"]
    }
  }

  STYLE_MOVE_GROUPS = {
    :recovery => [:RECOVER, :ROOST, :SOFTBOILED, :MILKDRINK, :SLACKOFF, :MOONLIGHT, :MORNINGSUN, :SYNTHESIS, :REST, :WISH, :AQUARING, :INGRAIN],
    :drain => [:GIGADRAIN, :MEGADRAIN, :DRAINPUNCH, :DRAININGKISS, :HORNLEECH, :LEECHLIFE, :PARABOLICCHARGE],
    :status => [:TOXIC, :WILLOWISP, :THUNDERWAVE, :GLARE, :SPORE, :SLEEPPOWDER, :HYPNOSIS, :YAWN, :STUNSPORE, :POISONPOWDER],
    :passive => [:LEECHSEED, :TOXIC, :WILLOWISP, :SANDSTORM, :HAIL],
    :protect => [:PROTECT, :DETECT, :KINGSSHIELD, :SPIKYSHIELD, :BANEFULBUNKER],
    :phazing => [:ROAR, :WHIRLWIND, :DRAGONTAIL, :CIRCLETHROW],
    :hazards => [:STEALTHROCK, :SPIKES, :TOXICSPIKES, :STICKYWEB],
    :setup => [:SWORDSDANCE, :DRAGONDANCE, :CALMMIND, :QUIVERDANCE, :NASTYPLOT, :SHELLSMASH, :BULKUP, :COIL, :CURSE, :AGILITY, :ROCKPOLISH],
    :priority => [:EXTREMESPEED, :BULLETPUNCH, :MACHPUNCH, :AQUAJET, :SUCKERPUNCH, :ICESHARD, :SHADOWSNEAK, :VACUUMWAVE, :QUICKATTACK],
    :pivot => [:UTURN, :VOLTSWITCH, :PARTINGSHOT, :FLIPTURN],
    :rain => [:RAINDANCE, :THUNDER, :HURRICANE],
    :sun => [:SUNNYDAY, :SOLARBEAM, :SOLARBLADE, :MORNINGSUN, :SYNTHESIS],
    :sand => [:SANDSTORM],
    :hail => [:HAIL, :BLIZZARD],
    :trick_room => [:TRICKROOM]
  }

  STYLE_ABILITY_GROUPS = {
    :rain => [:DRIZZLE, :SWIFTSWIM, :DRYSKIN, :RAINDISH, :HYDRATION],
    :sun => [:DROUGHT, :CHLOROPHYLL, :SOLARPOWER, :FLOWERGIFT, :LEAFGUARD],
    :sand => [:SANDSTREAM, :SANDRUSH, :SANDFORCE, :SANDVEIL],
    :hail => [:SNOWWARNING, :SLUSHRUSH, :ICEBODY, :SNOWCLOAK]
  }

  def self.style_move_count(move_ids, group)
    wanted = STYLE_MOVE_GROUPS[group] || []
    count = 0
    move_ids.each do |move_id|
      count += 1 if wanted.include?(move_id)
    end
    return count
  end

  def self.tactician_style_fit(species_data, move_ids = [], ability_id = nil)
    key = tactician_team_style_key
    return { :score => 0.0, :reasons => [] } if !key || !species_data

    stats = safe_value({}) { species_data.base_stats }
    hp  = safe_value(1) { stats[:HP] }
    atk = safe_value(1) { stats[:ATTACK] }
    dfn = safe_value(1) { stats[:DEFENSE] }
    spa = safe_value(1) { stats[:SPECIAL_ATTACK] }
    spd = safe_value(1) { stats[:SPECIAL_DEFENSE] }
    spe = safe_value(1) { stats[:SPEED] }
    offense = [atk, spa].max
    bulk = (hp + dfn + spd) / 3.0
    types = safe_value([]) { species_data.types }.uniq

    score = 0.0
    reasons = []

    add = proc do |points, reason|
      next if points <= 0
      score += points
      reasons.push(reason)
    end

    case key
    when :BALANCE
      add.call([[offense / 180.0 * 5.0, 5.0].min, 0.0].max, "usable offensive profile")
      add.call([[bulk / 180.0 * 5.0, 5.0].min, 0.0].max, "usable bulk")
      add.call([[spe / 180.0 * 3.0, 3.0].min, 0.0].max, "speed contribution")
      add.call(2.0, "dual typing") if types.length >= 2
      add.call([style_move_count(move_ids, :recovery), 1].min * 2.0, "recovery access")
      add.call([style_move_count(move_ids, :pivot), 1].min * 3.0, "pivot access")
    when :HYPER_OFFENSE
      add.call([[offense / 180.0 * 8.0, 8.0].min, 0.0].max, "high offensive stat")
      add.call([[spe / 180.0 * 6.0, 6.0].min, 0.0].max, "speed")
      add.call([style_move_count(move_ids, :setup), 1].min * 4.0, "setup move")
      add.call([style_move_count(move_ids, :priority), 1].min * 2.0, "priority")
    when :BULKY_OFFENSE
      add.call([[bulk / 180.0 * 8.0, 8.0].min, 0.0].max, "bulk")
      add.call([[offense / 180.0 * 7.0, 7.0].min, 0.0].max, "offensive pressure")
      sustain = style_move_count(move_ids, :recovery) + style_move_count(move_ids, :drain)
      add.call([sustain, 1].min * 3.0, "sustain")
      add.call(2.0, "dual typing") if types.length >= 2
    when :STALL
      add.call([[bulk / 180.0 * 10.0, 10.0].min, 0.0].max, "high bulk")
      add.call([style_move_count(move_ids, :recovery), 1].min * 4.0, "recovery")
      add.call([style_move_count(move_ids, :status), 1].min * 3.0, "status")
      passive = style_move_count(move_ids, :passive) + style_move_count(move_ids, :protect) + style_move_count(move_ids, :phazing)
      add.call([passive, 1].min * 3.0, "passive damage/protection/phazing")
    when :HAZARD_STACK
      add.call([style_move_count(move_ids, :hazards), 2].min * 6.0, "entry hazards")
      add.call([style_move_count(move_ids, :phazing), 1].min * 4.0, "phazing")
      add.call([[bulk / 180.0 * 4.0, 4.0].min, 0.0].max, "setter durability")
    when :RAIN
      add.call(5.0, "Water typing") if types.include?(:WATER)
      add.call(2.0, "Electric typing") if types.include?(:ELECTRIC)
      add.call([style_move_count(move_ids, :rain), 2].min * 4.0, "rain move synergy")
      add.call(7.0, "known rain ability") if STYLE_ABILITY_GROUPS[:rain].include?(ability_id)
      add.call([[spe / 180.0 * 2.0, 2.0].min, 0.0].max, "speed")
    when :SUN
      add.call(5.0, "Fire typing") if types.include?(:FIRE)
      add.call(4.0, "Grass typing") if types.include?(:GRASS)
      add.call([style_move_count(move_ids, :sun), 2].min * 4.0, "sun move synergy")
      add.call(7.0, "known sun ability") if STYLE_ABILITY_GROUPS[:sun].include?(ability_id)
    when :SAND
      sand_types = types.select { |t| [:ROCK, :GROUND, :STEEL].include?(t) }
      add.call([sand_types.length, 2].min * 4.0, "sand-safe typing")
      add.call([style_move_count(move_ids, :sand), 1].min * 5.0, "Sandstorm access")
      add.call(7.0, "known sand ability") if STYLE_ABILITY_GROUPS[:sand].include?(ability_id)
      add.call([[bulk / 180.0 * 3.0, 3.0].min, 0.0].max, "sand core bulk")
    when :HAIL
      add.call(7.0, "Ice typing") if types.include?(:ICE)
      add.call([style_move_count(move_ids, :hail), 2].min * 4.0, "hail/Blizzard synergy")
      add.call(7.0, "known hail ability") if STYLE_ABILITY_GROUPS[:hail].include?(ability_id)
      add.call([[spa / 180.0 * 2.0, 2.0].min, 0.0].max, "special pressure")
    when :TRICK_ROOM
      slow_score = [[(180.0 - [spe, 180].min) / 180.0 * 8.0, 8.0].min, 0.0].max
      add.call(slow_score, "low Speed")
      add.call([[offense / 180.0 * 6.0, 6.0].min, 0.0].max, "high offense")
      add.call([[bulk / 180.0 * 3.0, 3.0].min, 0.0].max, "setter/attacker bulk")
      add.call([style_move_count(move_ids, :trick_room), 1].min * 6.0, "Trick Room access")
    when :SETUP_SWEEP
      add.call([style_move_count(move_ids, :setup), 1].min * 8.0, "setup move")
      add.call([[offense / 180.0 * 6.0, 6.0].min, 0.0].max, "sweeper offense")
      add.call([[spe / 180.0 * 4.0, 4.0].min, 0.0].max, "sweeper speed")
      add.call([[bulk / 180.0 * 2.0, 2.0].min, 0.0].max, "setup durability")
    when :PRIORITY_OFFENSE
      add.call([style_move_count(move_ids, :priority), 2].min * 7.0, "priority attack")
      add.call([[offense / 180.0 * 6.0, 6.0].min, 0.0].max, "priority damage potential")
    when :PIVOT_MOMENTUM
      add.call([style_move_count(move_ids, :pivot), 2].min * 7.0, "pivot move")
      add.call([[spe / 180.0 * 4.0, 4.0].min, 0.0].max, "fast pivot")
      add.call(3.0, "dual typing") if types.length >= 2
      add.call([[bulk / 180.0 * 2.0, 2.0].min, 0.0].max, "switching durability")
    when :STATUS_CONTROL
      add.call([style_move_count(move_ids, :status), 2].min * 7.0, "status access")
      add.call([[bulk / 180.0 * 5.0, 5.0].min, 0.0].max, "status-user bulk")
      add.call([[spe / 180.0 * 3.0, 3.0].min, 0.0].max, "status tempo")
    end

    score = 20.0 if score > 20.0
    return { :score => score, :reasons => reasons }
  rescue Exception => e
    append_action_log("ERROR", "style fit: #{e.class}: #{e.message}")
    return { :score => 0.0, :reasons => [] }
  end

  def self.ensure_tactician_team_style
    return nil if !$PokemonGlobal

    current = safe_value(nil) { $PokemonGlobal.pifbot_tactician_team_style }
    if current && TEAM_STYLES[current]
      return current
    end

    keys = TEAM_STYLES.keys
    selected = keys[rand(keys.length)]
    $PokemonGlobal.pifbot_tactician_team_style = selected
    $PokemonGlobal.pifbot_tactician_team_style_version = TEAM_STYLE_VERSION
    append_action_log("TEAM_STYLE", "selected #{TEAM_STYLES[selected][:name]} (#{selected})")
    return selected
  rescue Exception => e
    append_action_log("ERROR", "team style selection: #{e.class}: #{e.message}")
    return nil
  end

  def self.tactician_team_style
    key = ensure_tactician_team_style
    return nil if !key
    return TEAM_STYLES[key]
  end

  def self.tactician_team_style_key
    return ensure_tactician_team_style
  end

  def self.write_team_style_report(reason = "update")
    key = ensure_tactician_team_style
    return if !key
    data = TEAM_STYLES[key]

    File.open(TEAM_STYLE_REPORT_PATH, "w") do |f|
      f.write("Pokemon Infinite Fusion Bot - Tactician Team Style\n")
      f.write("Bot version: #{VERSION}\n")
      f.write("Planner version: #{TEAM_STYLE_VERSION}\n")
      f.write("Reason: #{reason}\n")
      f.write("Time: #{Time.now}\n\n")

      f.write("Personality: TACTICIAN\n")
      f.write("Selected team style: #{data[:name]}\n")
      f.write("Style key: #{key}\n")
      f.write("Selection: RANDOM, one style per save/run\n")
      f.write("Persistence: stored in PokemonGlobalMetadata with the save\n")
      f.write("Available style count: #{TEAM_STYLES.length}\n\n")

      f.write("Identity: #{data[:identity]}\n\n")

      f.write("Core team goals:\n")
      data[:core].each { |goal| f.write("  - #{goal}\n") }

      f.write("\nPreferred signals:\n")
      data[:signals].each { |signal| f.write("  - #{signal}\n") }

      f.write("\nCurrent implementation stage:\n")
      f.write("  - Style selection and save persistence: ACTIVE\n")
      f.write("  - Reporting: ACTIVE\n")
      f.write("  - Style-aware catch scoring: ACTIVE\n")
      f.write("  - Style-aware fusion scoring: ACTIVE FOR CAPTURE PROJECTIONS\n")
      f.write("  - Style-aware final party construction: NOT YET ACTIVE\n")
      f.write("  - Feasibility-based reroll after prolonged failure to find core pieces: PLANNED\n")
    end
  rescue Exception => e
    begin
      File.open("Data/pif_bot_team_style_error.txt", "w") do |f|
        f.write("#{e.class}: #{e.message}\n")
        f.write(e.backtrace.join("\n")) if e.backtrace
      end
    rescue Exception
    end
  end
end

Events.onMapChange += proc { |_sender, _event_data|
  PIFBot.write_team_style_report("map_change")
}

Events.onStartBattle += proc { |_sender|
  PIFBot.write_team_style_report("battle_start")
}
