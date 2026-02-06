# frozen_string_literal: true

module RbrunCli
  class Runner
    attr_reader :formatter, :logger

    def initialize(config_path:, folder: nil, env_file: nil, formatter: nil, log_file: nil)
      @config_path = config_path
      @folder = folder
      @formatter = formatter || Formatter.new
      @absolute_config_path = if @folder
        File.expand_path(@config_path, @folder)
      else
        File.expand_path(@config_path)
      end
      @logger = build_logger(log_file)
      load_env_file(env_file) if env_file
    end

    def build_context(target:, slug: nil)
      in_folder do
        config = load_and_validate_config
        branch = detect_branch
        ctx = RbrunCore::Context.new(config:, target:, slug:, branch:)
        ctx.source_folder = @folder ? File.expand_path(@folder) : nil
        ctx
      end
    end

    def execute(command_class, target:, slug: nil)
      ctx = build_context(target:, slug:)
      load_ssh_keys!(ctx)

      command = command_class.new(
        ctx,
        logger: @logger,
        on_state_change: ->(state) { @formatter.state_change(state) }
      )
      command.run

      @formatter.summary(ctx)
      @logger.close
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

      raise RbrunCore::Error::Standard, "No server found matching #{server_name}" unless server

      server
    end

    def build_operational_context(target: nil, slug: nil, server: nil)
      config = load_config
      found_server = find_server(config, server)
      target ||= config.target || :production

      ctx = RbrunCore::Context.new(config:, target:, slug:)
      ctx.server_ip = found_server.public_ipv4
      load_ssh_keys!(ctx)
      ctx
    end

    def build_kubectl(ctx)
      RbrunCore::Clients::Kubectl.new(ctx.ssh_client)
    end

    private

      def load_ssh_keys!(ctx)
        ssh_keys = ctx.config.compute_config.read_ssh_keys
        ctx.ssh_private_key = ssh_keys[:private_key]
        ctx.ssh_public_key = ssh_keys[:public_key]
      end

      def load_env_file(path)
        abs_path = if @folder
          File.expand_path(path, @folder)
        else
          File.expand_path(path)
        end
        raise RbrunCore::Error::Configuration, "Env file not found: #{abs_path}" unless File.exist?(abs_path)

        File.readlines(abs_path).each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          key, value = line.split("=", 2)
          next unless key && value

          # Strip optional quotes
          value = value.strip
          value = value[1..-2] if (value.start_with?('"') && value.end_with?('"')) ||
                                  (value.start_with?("'") && value.end_with?("'"))

          ENV[key.strip] = value
        end
      end

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
      rescue RbrunCore::Error::Standard
        nil
      end

      def build_prefix(config)
        target = (config.target || :production).to_sym
        case target
        when :sandbox
          # Sandbox prefix requires a slug — handled at call site
          raise RbrunCore::Error::Standard, "Cannot determine prefix for sandbox without slug"
        else
          RbrunCore::Naming.release_prefix(config.git_config.app_name, target)
        end
      end

      def build_logger(log_file)
        # Default: {folder}/deploy.log, override with explicit log_file
        path = log_file || File.join(@folder || ".", "deploy.log")
        abs_path = File.expand_path(path)
        Logger.new(file: abs_path)
      end
  end
end
