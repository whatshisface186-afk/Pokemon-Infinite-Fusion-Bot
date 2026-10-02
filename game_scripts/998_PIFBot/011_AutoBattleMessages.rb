# PIFBot automatic battle-message handling v0.1
#
# Infinite Fusion's paused battle messages intentionally wait forever at the
# end of a battle. That is correct for a human player but deadlocks autonomous
# Tactician/self-test runs on messages such as "got X Exp. Points!".
#
# While Tactician battle control is active, convert only PAUSED INFORMATIONAL
# battle messages to the engine's normal auto-closing message path.
#
# Deliberately NOT touched:
# - command menus
# - yes/no confirmations
# - move-learning choices
# - party/item selection screens
#
# F7 manual takeover disables this automatically because it disables Tactician
# battle control.

module PIFBot
  def self.auto_advance_battle_messages?
    return false if !respond_to?(:tactician_auto_control?)
    return tactician_auto_control?
  rescue Exception
    return false
  end
end

class PokeBattle_Scene
  unless method_defined?(:pifbot_auto_message_original_pbDisplayPausedMessage)
    alias_method :pifbot_auto_message_original_pbDisplayPausedMessage, :pbDisplayPausedMessage

    def pbDisplayPausedMessage(msg, &block)
      if PIFBot.auto_advance_battle_messages?
        begin
          PIFBot.append_action_log(
            "AUTO_MESSAGE",
            msg.to_s.gsub(/[\r\n]+/, " ")
          )
        rescue Exception
        end

        # pbDisplayMessage(false) is the game's own ordinary informational
        # message routine. Unlike pbDisplayPausedMessage at battle end, it
        # auto-closes after its normal short delay and preserves any supplied
        # block (e.g. a sound effect that should play once text is shown).
        return pbDisplayMessage(msg, false, &block)
      end

      pifbot_auto_message_original_pbDisplayPausedMessage(msg, &block)
    end
  end
end
