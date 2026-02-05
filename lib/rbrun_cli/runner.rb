# frozen_string_literal: true

module RbrunCli
  class Runner
    attr_reader :formatter

    def initialize(config_path:, folder: nil, formatter: nil)
      @config_path = config_path
      @folder = folder
      @formatter = formatter || Formatter.new
      @absolute_config_path = if @folder
        File.expand_path(@config_path, @folder)
      else
        File.expand_path(@config_path)
      end
    end

    def build_context(target:, slug: nil)
      in_folder do
        config = load_and_validate_config
        branch = detect_branch
        RbrunCore::Context.new(config:, target:, slug:, branch:)
      end
    end

    def execute(command_class, target:, slug: nil)
      ctx = build_context(target:, slug:)

      command = command_class.new(
        ctx,
        on_log: ->(category, message) { @formatter.log(category, message) },
        on_state_change: ->(state) { @formatter.state_change(state) }
      )
      command.run

      @formatter.summary(ctx)
      ctx
    end

    def load_config
      in_folder { load_and_validate_config }
    end

    def find_server(config, name = nil)
      compute_client = config.compute_config.client
      prefix = build_prefix(config)

      if name
        server_name = "#{prefix}-#{name}"
      else
        server_name = prefix
      end

      servers = compute_client.list_servers
      server = servers.find { |s| s.name == server_name } ||
               servers.find { |s| s.name.start_with?(prefix) }

      raise RbrunCore::Error, "No server found matching #{server_name}" unless server

      server
    end

    def build_operational_context(target: nil, slug: nil, server: nil)
      config = load_config
      found_server = find_server(config, server)

      ssh_keys = config.compute_config.read_ssh_keys
      target ||= config.target || :production

      ctx = RbrunCore::Context.new(config:, target:, slug:)
      ctx.server_ip = found_server.public_ipv4
      ctx.ssh_private_key = ssh_keys[:private_key]
      ctx.ssh_public_key = ssh_keys[:public_key]
      ctx
    end

    def build_kubectl(ctx)
      RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
    end

    private

      def in_folder(&block)
        if @folder
          Dir.chdir(@folder, &block)
        else
          yield
        end
      end

      def load_and_validate_config
        config = RbrunCore::Config::Loader.load(@absolute_config_path)
        config.validate!
        config
      end

      def detect_branch
        RbrunCore::LocalGit.current_branch
      rescue RbrunCore::Error
        nil
      end

      def build_prefix(config)
        target = (config.target || :production).to_sym
        case target
        when :sandbox
          # Sandbox prefix requires a slug — handled at call site
          raise RbrunCore::Error, "Cannot determine prefix for sandbox without slug"
        else
          RbrunCore::Naming.release_prefix(config.git_config.app_name, target)
        end
      end
  end
end
