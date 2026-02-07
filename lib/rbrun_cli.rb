# frozen_string_literal: true

require "zeitwerk"

module RbrunCli
  class << self
    def loader
      @loader ||= Zeitwerk::Loader.for_gem
    end
  end
end

# External dependencies
require "rbrun_core"
require "thor"

# Setup and eager load
RbrunCli.loader.setup
RbrunCli.loader.eager_load
