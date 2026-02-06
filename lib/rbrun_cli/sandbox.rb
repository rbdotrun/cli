# frozen_string_literal: true

module RbrunCli
  class Sandbox < Thor
    def self.exit_on_failure? = true

    class_option :config, type: :string, required: true, aliases: "-c",
                          desc: "Path to YAML config file"
    class_option :folder, type: :string, aliases: "-f",
                          desc: "Working directory for git detection"
    class_option :env_file, type: :string, aliases: "-e",
                             desc: "Path to .env file for variable interpolation"
    class_option :log_file, type: :string, aliases: "-l",
                             desc: "Log file path (default: {folder}/deploy.log)"

    desc "deploy", "Deploy a development sandbox"
    option :slug, type: :string, desc: "Sandbox slug (auto-generated if omitted)"
    def deploy
      with_error_handling do
        slug = options[:slug] || RbrunCore::Naming.generate_slug
        runner.execute(RbrunCore::Commands::DeploySandbox, target: :sandbox, slug:)
      end
    end

    desc "destroy", "Tear down a sandbox"
    option :slug, type: :string, required: true, desc: "Sandbox slug"
    def destroy
      with_error_handling do
        RbrunCore::Naming.validate_slug!(options[:slug])
        runner.execute(RbrunCore::Commands::DestroySandbox, target: :sandbox, slug: options[:slug])
      end
    end

    desc "exec COMMAND", "Execute command in sandbox"
    option :slug, type: :string, required: true, desc: "Sandbox slug"
    option :process, type: :string, default: "web", desc: "App process name"
    option :service, type: :string, desc: "Service name (overrides --process)"
    def exec(command)
      with_error_handling do
        RbrunCore::Naming.validate_slug!(options[:slug])
        ctx = runner.build_operational_context(target: :sandbox, slug: options[:slug])
        kubectl = runner.build_kubectl(ctx)

        prefix = RbrunCore::Naming.resource(options[:slug])
        deployment = if options[:service]
          "#{prefix}-#{options[:service]}"
        else
          "#{prefix}-#{options[:process]}"
        end

        result = kubectl.exec(deployment, command)
        $stdout.puts result[:output]
      end
    end

    desc "ssh", "SSH into sandbox server"
    option :slug, type: :string, required: true, desc: "Sandbox slug"
    def ssh
      with_error_handling do
        RbrunCore::Naming.validate_slug!(options[:slug])
        ctx = runner.build_operational_context(target: :sandbox, slug: options[:slug])
        key_path = File.expand_path(ctx.config.compute_config.ssh_key_path)
        Kernel.exec("ssh", "-i", key_path, "-o", "StrictHostKeyChecking=no",
                    "deploy@#{ctx.server_ip}")
      end
    end

    desc "sql", "Connect to sandbox PostgreSQL"
    option :slug, type: :string, required: true, desc: "Sandbox slug"
    def sql
      with_error_handling do
        RbrunCore::Naming.validate_slug!(options[:slug])
        ctx = runner.build_operational_context(target: :sandbox, slug: options[:slug])
        pg = ctx.config.database_configs[:postgres]
        abort_with("No postgres database configured") unless pg

        key_path = File.expand_path(ctx.config.compute_config.ssh_key_path)
        prefix = RbrunCore::Naming.resource(options[:slug])
        pod_label = "#{prefix}-postgres"
        psql_cmd = "psql -U #{pg.username || "app"} #{pg.database || "app"}"
        Kernel.exec("ssh", "-t", "-i", key_path, "-o", "StrictHostKeyChecking=no",
                    "deploy@#{ctx.server_ip}",
                    "kubectl exec -it $(kubectl get pods -l app=#{pod_label} -o jsonpath='{.items[0].metadata.name}') -- #{psql_cmd}")
      end
    end

    desc "logs", "Show sandbox logs"
    option :slug, type: :string, required: true, desc: "Sandbox slug"
    option :process, type: :string, default: "web", desc: "App process name"
    option :service, type: :string, desc: "Service name (overrides --process)"
    option :tail, type: :numeric, default: 100, desc: "Number of lines"
    option :follow, type: :boolean, default: false, aliases: "-F", desc: "Stream logs in real-time"
    def logs
      with_error_handling do
        RbrunCore::Naming.validate_slug!(options[:slug])
        ctx = runner.build_operational_context(target: :sandbox, slug: options[:slug])

        prefix = RbrunCore::Naming.resource(options[:slug])
        deployment = if options[:service]
          "#{prefix}-#{options[:service]}"
        else
          "#{prefix}-#{options[:process]}"
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
          env_file: options[:env_file],
          log_file: options[:log_file],
          formatter:
        )
      end

      def formatter
        @formatter ||= Formatter.new
      end

      def abort_with(message)
        formatter.error(message)
        exit 1
      end

      def with_error_handling
        yield
      rescue ArgumentError => e
        formatter.error(e.message)
        exit 1
      rescue RbrunCore::Error::Configuration => e
        formatter.error("Configuration error: #{e.message}")
        exit 1
      rescue RbrunCore::Error::Api => e
        formatter.error("API error: #{e.message}")
        exit 1
      rescue RbrunCore::Clients::Ssh::CommandError => e
        formatter.error("Command failed (exit #{e.exit_code}): #{e.output}")
        exit 1
      rescue RbrunCore::Error::Standard => e
        formatter.error(e.message)
        exit 1
      end
  end
end
