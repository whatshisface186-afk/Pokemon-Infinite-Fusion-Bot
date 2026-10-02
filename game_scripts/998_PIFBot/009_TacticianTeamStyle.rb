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
  TEAM_STYLE_VERSION = 1

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
      f.write("  - Style-aware catch scoring: NOT YET ACTIVE\n")
      f.write("  - Style-aware fusion scoring: NOT YET ACTIVE\n")
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
