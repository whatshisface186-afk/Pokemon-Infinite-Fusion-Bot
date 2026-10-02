# PIFBot randomizer-error recovery v0.1
#
# Infinite Fusion's displayRandomizerErrorMessage() opens two blocking
# pbMessage dialogs. During F10 autonomous self-test mode, log the fault and
# return without opening those dialogs so one bad randomized encounter cannot
# strand the bot.
#
# After 3 randomizer faults in one F10 session, the navigator stops and writes
# "repeated_randomizer_errors" to the summary. Outside autonomous navigation,
# the game's original warning UI is preserved unchanged.

class Object
  if private_method_defined?(:displayRandomizerErrorMessage) &&
     !private_method_defined?(:pifbot_original_displayRandomizerErrorMessage)
    alias_method :pifbot_original_displayRandomizerErrorMessage,
                 :displayRandomizerErrorMessage
  end

  def displayRandomizerErrorMessage
    autonomous = false
    begin
      autonomous = PIFBot.navigation_active? ||
                   PIFBot.instance_variable_get(:@nav_pending_stop)
    rescue Exception
      autonomous = false
    end

    if autonomous
      begin
        PIFBot.navigation_handle_randomizer_error(caller)
      rescue Exception
      end
      return
    end

    if respond_to?(:pifbot_original_displayRandomizerErrorMessage, true)
      return pifbot_original_displayRandomizerErrorMessage
    end

    # Defensive fallback only if the original method unexpectedly disappeared.
    Kernel.pbMessage(
      _INTL("The randomizer has encountered an error. You should try to re-randomize your game as soon as possible.")
    )
    Kernel.pbMessage(
      _INTL("You can do this on the top floor of Pokémon Centers.")
    )
  end

  private :displayRandomizerErrorMessage
end
