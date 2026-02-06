# frozen_string_literal: true

# CI Integration Test - Full Deployment Lifecycle
#
# Runs real deployments through all scale scenarios using Topology validation.
#
# == Local Development (gradual testing)
#
# For iterative local testing, uncomment scenarios one at a time:
#
#   1. Uncomment scenario_1, run `rake ci:integration`
#   2. If success, uncomment scenario_2, run again (infra persists, idempotent)
#   3. Continue through scenario_4
#   4. For scenario_5 (final), also enable ensure/cleanup block
#   5. If cleanup fails mid-run: `rake ci:cleanup`
#
# This approach allows fixing issues incrementally without full teardown.
#
# == Remote CI (GitHub Actions)
#
# CI runs all scenarios in sequence with cleanup on completion/failure.
# All scenarios must be uncommented and ensure/cleanup enabled.
#
# == Environment
#
# Optional:
#   CI_APP_PATH  - Path to app (default: ~/Desktop/dummy-rails)
#   CI_ENV_PATH  - Path to .env file (default: $CI_APP_PATH/.env)
#   CI_LOG_PATH  - Log file path (default: /tmp/rbrun-ci-test.log)
#
# Required (in .env or exported):
#   HETZNER_API_TOKEN, CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, RAILS_MASTER_KEY
#

require "rbrun_cli"
require "yaml"
require "fileutils"
require "net/http"
require "uri"

namespace :ci do
  desc "Run full integration test: deploy -> scale up -> idempotent -> scale down -> destroy"
  task :integration do
    CiIntegration.new.run
  end

  desc "Cleanup CI infrastructure (use if test failed)"
  task :cleanup do
    CiIntegration.new.cleanup_only
  end
end

class CiIntegration
  CONFIG_PATH = "/tmp/rbrun-ci-test.yaml"
  LOG_PATH = ENV.fetch("CI_LOG_PATH", "/tmp/rbrun-ci-test.log")
  APP_PATH = ENV.fetch("CI_APP_PATH", File.expand_path("~/Desktop/dummy-rails"))
  ENV_PATH = ENV.fetch("CI_ENV_PATH", File.join(APP_PATH, ".env"))

  def initialize
    @logs = []
    @ctx = nil
    @last_log_count = 0
    @log_file = File.open(LOG_PATH, "a")
    @log_file.sync = true
    load_env_file!
    log("=" * 60)
    log("CI Integration started at #{Time.now}")
    log("=" * 60)
  end

  def run
    validate_env!
    probe_current_state!

    start = detect_starting_scenario
    log("Detected #{current_node_count} nodes, starting from scenario #{start}")

    scenario_1_single_server if start <= 1
    scenario_2_isolate_database if start <= 2
    scenario_3_scale_up if start <= 3
    scenario_4_idempotent_redeploy if start <= 4
    scenario_5_scale_down if start <= 5

    log_success("All scenarios passed!")
  end

  def probe_current_state!
    write_config(base_config)
    runner = RbrunCli::Runner.new(
      config_path: CONFIG_PATH,
      folder: APP_PATH,
      env_file: File.exist?(ENV_PATH) ? ENV_PATH : nil,
      formatter: CiFormatter.new(method(:log))
    )
    @ctx = runner.build_context(target: :production)
    runner.send(:load_ssh_keys!, @ctx)
    @ctx.server_ip = find_any_server_ip
  rescue
    @ctx = nil
  end

  def find_any_server_ip
    config = RbrunCore::Config::Loader.load(CONFIG_PATH)
    client = config.compute_config.client
    prefix = "dummy-rails-production"
    server = client.list_servers.find { |s| s.name.start_with?(prefix) }
    server&.public_ipv4
  end

  def detect_starting_scenario
    count = current_node_count
    case count
    when 0, 1 then 1
    when 2, 3 then 2
    when 4, 5 then 3
    else 1
    end
  end

  def current_node_count
    return 0 unless @ctx

    topology.nodes.count
  rescue
    0
  end

  def cleanup_only
    validate_env!
    write_config(compute_single_server) # Use single-server to match any state
    deploy_and_capture_context
    cleanup
  end

  private

    # ───────────────────────────────────────────────────────────────────────────
    # Scenarios
    # ───────────────────────────────────────────────────────────────────────────

    # Scenario 1: Single master (everything on one box)
    #
    # Expected topology after deploy:
    #   Nodes: 1 (ci-test-production-master-1)
    #   Pods:
    #     - master-1: web*2, worker*1, postgres*1, tunnel*1
    #
    def scenario_1_single_server
      log_scenario("1. Single master deploy")

      write_config(compute_single_server)
      deploy!

      assert_node_count(1)
      topology.validate_replicas!({ "web" => 2, "worker" => 1, "postgres" => 1 })
      verify_app_responds!
      log_success("Single master: OK")
    end

    # Scenario 2: Master + app workers (apps move to app nodes, db stays on master)
    #
    # Expected topology after deploy:
    #   Nodes: 3
    #     - ci-test-production-master-1 (K3s master)
    #     - ci-test-production-app-1 (K3s worker)
    #     - ci-test-production-app-2 (K3s worker)
    #   Pods:
    #     - master-1: postgres*1, tunnel*1
    #     - app-1: web*1, worker*1
    #     - app-2: web*1
    #
    def scenario_2_isolate_database
      log_scenario("2. Master + app workers (3 servers)")

      write_config(compute_with_app_workers)
      deploy!

      assert_node_count(3)
      topology.validate_placement!({ "web" => ["app"], "worker" => ["app"], "postgres" => ["master"] })
      topology.validate_replicas!({ "web" => 2, "worker" => 1, "postgres" => 1 })
      verify_app_responds!
      log_success("Master + app workers: OK")
    end

    # Scenario 3: Scale up (more app servers + dedicated worker servers)
    #
    # Expected topology after deploy:
    #   Nodes: 5
    #     - ci-test-production-master-1 (K3s master)
    #     - ci-test-production-app-1 (K3s worker)
    #     - ci-test-production-app-2 (K3s worker)
    #     - ci-test-production-app-3 (K3s worker)
    #     - ci-test-production-worker-1 (K3s worker)
    #   Pods:
    #     - master-1: postgres*1, tunnel*1
    #     - app-1, app-2, app-3: web*4 distributed
    #     - worker-1: worker*2
    #   Total: web*4, worker*2, postgres*1
    #
    def scenario_3_scale_up
      log_scenario("3. Scale up (3 app servers + 4 web replicas)")

      write_config(compute_scaled_up)
      deploy!

      assert_node_count(5)
      topology.validate_placement!({ "web" => ["app"], "worker" => ["worker"], "postgres" => ["master"] })
      topology.validate_replicas!({ "web" => 4, "worker" => 2, "postgres" => 1 })
      verify_app_responds!
      log_success("Scale up: OK")
    end

    # Scenario 4: Idempotent redeploy (same config, no infra changes)
    #
    # Expected topology after deploy:
    #   Nodes: 5 (unchanged)
    #   Pods: same distribution (unchanged)
    #   new_servers: empty (no new servers created)
    #   Server IDs: identical to before
    #
    def scenario_4_idempotent_redeploy
      log_scenario("4. Idempotent redeploy")

      servers_before = list_servers
      deploy!
      servers_after = list_servers

      if servers_before.map(&:id).sort != servers_after.map(&:id).sort
        raise RbrunCore::Error::Standard, "Idempotency failed: servers changed"
      end

      if @ctx.new_servers.any?
        raise RbrunCore::Error::Standard, "Idempotency failed: new_servers not empty: #{@ctx.new_servers.to_a}"
      end

      verify_app_responds!
      log_success("Idempotent redeploy: OK")
    end

    # Scenario 5: Scale down (remove extra app servers and dedicated worker server)
    #
    # Expected topology after deploy:
    #   Nodes: 2
    #     - ci-test-production-master-1 (K3s master) -- kept
    #     - ci-test-production-app-1 (K3s worker) -- kept
    #   Removed:
    #     - ci-test-production-app-3 (drained, deleted)
    #     - ci-test-production-app-2 (drained, deleted)
    #     - ci-test-production-worker-1 (drained, deleted)
    #   Pods:
    #     - master-1: postgres*1, tunnel*1
    #     - app-1: web*2, worker*1
    #
    def scenario_5_scale_down
      log_scenario("5. Scale down (master + 1 app)")

      write_config(compute_scaled_down)
      deploy!

      assert_node_count(2)
      topology.validate_placement!({ "web" => ["app"], "worker" => ["app"], "postgres" => ["master"] })
      topology.validate_replicas!({ "web" => 2, "worker" => 1, "postgres" => 1 })
      verify_app_responds!
      log_success("Scale down: OK")
    end

    # ───────────────────────────────────────────────────────────────────────────
    # Config Generators
    # ───────────────────────────────────────────────────────────────────────────

    def base_config
      {
        "target" => "ci-test",
        "compute" => {
          "provider" => "hetzner",
          "api_key" => ENV.fetch("HETZNER_API_TOKEN"),
          "ssh_key_path" => ENV.fetch("SSH_KEY_PATH", "~/.ssh/id_rsa"),
          "location" => "ash",
          "master" => { "instance_type" => "cpx21" }
        },
        "cloudflare" => {
          "api_token" => ENV.fetch("CLOUDFLARE_API_TOKEN"),
          "account_id" => ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
          "domain" => ENV.fetch("CLOUDFLARE_DOMAIN", "rb.run")
        },
        "databases" => { "postgres" => nil },
        "app" => {
          "dockerfile" => "Dockerfile",
          "processes" => {
            "web" => {
              "command" => "./bin/thrust ./bin/rails server",
              "port" => 80,
              "subdomain" => "ci-test",
              "replicas" => 2
            },
            "worker" => {
              "command" => "bin/jobs",
              "replicas" => 1
            }
          }
        },
        "setup" => ["bin/rails db:prepare"],
        "env" => {
          "RAILS_ENV" => "production",
          "RAILS_MASTER_KEY" => ENV.fetch("RAILS_MASTER_KEY")
        }
      }
    end

    # Scenario 1: Single master only (uses base_config which already has master)
    def compute_single_server
      deep_dup(base_config)
    end

    # Scenario 2: Master + 2 app workers (apps move to app nodes, db stays on master)
    def compute_with_app_workers
      config = deep_dup(base_config)
      config["compute"] = base_config["compute"].merge(
        "master" => { "instance_type" => "cpx21" },
        "servers" => { "app" => { "type" => "cpx21", "count" => 2 } }
      )
      config["app"]["processes"]["web"]["runs_on"] = ["app"]
      config["app"]["processes"]["worker"]["runs_on"] = ["app"]
      config
    end

    # Scenario 3: Master + 3 app workers + 1 dedicated worker
    def compute_scaled_up
      config = deep_dup(base_config)
      config["compute"] = base_config["compute"].merge(
        "master" => { "instance_type" => "cpx21" },
        "servers" => {
          "app" => { "type" => "cpx21", "count" => 3 },
          "worker" => { "type" => "cpx21" }
        }
      )
      config["app"]["processes"] = {
        "web" => {
          "command" => "./bin/thrust ./bin/rails server",
          "port" => 80,
          "subdomain" => "ci-test",
          "replicas" => 4,
          "runs_on" => ["app"]
        },
        "worker" => { "command" => "bin/jobs", "replicas" => 2, "runs_on" => ["worker"] }
      }
      config
    end

    # Scenario 5: Master + 1 app worker (scale down servers, keep all processes)
    def compute_scaled_down
      config = deep_dup(base_config)
      config["compute"] = base_config["compute"].merge(
        "master" => { "instance_type" => "cpx21" },
        "servers" => { "app" => { "type" => "cpx21" } }
      )
      # Keep both web and worker processes - only server count changes
      config["app"]["processes"]["web"]["runs_on"] = ["app"]
      config["app"]["processes"]["worker"]["runs_on"] = ["app"]
      config
    end

    # ───────────────────────────────────────────────────────────────────────────
    # Helpers
    # ───────────────────────────────────────────────────────────────────────────

    def write_config(config)
      File.write(CONFIG_PATH, YAML.dump(config))
    end

    def deploy!
      runner = RbrunCli::Runner.new(
        config_path: CONFIG_PATH,
        folder: APP_PATH,
        env_file: File.exist?(ENV_PATH) ? ENV_PATH : nil,
        formatter: CiFormatter.new(method(:log))
      )

      @ctx = runner.execute(RbrunCore::Commands::Deploy, target: :production)
    end

    def deploy_and_capture_context
      runner = RbrunCli::Runner.new(
        config_path: CONFIG_PATH,
        folder: APP_PATH,
        env_file: File.exist?(ENV_PATH) ? ENV_PATH : nil,
        formatter: CiFormatter.new(method(:log))
      )
      @ctx = runner.build_context(target: :production)
      runner.send(:load_ssh_keys!, @ctx)
    end

    def topology
      RbrunCore::Topology.new(@ctx)
    end

    def assert_node_count(expected)
      actual = topology.nodes.count
      return if actual == expected

      raise RbrunCore::Error::Standard, "Expected #{expected} nodes, got #{actual}"
    end

    def list_servers
      prefix = @ctx.prefix
      @ctx.compute_client.list_servers.select { |s| s.name.start_with?("#{prefix}-") }
    end

    # ───────────────────────────────────────────────────────────────────────────
    # App Verification
    # ───────────────────────────────────────────────────────────────────────────

    def verify_app_responds!
      wait_for_pods_ready!("web")
      log("[verify] Hitting web pod via localhost:3000")
      hit_endpoint!(3)

      # Wait for background job to process
      sleep 2

      new_count = get_log_count
      log("[verify] Log count: #{@last_log_count} -> #{new_count}")

      if new_count <= @last_log_count
        raise RbrunCore::Error::Standard, "Log count did not increase: was #{@last_log_count}, now #{new_count}"
      end

      @last_log_count = new_count
    end

    def wait_for_pods_ready!(app_suffix, max_attempts: 24, interval: 5)
      prefix = @ctx.prefix
      app_label = "#{prefix}-#{app_suffix}"

      RbrunCore::Waiter.poll(max_attempts:, interval:, message: "Pods for #{app_suffix} not ready after #{max_attempts * interval}s") do
        ready_pods = topology.pods.select { |p| p[:app] == app_label && p[:ready] }
        log("[verify] Waiting for #{app_suffix} pods: #{ready_pods.count} ready") if ready_pods.empty?
        ready_pods.any?
      end
    end

    def app_url
      subdomain = base_config.dig("app", "processes", "web", "subdomain")
      domain = base_config.dig("cloudflare", "domain")
      "https://#{subdomain}.#{domain}/"
    end

    def hit_endpoint!(count)
      kubectl = RbrunCore::Clients::Kubectl.new(@ctx.ssh_client)
      prefix = @ctx.prefix

      count.times do |i|
        result = kubectl.exec("#{prefix}-web", "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/")
        code = result[:output].strip.delete("'")
        log("[verify] Request #{i + 1}: HTTP #{code}")
        raise RbrunCore::Error::Standard, "HTTP request failed: #{code}" unless code == "200"
        sleep 0.5
      end
    end

    def get_log_count
      kubectl = RbrunCore::Clients::Kubectl.new(@ctx.ssh_client)
      prefix = @ctx.prefix
      pg = @ctx.config.database_configs[:postgres]
      username = pg&.username || "app"
      database = pg&.database || "app"

      # Get count from logs table via psql in postgres pod
      result = kubectl.exec(
        "#{prefix}-postgres",
        "psql -U #{username} -d #{database} -t -c 'SELECT COUNT(*) FROM logs;'"
      )
      result[:output].strip.to_i
    end

    def cleanup
      return unless @ctx

      log_scenario("Cleanup: destroying infrastructure")
      RbrunCore::Commands::Destroy.new(
        @ctx,
        logger: CiFormatter.new(method(:log))
      ).run
    rescue StandardError => e
      log("Cleanup failed: #{e.message}")
    end

    def load_env_file!
      return unless File.exist?(ENV_PATH)

      File.readlines(ENV_PATH).each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        next unless key && value

        value = value.strip
        value = value[1..-2] if (value.start_with?('"') && value.end_with?('"')) ||
                                (value.start_with?("'") && value.end_with?("'"))

        ENV[key.strip] = value
      end

      log("Loaded env from #{ENV_PATH}")
    end

    def validate_env!
      required = %w[HETZNER_API_TOKEN CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID RAILS_MASTER_KEY]
      missing = required.reject { |k| ENV.key?(k) }
      raise "Missing env vars: #{missing.join(', ')}" if missing.any?
    end

    def deep_dup(hash)
      Marshal.load(Marshal.dump(hash))
    end

    def log(message)
      ts = Time.now.strftime("%H:%M:%S")
      line = "[#{ts}] [CI] #{message}"
      puts line
      @log_file&.puts(line)
      @logs << "[#{ts}] #{message}"
    end

    def log_scenario(message)
      separator = "=" * 60
      puts "\n#{separator}"
      puts "[CI] #{message}"
      puts separator
      @log_file&.puts("\n#{separator}")
      @log_file&.puts("[CI] #{message}")
      @log_file&.puts(separator)
    end

    def log_success(message)
      line = "[CI] ✓ #{message}"
      puts line
      @log_file&.puts(line)
    end

  # Minimal formatter for CI output
  class CiFormatter
    def initialize(log_proc)
      @log_proc = log_proc
    end

    def log(category, message)
      @log_proc.call("[#{category}] #{message}")
    end

    def state_change(state)
      @log_proc.call("State: #{state}")
    end

    def summary(ctx)
      @log_proc.call("Deploy complete: #{ctx.server_ip}")
    end

    def error(message)
      @log_proc.call("ERROR: #{message}")
    end
  end
end
