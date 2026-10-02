# PIFBot automatic Poké Ball restocking v0.1
#
# Campaign policy:
# - When ordinary auto-capture balls fall to 5 or fewer, pause the current
#   campaign objective and visit the nearest reachable Poké Mart.
# - Walk to the Mart through the normal world router and start the real Mart
#   event/clerk event. The purchase hook uses the Mart's actual stock, current
#   price overrides, Trainer money and Bag storage rather than granting items.
# - Restock toward 20 usable capture balls.
# - Normally preserve $500 for other needs. If the bag has zero usable balls,
#   allow an emergency purchase of up to 5 balls even if that dips into reserve.
# - A 10+ ball purchase gets the same one-Premier-Ball bonus as the game's Mart.
# - After shopping, leave the Mart and route back to the map where restocking
#   interrupted the campaign; normal campaign phase selection then resumes.
#
# This intentionally avoids fragile menu-key timing. The player still travels to
# and talks to a real Mart clerk; only the repetitive Buy/quantity/confirm UI is
# completed directly from the stock passed to pbPokemonMart.

module PIFBot
  CAMPAIGN_BALL_RESTOCK_TRIGGER = 5
  CAMPAIGN_BALL_RESTOCK_TARGET = 20
  CAMPAIGN_BALL_RESTOCK_CASH_RESERVE = 500
  CAMPAIGN_BALL_RESTOCK_EMERGENCY_TARGET = 5
  CAMPAIGN_BALL_RESTOCK_MAP_SEARCH_LIMIT = 100
  CAMPAIGN_BALL_RESTOCK_MAP_HOP_LIMIT = 18

  # Infinite Fusion's Kanto/common-Mart exit table. These are the exterior city
  # maps that contain the corresponding enter_pokemart event. Off-screen RPG
  # map events do not expose the same live event list as the current Game_Map,
  # so use the game's own stable city map IDs for discovery and inspect the
  # actual entrance event only after arriving.
  CAMPAIGN_KANTO_MART_ENTRANCES = {
    :PEWTER     => [380, 43, 24],
    :CERULEAN   => [1, 24, 22],
    :VERMILLION => [19, 32, 13],
    :LAVENDER   => [50, 20, 23],
    :CELADON    => [95, 18, 15],
    :FUCHSIA    => [472, 7, 17],
    :SAFFRON    => [108, 53, 24],
    :CINNABAR   => [98, 30, 30]
  }

  @campaign_ball_restock_active = false
  @campaign_ball_restock_phase = nil
  @campaign_ball_restock_resume_map = nil
  @campaign_ball_restock_mart_map = nil
  @campaign_ball_restock_mart_city = nil
  @campaign_ball_restock_mart_source = nil
  @campaign_ball_restock_event_id = nil
  @campaign_ball_restock_path = []
  @campaign_ball_restock_tried_shop_events = {}
  @campaign_ball_restock_blocked_money = nil
  @campaign_ball_restock_next_retry_battle = 0
  @campaign_ball_restock_last_result = nil
  @campaign_ball_restock_last_item = nil
  @campaign_ball_restock_last_quantity = 0
  @campaign_ball_restock_last_spent = 0

  def self.campaign_ball_ids
    if const_defined?(:AUTO_CAPTURE_STANDARD_BALLS)
      return AUTO_CAPTURE_STANDARD_BALLS
    end
    return [
      :POKEBALL, :PREMIERBALL, :GREATBALL, :ULTRABALL,
      :NETBALL, :DIVEBALL, :NESTBALL, :REPEATBALL, :TIMERBALL,
      :DUSKBALL, :QUICKBALL, :FASTBALL, :LEVELBALL, :LUREBALL,
      :HEAVYBALL, :LOVEBALL, :MOONBALL, :DREAMBALL
    ]
  end

  def self.campaign_ball_count
    return 0 if !$PokemonBag
    return campaign_ball_ids.inject(0) do |sum, item_id|
      sum + safe_value(0) { $PokemonBag.pbQuantity(item_id) }.to_i
    end
  rescue Exception
    return 0
  end

  def self.campaign_ball_restock_active?
    return @campaign_ball_restock_active == true
  end

  def self.campaign_ball_restock_waiting_for_shop?
    return campaign_ball_restock_active? && @campaign_ball_restock_phase == :shop
  end

  def self.campaign_ball_restock_reset_runtime
    @campaign_ball_restock_active = false
    @campaign_ball_restock_phase = nil
    @campaign_ball_restock_resume_map = nil
    @campaign_ball_restock_mart_map = nil
    @campaign_ball_restock_mart_city = nil
    @campaign_ball_restock_mart_source = nil
    @campaign_ball_restock_event_id = nil
    @campaign_ball_restock_path = []
    @campaign_ball_restock_tried_shop_events = {}
    @campaign_ball_restock_blocked_money = nil
    @campaign_ball_restock_next_retry_battle = 0
    @campaign_ball_restock_last_result = nil
    @campaign_ball_restock_last_item = nil
    @campaign_ball_restock_last_quantity = 0
    @campaign_ball_restock_last_spent = 0
  end

  def self.campaign_ball_restock_needed?
    return false if !$Trainer || !$PokemonBag
    return false if campaign_ball_restock_active?
    return false if campaign_ball_count > CAMPAIGN_BALL_RESTOCK_TRIGGER

    current_battles = safe_value(0) { @nav_wild_battles || 0 }
    return false if current_battles < (@campaign_ball_restock_next_retry_battle || 0)

    money = safe_value(0) { $Trainer.money }.to_i
    if money <= 0
      if @campaign_ball_restock_blocked_money != money
        append_action_log("BALL_RESTOCK", "restock deferred: no money available")
      end
      @campaign_ball_restock_blocked_money = money
      return false
    end
    if @campaign_ball_restock_blocked_money &&
       money <= @campaign_ball_restock_blocked_money.to_i
      return false
    end

    # Don't interrupt an active Gym event/battle path just to shop. At campaign
    # start (phase nil) or during training/travel/rebuild, restocking is useful.
    phase = safe_value(nil) { @campaign_phase }
    return true if phase.nil?
    return [
      :training, :travel_training, :rebuild_team, :recover_after_loss
    ].include?(phase)
  rescue Exception
    return false
  end

  def self.campaign_map_has_mart_entrance?(map_id)
    map = safe_value(nil) { center_map_for_plan(map_id) }
    return false if !map

    safe_value({}) { map.events }.each_value do |event|
      next if !event
      script = safe_value("") { campaign_event_script_text(event).downcase }
      return true if !script.index("enter_pokemart").nil?
    end
    return false
  rescue Exception
    return false
  end

  def self.campaign_known_mart_candidates(start_map)
    candidates = []
    CAMPAIGN_KANTO_MART_ENTRANCES.each do |city, entry|
      map_id = entry[0]
      route = safe_value(nil) { center_map_route(start_map, map_id) }
      next if !route
      next if route.length - 1 > CAMPAIGN_BALL_RESTOCK_MAP_HOP_LIMIT
      candidates.push({
        :city => city,
        :map_id => map_id,
        :hops => route.length - 1,
        :x => entry[1],
        :y => entry[2]
      })
    end
    candidates.sort_by! { |entry| [entry[:hops], entry[:map_id]] }
    return candidates
  rescue Exception
    return []
  end

  def self.campaign_find_nearest_mart_map(start_map = nil)
    start_map ||= safe_value(nil) { $game_map.map_id }
    return nil if !start_map

    center_reset_plan_cache if respond_to?(:center_reset_plan_cache)

    # First use Infinite Fusion's own known Kanto Mart exterior maps. This fixes
    # the original implementation, which tried to read live event lists from
    # off-screen maps and therefore could not "see" Pewter's Mart from Route 3.
    known = campaign_known_mart_candidates(start_map)
    known.each do |entry|
      path = safe_value(nil) { campaign_plan_path_to_map(entry[:map_id]) }
      next if !path

      append_action_log(
        "BALL_RESTOCK",
        "selected known Mart #{entry[:city]} | map #{entry[:map_id]} | " +
        "#{entry[:hops]} map hops | #{path.length} walking steps"
      )
      @campaign_ball_restock_mart_city = entry[:city]
      @campaign_ball_restock_mart_source = :known_game_table
      return entry[:map_id]
    end

    # Fallback: if a future/custom map is currently loaded and visibly contains
    # a Mart entrance event, it is safe to use it directly.
    if campaign_map_has_mart_entrance?(start_map)
      append_action_log(
        "BALL_RESTOCK",
        "selected current-map Mart entrance | map #{start_map}"
      )
      @campaign_ball_restock_mart_city = nil
      @campaign_ball_restock_mart_source = :current_map_event
      return start_map
    end

    append_action_log(
      "BALL_RESTOCK",
      "no route to known Mart maps from map #{start_map}"
    )
    return nil
  rescue Exception => e
    append_action_log("ERROR", "find Mart map: #{e.class}: #{e.message}")
    return nil
  end

  def self.campaign_ball_restock_begin
    return true if campaign_ball_restock_active?
    return false if !$game_map || !$game_player

    mart_map = campaign_find_nearest_mart_map
    if !mart_map
      @campaign_ball_restock_next_retry_battle =
        safe_value(0) { @nav_wild_battles || 0 } + 5
      return false
    end

    @campaign_ball_restock_active = true
    @campaign_ball_restock_resume_map = $game_map.map_id
    @campaign_ball_restock_mart_map = mart_map
    @campaign_ball_restock_event_id = nil
    @campaign_ball_restock_path = []
    @campaign_ball_restock_tried_shop_events = {}
    @campaign_ball_restock_last_result = "traveling_to_mart"

    append_action_log(
      "BALL_RESTOCK",
      "triggered at #{campaign_ball_count} usable balls | target #{CAMPAIGN_BALL_RESTOCK_TARGET} | " +
      "money $#{safe_value(0) { $Trainer.money }} | resume map #{@campaign_ball_restock_resume_map}"
    )

    if $game_map.map_id == mart_map
      @campaign_ball_restock_phase = :enter
      @campaign_phase = :ball_restock
      return true
    end

    if campaign_begin_route(mart_map, "travel to Poké Mart for ball restock")
      @campaign_ball_restock_phase = :travel
      @campaign_phase = :ball_restock
      return true
    end

    append_action_log("BALL_RESTOCK", "could not plan route to Mart map #{mart_map}")
    @campaign_ball_restock_active = false
    @campaign_ball_restock_next_retry_battle =
      safe_value(0) { @nav_wild_battles || 0 } + 5
    return false
  rescue Exception => e
    append_action_log("ERROR", "begin ball restock: #{e.class}: #{e.message}")
    @campaign_ball_restock_active = false
    return false
  end

  def self.campaign_find_current_event_by_script(token, excluded_ids = nil)
    return nil if !$game_map || !$game_player
    token = token.to_s.downcase
    excluded_ids ||= {}

    matches = []
    safe_value({}) { $game_map.events }.each_value do |event|
      next if !event
      id = safe_value(nil) { event.id }
      next if id && excluded_ids[id]
      script = safe_value("") { campaign_event_script_text(event).downcase }
      next if script.index(token).nil?
      distance = (safe_value(0) { event.x } - $game_player.x).abs +
                 (safe_value(0) { event.y } - $game_player.y).abs
      matches.push([distance, event])
    end
    matches.sort_by! { |entry| entry[0] }
    return matches.length > 0 ? matches[0][1] : nil
  rescue Exception
    return nil
  end

  def self.campaign_ball_restock_move_to_event(event, label)
    return false if !event || !$game_player
    event_id = safe_value(nil) { event.id }

    if campaign_adjacent_to_event?(event)
      @campaign_ball_restock_event_id = nil
      @campaign_ball_restock_path = []
      event.start
      append_action_log(
        "BALL_RESTOCK",
        "started #{label} event #{event_id} at #{safe_value("?") { event.x }},#{safe_value("?") { event.y }}"
      )
      return true
    end

    if @campaign_ball_restock_event_id != event_id ||
       !@campaign_ball_restock_path ||
       @campaign_ball_restock_path.length == 0
      @campaign_ball_restock_event_id = event_id
      @campaign_ball_restock_path = campaign_plan_adjacent_to_event(event) || []
      append_action_log(
        "BALL_RESTOCK",
        "#{label} event #{event_id} | path #{@campaign_ball_restock_path.length}"
      )
    end

    return false if @campaign_ball_restock_path.length == 0
    direction = @campaign_ball_restock_path[0]
    if navigation_move(direction)
      @campaign_ball_restock_path.shift
      return true
    end
    @campaign_ball_restock_path = []
    return false
  rescue Exception => e
    append_action_log("ERROR", "ball restock event path: #{e.class}: #{e.message}")
    return false
  end

  def self.campaign_ball_restock_effective_stock(stock)
    ret = []
    safe_value([]) { stock }.each do |raw|
      item_id = safe_value(nil) { GameData::Item.get(raw).id }
      ret.push(item_id) if item_id
    end
    return ret.uniq
  rescue Exception
    return []
  end

  def self.campaign_execute_ball_purchase(stock)
    return false if !campaign_ball_restock_waiting_for_shop?
    return false if !$Trainer || !$PokemonBag

    stock = campaign_ball_restock_effective_stock(stock)
    adapter = PokemonMartAdapter.new

    candidates = []
    campaign_ball_ids.each do |item_id|
      next if !stock.include?(item_id)
      item = safe_value(nil) { GameData::Item.get(item_id) }
      next if !item || !safe_value(false) { item.is_poke_ball? }
      price = safe_value(0) { adapter.getPrice(item_id) }.to_i
      next if price <= 0
      # Prefer ordinary Poké Balls when available; otherwise use the cheapest
      # auto-capture-compatible ball this clerk actually sells.
      preference = (item_id == :POKEBALL) ? 0 : 1
      candidates.push([preference, price, item_id])
    end

    if candidates.length == 0
      event_id = safe_value(nil) { campaign_current_interpreter_event_id }
      @campaign_ball_restock_tried_shop_events ||= {}
      @campaign_ball_restock_tried_shop_events[event_id] = true if event_id
      @campaign_ball_restock_last_result = "clerk_has_no_usable_capture_ball"
      append_action_log(
        "BALL_RESTOCK",
        "clerk event #{event_id || "?"} has no auto-capture-compatible ball; trying another clerk"
      )
      return true
    end

    candidates.sort_by! { |entry| [entry[0], entry[1], entry[2].to_s] }
    price = candidates[0][1]
    item_id = candidates[0][2]
    current = campaign_ball_count
    desired = [CAMPAIGN_BALL_RESTOCK_TARGET - current, 0].max
    money = safe_value(0) { $Trainer.money }.to_i

    normal_budget = [money - CAMPAIGN_BALL_RESTOCK_CASH_RESERVE, 0].max
    affordable = normal_budget / price

    if current <= 0 && affordable < CAMPAIGN_BALL_RESTOCK_EMERGENCY_TARGET
      emergency_affordable = money / price
      emergency_qty = [
        emergency_affordable,
        CAMPAIGN_BALL_RESTOCK_EMERGENCY_TARGET
      ].min
      affordable = emergency_qty if emergency_qty > affordable
    end

    quantity = [desired, affordable].min
    if quantity <= 0
      @campaign_ball_restock_blocked_money = money
      @campaign_ball_restock_last_result = "insufficient_money"
      @campaign_ball_restock_phase = :exit
      append_action_log(
        "BALL_RESTOCK",
        "cannot afford #{GameData::Item.get(item_id).name} | price $#{price} | " +
        "money $#{money} | reserve $#{CAMPAIGN_BALL_RESTOCK_CASH_RESERVE}"
      )
      return true
    end

    added = 0
    quantity.times do
      break if !safe_value(false) { $PokemonBag.pbStoreItem(item_id) }
      added += 1
    end

    if added <= 0
      @campaign_ball_restock_last_result = "bag_could_not_store_ball"
      @campaign_ball_restock_phase = :exit
      append_action_log("BALL_RESTOCK", "Bag could not store #{GameData::Item.get(item_id).name}")
      return true
    end

    spent = added * price
    $Trainer.money = [money - spent, 0].max

    bonus = false
    if added >= 10 && safe_value(false) { GameData::Item.exists?(:PREMIERBALL) }
      bonus = safe_value(false) { $PokemonBag.pbStoreItem(:PREMIERBALL) }
    end

    @campaign_ball_restock_last_result = "success"
    @campaign_ball_restock_last_item = item_id
    @campaign_ball_restock_last_quantity = added
    @campaign_ball_restock_last_spent = spent
    @campaign_ball_restock_blocked_money = nil
    @campaign_ball_restock_phase = :exit

    append_action_log(
      "BALL_RESTOCK",
      "bought #{added}x #{GameData::Item.get(item_id).name} for $#{spent} | " +
      "balls #{current} -> #{campaign_ball_count}" +
      (bonus ? " | +1 Premier Ball bonus" : "") +
      " | money $#{money} -> $#{safe_value(0) { $Trainer.money }}"
    )
    safe_value(nil) { pbSEPlay("Mart buy item") }
    return true
  rescue Exception => e
    append_action_log("ERROR", "auto Mart purchase: #{e.class}: #{e.message}")
    @campaign_ball_restock_last_result = "purchase_error"
    @campaign_ball_restock_phase = :exit
    return true
  end

  def self.campaign_ball_restock_begin_return
    return false if !@campaign_ball_restock_resume_map
    @campaign_ball_restock_event_id = nil
    @campaign_ball_restock_path = []

    if $game_map && $game_map.map_id == @campaign_ball_restock_resume_map
      return campaign_ball_restock_finish
    end

    if campaign_begin_route(
         @campaign_ball_restock_resume_map,
         "return after Poké Ball restock"
       )
      @campaign_ball_restock_phase = :return
      return true
    end

    append_action_log(
      "BALL_RESTOCK",
      "purchase finished but return map #{@campaign_ball_restock_resume_map} is unreachable"
    )
    navigation_stop("ball_restock_return_unreachable")
    @campaign_ball_restock_active = false
    return false
  rescue Exception => e
    append_action_log("ERROR", "ball restock begin return: #{e.class}: #{e.message}")
    return false
  end

  def self.campaign_ball_restock_finish
    append_action_log(
      "BALL_RESTOCK",
      "restock complete | #{campaign_ball_count} usable balls | " +
      "result #{@campaign_ball_restock_last_result || "unknown"} | resuming campaign"
    )
    @campaign_ball_restock_active = false
    @campaign_ball_restock_phase = nil
    @campaign_ball_restock_resume_map = nil
    @campaign_ball_restock_mart_map = nil
    @campaign_ball_restock_event_id = nil
    @campaign_ball_restock_path = []
    @campaign_ball_restock_tried_shop_events = {}
    @campaign_ball_restock_next_retry_battle =
      safe_value(0) { @nav_wild_battles || 0 } +
      (campaign_ball_count <= CAMPAIGN_BALL_RESTOCK_TRIGGER ? 5 : 0)
    @campaign_phase = nil
    campaign_write_status("ball_restock_complete") if respond_to?(:campaign_write_status)
    return true
  rescue Exception
    @campaign_ball_restock_active = false
    @campaign_phase = nil
    return true
  end

  def self.campaign_ball_restock_update
    return false if !campaign_ball_restock_active?
    return false if !navigation_can_update?

    case @campaign_ball_restock_phase
    when :travel
      result = campaign_route_update
      if result == :arrived
        @campaign_ball_restock_phase = :enter
        @campaign_ball_restock_event_id = nil
        @campaign_ball_restock_path = []
      elsif result == :unreachable
        navigation_stop("ball_restock_mart_route_blocked")
        @campaign_ball_restock_active = false
      end
      return true

    when :enter
      mart_interior = safe_value(357) {
        Object.const_defined?(:POKEMART_MAP_ID) ? Object.const_get(:POKEMART_MAP_ID) : 357
      }
      if $game_map.map_id == mart_interior
        @campaign_ball_restock_phase = :shop
        @campaign_ball_restock_event_id = nil
        @campaign_ball_restock_path = []
        @campaign_ball_restock_tried_shop_events = {}
        return true
      end

      entrance = campaign_find_current_event_by_script("enter_pokemart")
      if !entrance
        append_action_log("BALL_RESTOCK", "Mart entrance event not found on map #{$game_map.map_id}")
        @campaign_ball_restock_next_retry_battle =
          safe_value(0) { @nav_wild_battles || 0 } + 5
        @campaign_ball_restock_active = false
        @campaign_phase = nil
        return true
      end
      campaign_ball_restock_move_to_event(entrance, "Mart entrance")
      return true

    when :shop
      clerk = campaign_find_current_event_by_script(
        "pbpokemonmart",
        @campaign_ball_restock_tried_shop_events || {}
      )
      if !clerk
        append_action_log(
          "BALL_RESTOCK",
          "no remaining Mart clerk with usable Poké Ball stock"
        )
        @campaign_ball_restock_last_result = "no_mart_ball_stock"
        @campaign_ball_restock_phase = :exit
        return true
      end
      campaign_ball_restock_move_to_event(clerk, "Mart clerk")
      return true

    when :exit
      mart_interior = safe_value(357) {
        Object.const_defined?(:POKEMART_MAP_ID) ? Object.const_get(:POKEMART_MAP_ID) : 357
      }
      if $game_map.map_id != mart_interior
        return campaign_ball_restock_begin_return
      end

      exit_event = campaign_find_current_event_by_script("exit_pokemart")
      if exit_event
        campaign_ball_restock_move_to_event(exit_event, "Mart exit")
        return true
      end

      # Defensive fallback for a custom/changed common Mart map. Use Infinite
      # Fusion's own exit helper rather than teleporting with bot-owned coords.
      if Object.private_method_defined?(:exit_pokemart)
        append_action_log("BALL_RESTOCK", "Mart exit event not found; using game's exit_pokemart helper")
        Object.new.send(:exit_pokemart)
        return true
      end

      navigation_stop("ball_restock_exit_not_found")
      @campaign_ball_restock_active = false
      return true

    when :return
      result = campaign_route_update
      if result == :arrived
        campaign_ball_restock_finish
      elsif result == :unreachable
        navigation_stop("ball_restock_return_blocked")
        @campaign_ball_restock_active = false
      end
      return true
    end

    return false
  rescue Exception => e
    append_action_log("ERROR", "ball restock update: #{e.class}: #{e.message}")
    navigation_stop("ball_restock_error")
    @campaign_ball_restock_active = false
    return true
  end

  class << self
    unless method_defined?(:pifbot_ball_restock_original_navigation_start)
      alias_method :pifbot_ball_restock_original_navigation_start, :navigation_start
    end

    def navigation_start
      result = pifbot_ball_restock_original_navigation_start
      if result
        # Preserve long-lived diagnostics from the last run, but clear all
        # active routing state for a fresh F10 campaign.
        @campaign_ball_restock_active = false
        @campaign_ball_restock_phase = nil
        @campaign_ball_restock_resume_map = nil
        @campaign_ball_restock_mart_map = nil
        @campaign_ball_restock_event_id = nil
        @campaign_ball_restock_path = []
        @campaign_ball_restock_tried_shop_events = {}
        @campaign_ball_restock_next_retry_battle = 0
      end
      return result
    end

    unless method_defined?(:pifbot_ball_restock_original_navigation_update)
      alias_method :pifbot_ball_restock_original_navigation_update, :navigation_update
    end

    def navigation_update
      if campaign_active? &&
         !(respond_to?(:center_return_active?) && center_return_active?) &&
         navigation_can_update?
        # Healing/survival takes precedence. If the party genuinely needs a
        # Center, let the existing campaign update start that trip first.
        needs_heal = respond_to?(:navigation_low_hp_pokemon) &&
                     safe_value(nil) { navigation_low_hp_pokemon }
        if !needs_heal
          if campaign_ball_restock_active?
            campaign_ball_restock_update
            return
          elsif campaign_ball_restock_needed?
            if campaign_ball_restock_begin
              return
            end
          end
        end
      end

      return pifbot_ball_restock_original_navigation_update
    end
  end
end

# Intercept only the real Poké Mart call reached by the autonomous restock
# state. Manual shopping and every non-restock Mart interaction are unchanged.
class Object
  if private_method_defined?(:pbPokemonMart) &&
     !private_method_defined?(:pifbot_ball_restock_original_pbPokemonMart)
    alias_method :pifbot_ball_restock_original_pbPokemonMart, :pbPokemonMart

    def pbPokemonMart(stock, speech_welcome = nil, cantsell = false,
                      speech_bye = nil, speech_what_else = nil)
      if PIFBot.campaign_ball_restock_waiting_for_shop?
        effective_stock = stock.is_a?(Array) ? stock.dup : []
        random_general = begin
          $game_switches && $game_switches[SWITCH_RANDOM_ITEMS_GENERAL]
        rescue Exception
          false
        end
        random_shops = begin
          $game_switches && $game_switches[SWITCH_RANDOM_SHOP_ITEMS]
        rescue Exception
          false
        end

        if random_general && random_shops &&
           respond_to?(:replaceShopStockWithRandomized, true)
          effective_stock = replaceShopStockWithRandomized(effective_stock)
        end

        if PIFBot.campaign_execute_ball_purchase(effective_stock)
          begin
            $game_temp.clear_mart_prices if $game_temp
          rescue Exception
          end
          return
        end
      end

      return pifbot_ball_restock_original_pbPokemonMart(
        stock, speech_welcome, cantsell, speech_bye, speech_what_else
      )
    end

    private :pbPokemonMart
  end
end
