# PIFBot autonomous run stop notification v0.1
#
# Gives the spectator immediate feedback when F10 navigation stops.
# - Non-blocking: no message box that needs a button press.
# - Audible: uses an existing Infinite Fusion sound effect.
# - Persistent: writes the latest stop reason to Data/pif_bot_stop_notice.txt.
#
# The notification is intentionally separate from the debug report so a stop
# can be noticed immediately without opening a file.

module PIFBot
  STOP_NOTICE_PATH = "Data/pif_bot_stop_notice.txt"

  def self.write_stop_notice(reason)
    File.open(STOP_NOTICE_PATH, "wb") do |f|
      f.write("Pokemon Infinite Fusion Bot - STOPPED\n")
      f.write("Time: #{Time.now}\n")
      f.write("Reason: #{reason}\n")
      f.write("Map: #{safe_value("unknown") { $game_map ? $game_map.name : "unknown" }}\n")
      f.write("Position: #{safe_value("?") { $game_player ? $game_player.x : "?" }},#{safe_value("?") { $game_player ? $game_player.y : "?" }}\n")
      f.write("Wild battles: #{safe_value(0) { instance_variable_get(:@nav_wild_battles) }}/#{safe_value("?") { NAV_TARGET_WILD_BATTLES }}\n")
      f.write("Steps: #{safe_value(0) { instance_variable_get(:@nav_steps) }}\n")
    end
  rescue Exception
  end

  def self.play_stop_sound
    begin
      # This is an existing Infinite Fusion SE also used by the game when an EXP
      # bar fills. It is noticeable without opening a blocking dialog.
      if FileTest.audio_exist?("Audio/SE/Pkmn exp full")
        pbSEPlay("Pkmn exp full", 100, 80)
      else
        # Widely used built-in GUI confirmation sound as a fallback.
        pbSEPlay("GUI save choice", 100, 80)
      end
    rescue Exception
      begin
        pbSEPlay("GUI save choice")
      rescue Exception
      end
    end
  end

  def self.notify_navigation_stop(reason)
    write_stop_notice(reason)
    play_stop_sound
    append_action_log("BOT_STOPPED", reason) if respond_to?(:append_action_log)
    return true
  rescue Exception
    return false
  end
end
