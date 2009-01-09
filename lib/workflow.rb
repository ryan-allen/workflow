%w(rubygems active_support).each { |f| require f }

module Workflow
  @@logger = nil
  def self.logger=(obj) @@logger = obj; end
  def logger=(obj) @@logger = obj; end
  def self.logger() @@logger; end
  def logger() @@logger; end

  WORKFLOW_DEFAULT_LOGGER = Logger.new(STDERR)
  WORKFLOW_DEFAULT_LOGGER.level = Logger::DEBUG

  @@specifications = {}

  class << self

    def specify(name = :default, meta = {:meta => {}}, &specification)
      if @@specifications[name]
        @@specifications[name].blat(meta[:meta], &specification)
      else
        @@specifications[name] = Specification.new(meta[:meta], &specification)
      end
    end

    def reset!
      @@specifications = {}
    end

  private

    def find_spec_for(klass) # it could either be a symbol, or a class, man, urgh.
      target = klass
      while @@specifications[target].nil? and target != Object
        target = target.superclass
      end
      @@specifications[target]
    end

  public

    def new(name = :default, args = {})
      find_spec_for(name).to_instance(args[:reconstitute_at])
    end

    def reconstitute(reconstitute_at = nil, name = :default)
      find_spec_for(name).to_instance(reconstitute_at)
    end

    def active_record?(receiver)
      receiver.to_s == 'ActiveRecord::Base'
    end

    def append_features(receiver)
      if active_record?(receiver)
        receiver.instance_eval do
          def workflow(&specification)
            Workflow.logger.debug "Adding Workflow to ActiveRecord object #{self}"
            Workflow.specify(self, &specification)

            class_eval do
              attr_accessor :workflow
              alias_method :initialize_before_workflow, :initialize

              def initialize(attributes = nil)
                Workflow.logger.debug "calling Workflow's redefined initializer"
                initialize_before_workflow(attributes)
                @workflow = Workflow.new(self.class)
                @workflow.bind_to(self)
                puts "after initialize the workflow state is #{self.workflow_state}"
                self.workflow_state = Workflow.new(self.class).state.to_s if workflow_state.nil?
                puts "1 within initialize #{self.workflow_state.inspect}"
              end

              def after_find
                puts "1 within after_find #{self.workflow_state.inspect}"
                puts "class of #{self.workflow_state.class}"
                Workflow.logger.debug "after find called"
                @workflow = if workflow_state.nil?
                              Workflow.new(self.class)
                            else
                              Workflow.reconstitute(workflow_state.to_sym, self.class)
                            end
                puts "1 within after_find #{self.workflow_state}"
                @workflow.bind_to(self)
                puts "2 within after_find #{self.workflow_state}"
              end
            end
          end
        end
      else
        Workflow.logger.debug "Adding Workflow to object #{self}"

        receiver.instance_eval do
          def workflow(&specification)
            Workflow.specify(self, &specification)
          end
        end

        # anything else gets this style of integration
        receiver.class_eval do
          alias_method :initialize_before_workflow, :initialize
          attr_reader :workflow

          def initialize(*args, &block)
            initialize_before_workflow(*args, &block)
            @workflow = Workflow.new(self.class)
            @workflow.bind_to(self)
          end
        end
      end
    end
  end

  class Specification

    attr_accessor :states, :meta, :on_transition

    def initialize(meta = {}, &specification)
      @states = []
      @meta = meta
      instance_eval(&specification)
    end

    def to_instance(reconstitute_at = nil)
      Instance.new(states, @on_transition, @meta, reconstitute_at)
    end

    def blat(meta = {}, &specification)
      instance_eval(&specification)
    end

  private

    def state(name, meta = {:meta => {}}, &events_and_etc)
      puts "**** This one"
      Workflow.logger.debug "Defining state(#{name}) for #{self}"
      # meta[:meta] to keep the API consistent..., gah
      self.states << State.new(name, meta[:meta])
      instance_eval(&events_and_etc) if events_and_etc
    end

    def on_transition(&proc)
      @on_transition = proc
    end

    def event(name, args = {}, &action)
      scoped_state.add_event Event.new(name, args[:transitions_to], (args[:meta] or {}), &action)
    end

    def on_entry(&proc)
      scoped_state.on_entry = proc
    end

    def on_exit(&proc)
      scoped_state.on_exit = proc
    end

    def scoped_state
      states.last
    end

  end

  class Instance

    class TransitionHalted < Exception
      attr_reader :halted_because

      def initialize(msg = nil)
        @halted_because = msg
        super msg
      end
    end

    attr_accessor :states, :meta, :current_state, :on_transition, :context

    def initialize(states, on_transition, meta = {}, reconstitute_at = nil)
      Workflow.logger.debug "Creating workflow instance"
      @states, @on_transition, @meta = states, on_transition, meta
      puts "in the instance init the context is #{context}, #{@context}"
      if reconstitute_at.nil?
        transition(nil, states.first, nil)
      else
        puts "Instance.init = start"
        self.current_state = states(reconstitute_at)
        puts "Instance.init = end"
      end
    end

    def current_state=(var)
#      puts "setting state to #{var}"
#      puts "1 self is #{self}"
#      puts "2 self.context is #{self.context}"
#      puts "3 wfs is #{self.context.workflow_state}" if self.context
      @current_state=var
    end

    def state(fetch = nil)
      puts "calling state(#{fetch.inspect})"
      if fetch
        states(fetch)
      else
#        puts "what is the current state #{current_state.inspect}"
#        puts "current state.name is #{current_state.name}"
        current_state.name
      end
    end

    def states(name = nil)
      if name
        @states.detect { |s| s.name == name }
      else
        @states.collect { |s| s.name }
      end
    end

    def available_events
      self.current_state.events
    end

    def method_missing(name, *args)
#      puts "starting method missing"
      if current_state.events(name)
        process_event!(name, *args)
      elsif name.to_s[-1].chr == '?' and states(name.to_s[0..-2].to_sym)
        current_state == states(name.to_s[0..-2].to_sym)
      else
        super
      end
    end

    def bind_to(another_context)
      self.context = another_context
      puts "setting #{self}.context to #{another_context}"
      patch_context(another_context) if another_context != self
    end

    def halted?
      @halted
    end

    def halted_because
      @halted_because
    end

  private

    def patch_context(context)
      Workflow.logger.debug "patching context of #{context.inspect} to include @workflow"
#      puts "*1*** patch_context is patching: #{self} -> #{self.id}"
#      puts "*2*** patch_context state is: #{self.state}"
      context.instance_variable_set("@workflow", self)
      context.instance_eval do
        alias :method_missing_before_workflow :method_missing
        #
        # PROBLEM: method_missing in on_transition events
        # when bound to other context is raising confusing
        # error messages, so need to rethink how this is
        # implemented - i.e. should we just check that an
        # event exists rather than send ANY message to the
        # machine? so like:
        #
        # if @workflow.state.events(ref_to_sym)
        #   execute
        # else
        #   super ?
        # end
        #

        alias :respond_to_before_workflow :respond_to?

        # rails 2.2 is stricter about method_missing, now we need respond_to
        def respond_to?(method, include_private=false)
          if potential_methods.include?(method.to_sym)
            return true
          else
            respond_to_before_workflow(method, include_private)
          end
        end

        def method_missing(method, *args)
          Workflow.logger.debug "#{self} method missing: #{method}(#{args.inspect})"
          # we create an array of valid method names that can be delegated to the workflow,
          # otherwise methods are sent onwards down the chain.
          # this solves issues with catching a NoMethodError when it means something OTHER than a method missing in the workflow instance
          # for example, perhaps a NoMethodError is raised in an on_entry block or similar.
          # "potential_methods" should probably be calculated elsewhere, not per invocation
          if potential_methods.include?(method.to_sym)
            puts "MM: sending #{method} to @workflow"
            result = @workflow.send(method, *args)
            puts "MM: result was #{result}"
            result
          else
            puts "MM: calling workflow's method missing"
            method_missing_before_workflow(method, *args)
          end
        end

        def potential_methods
          [ :available_events, :current_state, :halt!, :halt, :halted?, :halted_because, :override_state_with, :state, :states, :transition ] +
            @workflow.available_events +
            (@workflow.states.collect {|s| "#{s}?".to_sym})
        end
      end
    end

    def process_event!(name, *args)
      event = current_state.events(name)
      @halted_because = nil
      @halted = false
      @raise_exception_on_halt = false
      # i don't think we've tested that the return value is
      # what the action returns... so yeah, test it, at some point.
      return_value = run_action(event.action, *args)
      if @halted
        if @raise_exception_on_halt
          raise TransitionHalted.new(@halted_because)
        else
          false
        end
      else
        run_on_transition(current_state, states(event.transitions_to), name, *args)
        transition(current_state, states(event.transitions_to), name, *args)
        return_value
      end
    end

    def halt(reason = nil)
      @halted_because = reason
      @halted = true
      @raise_exception_on_halt = false
    end

    def halt!(reason = nil)
      @halted_because = reason
      @halted = true
      @raise_exception_on_halt = true
    end

    # TODO: There is identical code up int he Workflow module - remove the duplication
    def active_record?(receiver)
      if receiver.nil?
        false
      else
        puts "ancestors #{receiver.class.ancestors.inspect}"
        receiver.class.ancestors.include?(ActiveRecord::Base)
      end
    end

    def transition(from, to, name, *args)
      run_on_exit(from, to, name, *args)
      self.current_state = to
#      if @context
#        puts "TRANSITION: wfs was #{@context.workflow_state}"
#      else
#        puts "TRANSITION: CONTEXT NOT SET"
#      end
      puts "context is #{@context.inspect}"
      puts "checking to see if we need to update the workflow state #{active_record?(@context)}"
      @context.workflow_state = to.name.to_s if active_record?(@context)   # may not have been defined when bind_to is called
#      puts "TRANSITION: wfs is #{@context.workflow_state}" if @context
#      puts "***** context is #{@context}"
#      puts "***** current_state is #{current_state}"
#      puts "***** workflow state is #{@context.workflow_state} and current state is #{to.name}" if @context
      run_on_entry(to, from, name, *args)
    end

    def run_on_transition(from, to, event, *args)
      puts "YYY context is #{context}"
      puts "YYY @context is #{@context}"
      puts "YYY self is #{self}"
      self.instance_exec(from.name, to.name, event, *args, &on_transition) if on_transition
    end

    def run_action(action, *args)
      puts "XXX context is #{context}"
      puts "XXX @context is #{@context}"
      puts "XXX self is #{self}"
      self.instance_exec(*args, &action) if action
    end

    def run_on_entry(state, prior_state, triggering_event, *args)
      if state.on_entry
        self.instance_exec(prior_state.name, triggering_event, *args, &state.on_entry)
      end
    end

    def run_on_exit(state, new_state, triggering_event, *args)
      if state and state.on_exit
        self.instance_exec(new_state.name, triggering_event, *args, &state.on_exit)
      end
    end

  end

  class State

    attr_accessor :name, :events, :meta, :on_entry, :on_exit

    def initialize(name, meta = {})
      @name, @events, @meta = name, [], meta
    end

    def events(name = nil)
      if name
        @events.detect { |e| e.name == name }
      else
        @events.collect { |e| e.name }
      end
    end

    def add_event(event)
      @events << event
    end

  end

  class Event

    attr_accessor :name, :transitions_to, :meta, :action

    def initialize(name, transitions_to, meta = {}, &action)
      @name, @transitions_to, @meta, @action = name, transitions_to, meta, action
    end

  end

end

Workflow.logger = Workflow::WORKFLOW_DEFAULT_LOGGER
