# PIFBot automatic level-up stat handling v0.1
#
# Infinite Fusion's battle pbLevelUp shows TWO pbTopRightWindow panels:
#  1) stat gains
#  2) resulting total stats
# pbTopRightWindow waits indefinitely for Input::USE.
#
# While Tactician battle control is active, skip only those informational stat
# panels and log their contents instead. The battle's move-learning/evolution
# logic occurs after pbLevelUp returns and is intentionally left untouched here.
#
# Manual/F7 mode keeps the game's original level-up UI unchanged.

class PokeBattle_Scene
  unless method_defined?(:pifbot_levelup_original_pbLevelUp)
    alias_method :pifbot_levelup_original_pbLevelUp, :pbLevelUp

    def pbLevelUp(pkmn, battler, oldTotalHP, oldAttack, oldDefense,
                  oldSpAtk, oldSpDef, oldSpeed)
      if PIFBot.tactician_auto_control?
        begin
          hp_gain  = pkmn.totalhp - oldTotalHP
          atk_gain = pkmn.attack  - oldAttack
          def_gain = pkmn.defense - oldDefense
          spa_gain = pkmn.spatk   - oldSpAtk
          spd_gain = pkmn.spdef   - oldSpDef
          spe_gain = pkmn.speed   - oldSpeed

          PIFBot.append_action_log(
            "LEVEL_UP",
            "#{pkmn.name} Lv#{pkmn.level} | " +
            "gains HP +#{hp_gain}, Atk +#{atk_gain}, Def +#{def_gain}, " +
            "SpA +#{spa_gain}, SpD +#{spd_gain}, Spe +#{spe_gain} | " +
            "totals HP #{pkmn.totalhp}, Atk #{pkmn.attack}, Def #{pkmn.defense}, " +
            "SpA #{pkmn.spatk}, SpD #{pkmn.spdef}, Spe #{pkmn.speed}"
          )
        rescue Exception => e
          begin
            PIFBot.append_action_log(
              "ERROR",
              "level-up auto-advance log: #{e.class}: #{e.message}"
            )
          rescue Exception
          end
        end

        # The two stat windows are informational only. Returning here allows
        # the battle engine to continue immediately into any move-learning
        # checks and the rest of the normal level-up flow.
        return
      end

      pifbot_levelup_original_pbLevelUp(
        pkmn, battler, oldTotalHP, oldAttack, oldDefense,
        oldSpAtk, oldSpDef, oldSpeed
      )
    end
  end
end
