# frozen_string_literal: true

require_relative "lib/rbrun_cli/version"

Gem::Specification.new do |s|
  s.name          = "rbrun"
  s.version       = RbrunCli::VERSION
  s.authors       = [ "rbrun" ]
  s.summary       = "CLI for rbrun cloud deployments"
  s.license       = "MIT"

  s.required_ruby_version = ">= 3.2"

  s.files       = Dir["lib/**/*", "bin/*"]
  s.bindir      = "bin"
  s.executables = [ "rbrun" ]

  s.add_dependency "rbrun-core", "~> 0.1"
  s.add_dependency "thor", "~> 1.0"
  s.add_dependency "tty-spinner", "~> 0.9"
  s.add_dependency "zeitwerk", "~> 2.6"
  s.metadata["rubygems_mfa_required"] = "true"
end
