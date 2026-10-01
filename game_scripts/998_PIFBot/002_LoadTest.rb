# Harmless startup load test.
# If this script is evaluated by Infinite Fusion, it writes a marker file
# in the game's Data folder so we can confirm the bot code is being loaded.

begin
  File.open("Data/pif_bot_loaded.txt", "w") do |f|
    f.write("Pokemon Infinite Fusion Bot loaded successfully.\n")
    f.write("Bot version: #{PIFBot::VERSION}\n")
    f.write("Loaded at: #{Time.now}\n")
  end
rescue Exception => e
  echoln("PIFBot load test could not write marker: #{e}") if defined?(echoln)
end
