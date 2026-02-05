# frozen_string_literal: true

module RbrunCli
  class CLI < Thor
    def self.exit_on_failure? = true

    desc "release SUBCOMMAND", "Manage production/staging releases"
    subcommand "release", Release

    desc "sandbox SUBCOMMAND", "Manage development sandboxes"
    subcommand "sandbox", Sandbox
  end
end
