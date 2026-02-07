# frozen_string_literal: true

module RbrunCli
  class Cli < Thor
    def self.exit_on_failure? = true

    desc "release SUBCOMMAND", "Manage production/staging releases"
    subcommand "release", Release

    desc "sandbox SUBCOMMAND", "Manage development sandboxes"
    subcommand "sandbox", Sandbox

    desc "backup SUBCOMMAND", "Manage database backups"
    subcommand "backup", Backup

    desc "resources", "List all resources across configured providers"
    option :config, type: :string, default: "rbrun.yaml", aliases: "-c"
    option :folder, type: :string, aliases: "-f"
    option :env_file, type: :string, default: ".env", aliases: "-e"
    def resources
      formatter = Formatter.new
      folder = options[:folder] || File.dirname(File.expand_path(options[:config]))
      runner = Runner.new(config_path: options[:config], folder:, env_file: options[:env_file], formatter:)
      config = runner.load_config

      compute_provider = config.compute_config.class.name.split("::").last.downcase
      compute_inventory = config.compute_config.client.inventory

      cloudflare_inventory = if config.cloudflare_configured?
        prefix = RbrunCore::Naming.release_prefix(config.git_config.app_name, config.target)
        config.cloudflare_config.client.inventory(domain: config.cloudflare_config.domain, prefix:)
      end

      formatter.resources(
        compute_provider:,
        compute_inventory:,
        cloudflare_inventory:
      )
    rescue RbrunCore::Error::Configuration => e
      formatter.error(e.message)
      exit 1
    rescue RbrunCore::Error::Standard => e
      formatter.error(e.message)
      exit 1
    end
  end
end
