# frozen_string_literal: true

module RbrunCli
  class Backup < Thor
    def self.exit_on_failure? = true

    class_option :config, type: :string, default: "rbrun.yaml", aliases: "-c",
                          desc: "Path to YAML config file"
    class_option :folder, type: :string, aliases: "-f",
                          desc: "Working directory for git detection"
    class_option :env_file, type: :string, default: ".env", aliases: "-e",
                             desc: "Path to .env file for variable interpolation"

    desc "list", "List backups in R2 bucket"
    def list
      with_error_handling do
        config = runner.load_config

        unless config.cloudflare_configured?
          abort_with("Cloudflare not configured - backups require cloudflare config")
        end

        unless config.database?(:postgres)
          abort_with("No postgres database configured")
        end

        cf_config = config.cloudflare_config
        r2 = RbrunCore::Clients::CloudflareR2.new(
          api_token: cf_config.api_token,
          account_id: cf_config.account_id
        )

        bucket_name = RbrunCore::Naming.backup_bucket(config.git_config.app_name, config.target)

        begin
          objects = r2.list_objects(bucket: bucket_name)
        rescue Aws::S3::Errors::NoSuchBucket
          formatter.info("No backups found (bucket does not exist yet)")
          return
        rescue Aws::S3::Errors::AccessDenied
          formatter.error("Access denied. Ensure your Cloudflare API token has R2 permissions.")
          formatter.info("Run 'rbrun release deploy' first to create the backup bucket.")
          return
        end

        if objects.empty?
          formatter.info("No backups found")
        else
          formatter.backup_list(objects)
        end
      end
    end

    desc "now", "Trigger immediate backup"
    def now
      with_error_handling do
        config = runner.load_config

        unless config.database?(:postgres)
          abort_with("No postgres database configured")
        end

        ctx = runner.build_operational_context
        kubectl = runner.build_kubectl(ctx)

        cronjob_name = "#{ctx.prefix}-postgres-backup"
        formatter.info("Starting backup...")
        job_name = kubectl.create_job_from_cronjob(cronjob_name)

        formatter.info("Waiting for job #{job_name} to complete...")
        kubectl.wait_for_job(job_name)

        formatter.success("Backup completed successfully")
      end
    end

    private

      def runner
        @runner ||= Runner.new(
          config_path: options[:config],
          folder: options[:folder],
          env_file: options[:env_file],
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
