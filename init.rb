require "#{File.dirname(__FILE__)}/workflow"

class ActiveRecord::Base
  include Workflow
end
