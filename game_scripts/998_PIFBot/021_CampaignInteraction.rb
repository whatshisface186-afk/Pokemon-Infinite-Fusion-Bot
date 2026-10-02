# PIFBot campaign interaction automation v0.1
#
# Handles two interaction classes that intentionally block a human:
# 1) ordinary map-event trainer/story text with no choice
# 2) Gym-leader confirmation choices and PokemonSelection team-entry screens
#
# Scope is deliberately narrow. Manual play and non-campaign menus keep the
# game's original behavior.

module PIFBot
  def self.campaign_current_interpreter_event_id(interpreter = nil)
    interpreter ||= safe_value(nil) { pbMapInterpreter }
    return nil if !interpreter
    return safe_value(nil) { interpreter.instance_variable_get(:@event_id) }
  end

  def self.campaign_leader_interpreter?(interpreter = nil)
    return false if !campaign_active?
    return false if safe_value(nil) { instance_variable_get(:@campaign_phase) } != :gym
    leader_event = safe_value(nil) { campaign_find_leader_event }
    return false if !leader_event
    return campaign_current_interpreter_event_id(interpreter) == safe_value(nil) { leader_event.id }
  rescue Exception
    return false
  end

  def self.campaign_choice_index(commands, default_index = 0)
    return default_index || 0 if !commands || commands.length == 0
    normalized = commands.map { |cmd| cmd.to_s.downcase.gsub(/[^a-z0-9 ]+/, " ").strip }

    # Positive/progression intent first.
    preferred = [
      /^yes$/, /challenge/, /battle/, /fight/, /ready/, /continue/,
      /^ok$/, /^okay$/, /proceed/, /let'?s do/
    ]
    preferred.each do |pattern|
      idx = normalized.index { |text| text =~ pattern }
      return idx if idx
    end

    # Never deliberately choose an obvious negative when another option exists.
    negative = [/^no$/, /cancel/, /back/, /not yet/, /later/]
    normalized.each_with_index do |text, idx|
      next if negative.any? { |pattern| text =~ pattern }
      return idx
    end
    return default_index || 0
  rescue Exception
    return default_index || 0
  end

  def self.campaign_gym_selection_active?
    return false if !campaign_active?
    return false if safe_value(nil) { instance_variable_get(:@campaign_phase) } != :gym
    map_name = safe_value("") { $game_map.name.to_s.downcase }
    return !map_name.index("gym").nil?
  rescue Exception
    return false
  end

  def self.campaign_rank_party_indexes(indexes, count)
    covered = []
    remaining = indexes.dup
    selected = []
    while selected.length < count && remaining.length > 0
      remaining.sort_by! do |idx|
        pkmn = safe_value(nil) { $Trainer.party[idx] }
        score = pkmn ? campaign_roster_score(pkmn, covered) : -9999.0
        -score
      end
      idx = remaining.shift
      selected.push(idx)
      pkmn = safe_value(nil) { $Trainer.party[idx] }
      if pkmn
        safe_value([]) { pkmn.types }.each do |type|
          covered.push(type) if !covered.include?(type)
        end
      end
    end
    return selected
  rescue Exception
    return indexes[0, count]
  end

  def self.campaign_note_gym_party_requirement(minimum, maximum = nil)
    minimum = minimum.to_i
    maximum = maximum.to_i if maximum
    return if minimum <= 0
    current = safe_value(0) { instance_variable_get(:@campaign_required_gym_party_size).to_i }
    needed = [current, minimum].max
    instance_variable_set(:@campaign_required_gym_party_size, needed)

    if campaign_owned_count < needed
      instance_variable_set(:@campaign_expand_until_owned_count, needed)
      instance_variable_set(:@campaign_phase, :training)
      append_action_log(
        "CAMPAIGN_TEAM",
        "Gym requires at least #{needed} Pokemon; owned #{campaign_owned_count}; expanding roster before retry"
      )
    end
    campaign_write_status("gym_party_requirement") if respond_to?(:campaign_write_status)
  rescue Exception => e
    append_action_log("ERROR", "gym party requirement: #{e.class}: #{e.message}")
  end
end

# Auto-advance only ordinary event text while F10 Campaign Mode is active.
# Text with choices or numeric input remains interactive, except for the
# narrowly targeted Gym-leader confirmation path below.
class Interpreter
  unless method_defined?(:pifbot_campaign_original_command_101)
    alias_method :pifbot_campaign_original_command_101, :command_101
  end

  def command_101
    if PIFBot.campaign_active?
      begin
        # Mirror the engine's look-ahead without consuming interpreter state.
        scan_index = @index
        text_indexes = [scan_index]
        choice_command = nil
        number_command = nil
        message_continues = false

        loop do
          next_index = pbNextIndex(scan_index)
          cmd = @list[next_index]
          break if !cmd
          case cmd.code
          when 401
            text_indexes.push(next_index)
            scan_index = next_index
            next
          when 101
            message_continues = true
          when 102
            choice_command = cmd
          when 103
            number_command = cmd
          end
          break
        end

        # Ordinary trainer/story dialogue: add the engine's own "wait then no
        # pause" control to the LAST text line. Choice/number prompts are never
        # modified by this branch.
        if !choice_command && !number_command
          last_index = text_indexes[-1]
          original = @list[last_index].parameters[0]
          text = original.to_s
          if text.index("\\wtnp[") == nil && text.index("\\^") == nil
            @list[last_index].parameters[0] = text + "\\wtnp[1]"
            begin
              PIFBot.append_action_log(
                "AUTO_DIALOG",
                text.gsub(/[\r\n]+/, " ")[0, 180]
              )
              return pifbot_campaign_original_command_101
            ensure
              @list[last_index].parameters[0] = original
            end
          end
        end

        # Gym leader confirmation attached to Show Text + Show Choices. Bypass
        # the command window and choose a positive/progression option directly.
        if choice_command && PIFBot.campaign_leader_interpreter?(self)
          message = @list[@index].parameters[0].to_s
          text_indexes[1..-1].to_a.each do |idx|
            part = @list[idx].parameters[0].to_s
            message += " " if part != "" && message[-1, 1] != " "
            message += part
          end
          message = _MAPINTL($game_map.map_id, message)
          translated = choice_command.parameters[0].map { |cmd| _MAPINTL($game_map.map_id, cmd) }
          choice = PIFBot.campaign_choice_index(translated, 0)

          @message_waiting = true
          pbMessage(message + (message_continues ? "\1" : "") + "\\wtnp[1]")
          # The original method consumes the choice command by moving @index to it.
          @index = @list.index(choice_command) || @index
          @branch[choice_command.indent] = choice
          @message_waiting = false

          PIFBot.append_action_log(
            "AUTO_CHOICE",
            "Gym leader choice #{choice}: #{translated[choice]}"
          )
          Input.update
          return true
        end
      rescue Exception => e
        PIFBot.append_action_log("ERROR", "campaign dialog automation: #{e.class}: #{e.message}")
      end
    end

    return pifbot_campaign_original_command_101
  end
end

# Infinite Fusion's PokemonSelection module is used by Gym leaders to restrict
# the player's battle party to the leader's team size. In Campaign Mode,
# Tactician chooses the strongest/style-coherent eligible subset automatically.
module PokemonSelection
  class << self
    unless method_defined?(:pifbot_campaign_original_choose)
      alias_method :pifbot_campaign_original_choose, :choose
    end

    def choose(min = 1, max = 6, canCancel = false, acceptFainted = false,
               ableproc = nil, indexesVar = nil)
      if PIFBot.campaign_gym_selection_active?
        minimum = min.to_i
        maximum = max.to_i
        maximum = minimum if maximum <= 0
        PIFBot.campaign_note_gym_party_requirement(minimum, maximum)

        ruleset = self.rules(minimum, maximum, canCancel, acceptFainted).ruleset
        eligible = []
        $Trainer.party.each_with_index do |pkmn, idx|
          next if !pkmn
          valid = begin
            ruleset.isPokemonValid?(pkmn, ableproc)
          rescue Exception
            acceptFainted || (begin pkmn.able? rescue false end)
          end
          eligible.push(idx) if valid
        end

        if eligible.length < minimum
          PIFBot.append_action_log(
            "CAMPAIGN_TEAM",
            "Gym selection deferred: needs #{minimum}, eligible #{eligible.length}"
          )
          return false
        end

        count = [maximum, eligible.length].min
        count = minimum if count < minimum
        selected_indexes = PIFBot.campaign_rank_party_indexes(eligible, count)
        selected_names = selected_indexes.map do |idx|
          begin
            $Trainer.party[idx].name
          rescue Exception
            "?"
          end
        end

        # force() uses the game's own saved-original-party mechanism, so the
        # ordinary Gym event can restore the full party after the battle.
        result = PokemonSelection.force(selected_indexes)
        pbSet(indexesVar, selected_indexes) if indexesVar && result

        if result
          PIFBot.append_action_log(
            "CAMPAIGN_TEAM",
            "auto-selected #{selected_indexes.length} Pokemon for Gym: #{selected_names.join(", ")}"
          )
        end
        return result
      end

      return pifbot_campaign_original_choose(
        min, max, canCancel, acceptFainted, ableproc, indexesVar
      )
    end
  end
end
