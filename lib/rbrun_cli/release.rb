# frozen_string_literal: true

module RbrunCli
  class Release < Thor
    def self.exit_on_failure? = true

    class_option :config, type: :string, required: true, aliases: "-c",
                          desc: "Path to YAML config file"
    class_option :folder, type: :string, aliases: "-f",
                          desc: "Working directory for git detection"

    desc "deploy", "Deploy release infrastructure + app"
    def deploy
      with_error_handling do
        runner.execute(RbrunCore::Commands::Deploy, target: :production)
      end
    end

    desc "destroy", "Tear down release infrastructure"
    def destroy
      with_error_handling do
        runner.execute(RbrunCore::Commands::Destroy, target: :production)
      end
    end

    desc "status", "Show servers and their status"
    def status
      with_error_handling do
        config = runner.load_config
        compute_client = config.compute_config.client
        prefix = build_prefix(config)
        servers = compute_client.list_servers.select { |s| s.name.start_with?(prefix) }
        formatter.status_table(servers)
      end
    end

    desc "exec COMMAND", "Execute command in a running pod"
    option :process, type: :string, default: "web", desc: "App process name"
    option :service, type: :string, desc: "Service name (overrides --process)"
    option :server, type: :string, desc: "Server name for multi-server (e.g. worker-1)"
    def exec(command)
      with_error_handling do
        ctx = runner.build_operational_context(server: options[:server])
        kubectl = runner.build_kubectl(ctx)

        deployment = if options[:service]
          "#{ctx.prefix}-#{options[:service]}"
        else
          "#{ctx.prefix}-#{options[:process]}"
        end

        result = kubectl.exec(deployment, command)
        $stdout.puts result[:output]
      end
    end

    desc "ssh", "SSH into the server"
    option :server, type: :string, desc: "Server name for multi-server (e.g. worker-1)"
    def ssh
      with_error_handling do
        ctx = runner.build_operational_context(server: options[:server])
        key_path = File.expand_path(ctx.config.compute_config.ssh_key_path)
        Kernel.exec("ssh", "-i", key_path, "-o", "StrictHostKeyChecking=no",
                    "deploy@#{ctx.server_ip}")
      end
    end

    desc "sql", "Connect to PostgreSQL via psql"
    def sql
      with_error_handling do
        ctx = runner.build_operational_context
        pg = ctx.config.database_configs[:postgres]
        abort_with("No postgres database configured") unless pg

        key_path = File.expand_path(ctx.config.compute_config.ssh_key_path)
        pod_label = "#{ctx.prefix}-postgres"
        psql_cmd = "psql -U #{pg.username || "app"} #{pg.database || "app"}"
        Kernel.exec("ssh", "-t", "-i", key_path, "-o", "StrictHostKeyChecking=no",
                    "deploy@#{ctx.server_ip}",
                    "kubectl exec -it $(kubectl get pods -l app=#{pod_label} -o jsonpath='{.items[0].metadata.name}') -- #{psql_cmd}")
      end
    end

    desc "logs", "Show pod logs"
    option :process, type: :string, default: "web", desc: "App process name"
    option :service, type: :string, desc: "Service name (overrides --process)"
    option :tail, type: :numeric, default: 100, desc: "Number of lines"
    option :follow, type: :boolean, default: false, aliases: "-F", desc: "Stream logs in real-time"
    def logs
      with_error_handling do
        ctx = runner.build_operational_context

        deployment = if options[:service]
          "#{ctx.prefix}-#{options[:service]}"
        else
          "#{ctx.prefix}-#{options[:process]}"
        end

        if options[:follow]
          key_path = File.expand_path(ctx.config.compute_config.ssh_key_path)
          Kernel.exec("ssh", "-t", "-i", key_path, "-o", "StrictHostKeyChecking=no",
                      "deploy@#{ctx.server_ip}",
                      "kubectl logs -l app=#{deployment} --tail=#{options[:tail]} -f --all-containers --prefix")
        else
          kubectl = runner.build_kubectl(ctx)
          result = kubectl.logs(deployment, tail: options[:tail])
          $stdout.puts result[:output]
        end
      end
    end

    private

      def runner
        @runner ||= Runner.new(
          config_path: options[:config],
          folder: options[:folder],
          formatter:
        )
      end

      def formatter
        @formatter ||= Formatter.new
      end

      def build_prefix(config)
        target = (config.target || :production).to_sym
        RbrunCore::Naming.release_prefix(config.git_config.app_name, target)
      end

      def abort_with(message)
        formatter.error(message)
        exit 1
      end

      def with_error_handling
        yield
      rescue RbrunCore::ConfigurationError => e
        formatter.error("Configuration error: #{e.message}")
        exit 1
      rescue RbrunCore::HttpErrors::ApiError => e
        formatter.error("API error: #{e.message}")
        exit 1
      rescue RbrunCore::Clients::Ssh::CommandError => e
        formatter.error("Command failed (exit #{e.exit_code}): #{e.output}")
        exit 1
      rescue RbrunCore::Error => e
        formatter.error(e.message)
        exit 1
      end
  end
end
