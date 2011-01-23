# rrschedule (Round Robin Schedule generator)
# Auhtor: François Lamontagne
############################################################################################################################
module RRSchedule
  class Schedule
    attr_reader :teams, :nteams, :rounds, :gamedays                
    attr_accessor :rules, :cycles, :start_date, :exclude_dates,:shuffle_initial_order


    def initialize(params={})
      @gamedays = []
      self.teams = params[:teams] if params[:teams]
      self.cycles = params[:cycles] || 1
      self.shuffle_initial_order = params[:shuffle_initial_order].nil? ? true : params[:shuffle_initial_order]
      self.exclude_dates = params[:exclude_dates] || []      
      self.start_date = params[:start_date] || Date.today
      self.rules = params[:rules] || []
      self
    end

    #Array of teams that will compete against each other. You can pass it any kind of object
    def teams=(arr)
      @teams = Marshal.load(Marshal.dump(arr)) #deep clone

      #nteams (stands for normalized teams. We don't modify the original array anymore).
      @nteams = Marshal.load(Marshal.dump(@teams)) #deep clone

      #If teams aren't grouped, we create a single group and put all teams in it. That way
      #we won't have to check if this is a grouped round-robin or not every time.
      @nteams = [@nteams] unless @nteams.first.respond_to?(:to_ary)

      @nteams.each_with_index do |team_group,i|
        raise ":dummy is a reserved team name. Please use something else" if team_group.member?(:dummy)
        raise "at least 2 teams are required" if team_group.size == 1
        raise "teams have to be unique" if team_group.uniq.size < team_group.size
        @nteams[i] << :dummy if team_group.size.odd?
      end
    end

    #This will generate the schedule based on the various parameters
    def generate(params={})
      flat_schedule = generate_flat_schedule
      @nteams.each_with_index do |teams,division_id|
        current_cycle = current_round = 0
        teams = teams.sort_by{rand} if @shuffle_initial_order
        begin
          t = teams.clone
          games = []

          #process one round
          while !t.empty? do
            team_a = t.shift
            team_b = t.reverse!.shift
            t.reverse!

            matchup = {:team_a => team_a, :team_b => team_b}
            games << matchup
          end
          ####
          current_round += 1

          teams = teams.insert(1,teams.delete_at(teams.size-1))
          
          #add the round in memory
          @rounds ||= []
          @rounds[division_id] ||= []
          @rounds[division_id] << Round.new(
            :round => current_round,
            :flight => division_id,
            :games => games.collect { |g|
              Game.new(
                :team_a => g[:team_a],
                :team_b => g[:team_b]
              )              
            }
          )
          ####

          #have we completed a full round-robin for the current division?
          if current_round == teams.size-1            
            current_cycle += 1
            current_round = 0 if current_cycle < self.cycles
            teams = teams.sort_by{rand} if @shuffle_initial_order && current_cycle <= self.cycles
          end
        
        end until current_round == teams.size-1 && current_cycle==self.cycles
      end   
      slice(@rounds,flat_schedule)
      self
    end

    #human readable schedule
    def to_s
      res = ""
      res << "#{self.gamedays.size.to_s} gamedays\n"
      self.gamedays.each do |gd|
        res << gd.date.strftime("%Y-%m-%d") + "\n"
        res << "==========\n"
        gd.games.each do |g|
          res << "#{g.ta.to_s} VS #{g.tb.to_s} on playing surface #{g.ps} at #{g.gt.strftime("%I:%M %p")}\n"
        end
        res << "\n"
      end
      res
    end

    #returns true if the generated schedule is a valid round-robin (for testing purpose)
    def round_robin?
      #each round-robin round should contains n-1 games where n is the nbr of teams (:dummy included if odd)
      return false if self.rounds.size != (@teams.size*self.cycles)-self.cycles

      #check if each team plays the same number of games against each other
      self.teams.each do |t1|
        self.teams.reject{|t| t == t1}.each do |t2|
          return false unless self.face_to_face(t1,t2).size == self.cycles || [t1,t2].include?(:dummy)
        end
      end
      return true
    end

    private
    def generate_flat_schedule
      rules_copy = Marshal.load(Marshal.dump(rules)).sort #deep clone
      
      rule_ctr = 0
      #detect the first rule
      cur_rule  = rules_copy.select{|r| r.wday >= self.start_date.wday}.first
      cur_rule = rules_copy.first if cur_rule.nil?
      cur_rule_index = rules_copy.index(cur_rule)
      cur_date = next_game_date(self.start_date,cur_rule.wday)
      flat_schedule = []
      nbr_of_games = max_games_per_day = 0
      day_game_ctr = 0
      
      @nteams.each do |flight|
        nbr_of_games += self.cycles * (flight.include?(:dummy) ? ((flight.size-1)/2.0)*(flight.size-2) : (flight.size/2)*(flight.size-1))
        max_games_per_day += (flight.include?(:dummy) ? (flight.size-2)/2.0 : (flight.size-1)/2.0).ceil
      end

      while nbr_of_games > 0 do
        cur_rule.gt.each do |gt|
          cur_rule.ps.each do |ps|          
            if day_game_ctr <= max_games_per_day-1
              flat_game = {:gamedate => cur_date, :gt => gt, :ps => ps}
              flat_schedule << flat_game
              nbr_of_games -= 1
              day_game_ctr+=1
            end
          end                
        end
        cur_rule_index = cur_rule_index == rules_copy.size-1 ? 0 : cur_rule_index + 1
        last_rule = cur_rule
        cur_rule = rules_copy[cur_rule_index]
                
        last_date = cur_date

        if cur_rule.wday != last_rule.wday
          cur_date+=1
          cur_date= next_game_date(cur_date,cur_rule.wday)
        end
        
        day_game_ctr = 0 if cur_date != last_date
      end      
      flat_schedule
    end
    
    #Slice games according to available playing surfaces  and game times
    def slice(rounds,flat_schedule)
      rounds_copy =  Marshal.load(Marshal.dump(rounds)) #deep clone
      nbr_of_flights = rounds_copy.size
      cur_flight = 0

      i=0
      while !rounds_copy.empty? do
        cur_round = rounds_copy[cur_flight].shift

        #process the next round in the current flight
        if cur_round          
          cur_round.games.each do |game|
            unless [game.team_a,game.team_b].include?(:dummy)            
              flat_schedule[i][:team_a] = game.team_a
              flat_schedule[i][:team_b] = game.team_b
              i+=1
            end
          end
        end
        
        
        empty_flights = rounds_copy.select {|flight| flight.empty?}
        rounds_copy=[] if empty_flights.size == nbr_of_flights     
        
        if cur_flight == nbr_of_flights-1
          cur_flight = 0
        else
          cur_flight += 1          
        end        
      end
            
      s=flat_schedule.group_by{|fs| fs[:gamedate]}.sort

      s.each do |gamedate,gms|      
        games = []
        gms.each do |gm|    
          games << Game.new(
            :team_a => gm[:team_a],
            :team_b => gm[:team_b],
            :playing_surface => gm[:ps],
            :game_time => gm [:gt] 
          )
        end
        self.gamedays << Gameday.new(:date => gamedate, :games => games)
      end      
      self.gamedays.each { |gd| gd.games.reject! {|g| g.team_a.nil?}}
    end

    #get the next gameday
    def next_game_date(dt,wday)
      dt += 1 until wday == dt.wday && !self.exclude_dates.include?(dt)
      dt
    end
  end

  class Gameday
    attr_accessor :date, :games

    def initialize(params)
      self.date = params[:date]
      self.games = params[:games] || []
    end

  end

  class Rule
    attr_accessor :wday, :gt, :ps


    def initialize(params)
      self.wday = params[:wday]
      self.gt = params[:gt]
      self.ps = params[:ps]
    end

    def wday=(wday)
      @wday = wday ? wday : 1
      raise "Rule#wday must be between 0 and 6" unless (0..6).include?(@wday)
    end

    #Array of available playing surfaces. You can pass it any kind of object
    def ps=(ps)
      @ps = Array(ps).empty? ? ["Field #1", "Field #2"] : Array(ps)
    end

    #Array of game times where games are played. Must be valid DateTime objects in the string form
    def gt=(gt)
      @gt =  Array(gt).empty? ? ["7:00 PM"] : Array(gt)
      @gt.collect! do |gt|
        begin
          DateTime.parse(gt)
        rescue
          raise "game times must be valid time representations in the string form (e.g. 3:00 PM, 11:00 AM, 18:20, etc)"
        end
      end
    end

    def <=>(other)
      self.wday == other.wday ?
      DateTime.parse(self.gt.first.to_s) <=> DateTime.parse(other.gt.first.to_s) :
      self.wday <=> other.wday
    end
  end

  class Game
    attr_accessor :team_a, :team_b, :playing_surface, :game_time, :game_date
    alias :ta :team_a
    alias :tb :team_b
    alias :ps :playing_surface
    alias :gt :game_time
    alias :gd :game_date

    def initialize(params={})
      self.team_a = params[:team_a]
      self.team_b = params[:team_b]
      self.playing_surface = params[:playing_surface]
      self.game_time = params[:game_time]
      self.game_date = params[:game_date]
    end
  end

  class Round
    attr_accessor :round, :games,:flight

    def initialize(params={})
      self.round = params[:round]
      self.flight = params[:flight]
      self.games = params[:games] || []
    end
    
    def to_s
      str = "FLIGHT #{@flight.to_s} - Round ##{@round.to_s}\n"
      str += "=====================\n"
      
      self.games.each do |g|
        if [g.team_a,g.team_b].include?(:dummy)
          str+= g.team_a == :dummy ? g.team_b.to_s : g.team_a.to_s + " has a BYE\n"
        else
          str += g.team_a.to_s + " Vs " + g.team_b.to_s + "\n"
        end
      end
      str += "\n"
    end
  end
end
