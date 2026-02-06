# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"

class ReleaseTest < Minitest::Test
  def test_deploy_requires_config_option
    output = capture_thor(%w[release deploy])

    assert_match(/config/, output)
  end

  def test_configuration_error_exits_1
    with_invalid_config do |path|
      release = RbrunCli::Release.new([], { config: path })
      error_output = StringIO.new
      release.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_output))

      assert_raises(SystemExit) { release.deploy }
      assert_includes error_output.string, "Error:"
    end
  end

  # ── exec ──

  def test_exec_targets_service_when_service_option
    release, kubectl = build_release_with_kubectl(service: "redis", process: "web")
    kubectl.expect(:exec, { output: "ok", exit_code: 0 }, [ "test-repo-production-redis", "echo hi" ])

    with_captured_stdout { release.exec("echo hi") }
    kubectl.verify
  end

  def test_exec_defaults_to_web_process
    release, kubectl = build_release_with_kubectl(process: "web")
    kubectl.expect(:exec, { output: "done", exit_code: 0 }, [ "test-repo-production-web", "rails c" ])

    out = with_captured_stdout { release.exec("rails c") }
    kubectl.verify

    assert_includes out, "done"
  end

  def test_exec_output_goes_to_stdout
    release, kubectl = build_release_with_kubectl(process: "web")
    kubectl.expect(:exec, { output: "line1\nline2", exit_code: 0 }, [ "test-repo-production-web", "ls" ])

    out = with_captured_stdout { release.exec("ls") }

    assert_includes out, "line1\nline2"
  end

  # ── sql ──

  def test_sql_aborts_when_no_postgres
    config = build_config
    ctx = RbrunCore::Context.new(config:, target: :production)
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    release = build_release_with_ctx(ctx)

    assert_raises(SystemExit) { release.sql }
    assert_includes release_error_output(release), "No postgres database configured"
  end

  def test_sql_execs_ssh_with_psql
    config = build_config
    config.database(:postgres) { |db| db.username = "myuser"; db.database = "mydb" }
    ctx = RbrunCore::Context.new(config:, target: :production)
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    release = build_release_with_ctx(ctx)
    exec_args = intercept_kernel_exec { release.sql }

    assert_includes exec_args.join(" "), "psql -U myuser mydb"
    assert_includes exec_args, "deploy@1.2.3.4"
  end

  # ── status ──

  def test_status_lists_servers_by_prefix
    config = build_config
    config.git { |g| g.repo = "owner/myapp" }

    matching = RbrunCore::Clients::Compute::Types::Server.new(
      name: "myapp-production", public_ipv4: "1.2.3.4", status: "running", instance_type: "cpx11"
    )
    other = RbrunCore::Clients::Compute::Types::Server.new(
      name: "other-app", public_ipv4: "5.6.7.8", status: "running", instance_type: "cpx11"
    )
    config.compute_config.client.define_singleton_method(:list_servers) { [ matching, other ] }

    runner = Object.new
    runner.define_singleton_method(:load_config) { config }

    release = RbrunCli::Release.new([], { config: "test.yaml" })
    release.instance_variable_set(:@runner, runner)

    out = capture_output do |o|
      release.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: o))
      release.status
    end

    assert_includes out, "myapp-production"
    refute_includes out, "other-app"
  end

  # ── ssh ──

  def test_ssh_resolves_server_by_name
    ctx = build_context
    ctx.server_ip = "9.8.7.6"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |server: nil| ctx }

    release = RbrunCli::Release.new([], { config: "test.yaml", server: "worker-1" })
    release.instance_variable_set(:@runner, runner)

    exec_args = intercept_kernel_exec { release.ssh }

    assert_includes exec_args, "deploy@9.8.7.6"
  end

  def test_ssh_uses_configured_key_path
    ctx = build_context
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |server: nil| ctx }

    release = RbrunCli::Release.new([], { config: "test.yaml" })
    release.instance_variable_set(:@runner, runner)

    exec_args = intercept_kernel_exec { release.ssh }

    assert_includes exec_args, "-i"
    assert(exec_args.any? { |a| a.include?("id_rsa") || a.include?("ssh") })
  end

  # ── logs ──

  def test_logs_non_follow_uses_kubectl
    release, kubectl = build_release_with_kubectl(process: "web", follow: false, tail: 50)
    kubectl.expect(:logs, { output: "log output", exit_code: 0 }, [ "test-repo-production-web" ], tail: 50)

    out = with_captured_stdout { release.logs }
    kubectl.verify

    assert_includes out, "log output"
  end

  def test_logs_follow_execs_ssh
    ctx = build_context
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    release = RbrunCli::Release.new([], { config: "test.yaml", process: "web", follow: true, tail: 100 })
    release.instance_variable_set(:@runner, runner)

    exec_args = intercept_kernel_exec { release.logs }
    cmd = exec_args.join(" ")

    assert_includes cmd, "kubectl logs"
    assert_includes cmd, "-f"
    assert_includes cmd, "test-repo-production-web"
  end

  def test_logs_service_overrides_process
    release, kubectl = build_release_with_kubectl(service: "redis", process: "web", follow: false, tail: 100)
    kubectl.expect(:logs, { output: "redis logs", exit_code: 0 }, [ "test-repo-production-redis" ], tail: 100)

    with_captured_stdout { release.logs }
    kubectl.verify
  end

  # ── error handling ──

  def test_api_error_exits_1
    runner = Object.new
    runner.define_singleton_method(:load_config) do
      raise RbrunCore::Error::Api.new("[401] Unauthorized", status: 401)
    end

    release = RbrunCli::Release.new([], { config: "test.yaml" })
    release.instance_variable_set(:@runner, runner)
    error_out = StringIO.new
    release.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_out))

    assert_raises(SystemExit) { release.status }
    assert_includes error_out.string, "API error"
  end

  def test_ssh_command_error_shows_output
    runner = Object.new
    runner.define_singleton_method(:build_operational_context) do |**_|
      raise RbrunCore::Clients::Ssh::CommandError.new("fail", exit_code: 127, output: "command not found")
    end

    release = RbrunCli::Release.new([], { config: "test.yaml", process: "web" })
    release.instance_variable_set(:@runner, runner)
    error_out = StringIO.new
    release.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_out))

    assert_raises(SystemExit) { release.exec("bad") }
    assert_includes error_out.string, "command not found"
  end

  # ── destroy ──

  def test_destroy_requires_config_option
    output = capture_thor(%w[release destroy])

    assert_match(/config/, output)
  end

  private

    def build_release_with_kubectl(**opts)
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      runner = Object.new
      runner.define_singleton_method(:build_operational_context) { |**_| ctx }

      kubectl = Minitest::Mock.new
      runner.define_singleton_method(:build_kubectl) { |_| kubectl }

      release = RbrunCli::Release.new([], { config: "test.yaml" }.merge(opts))
      release.instance_variable_set(:@runner, runner)

      [ release, kubectl ]
    end

    def build_release_with_ctx(ctx, **opts)
      runner = Object.new
      runner.define_singleton_method(:build_operational_context) { |**_| ctx }

      release = RbrunCli::Release.new([], { config: "test.yaml" }.merge(opts))
      release.instance_variable_set(:@runner, runner)
      error_out = StringIO.new
      release.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_out))
      release
    end

    def release_error_output(release)
      release.instance_variable_get(:@formatter).instance_variable_get(:@output).string
    end

    def with_captured_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    def intercept_kernel_exec
      exec_args = nil
      Kernel.define_singleton_method(:exec) { |*args| exec_args = args; throw :exec_called }
      catch(:exec_called) { yield }
      exec_args
    ensure
      class << Kernel; remove_method(:exec); end if exec_args
    end

    def capture_thor(args)
      output = StringIO.new
      begin
        original_stderr = $stderr
        $stderr = output
        RbrunCli::CLI.start(args)
      rescue SystemExit
        # Expected
      ensure
        $stderr = original_stderr
      end
      output.string
    end

    def with_invalid_config
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad.yaml")
        File.write(path, YAML.dump("compute" => { "provider" => "hetzner" }))
        yield path
      end
    end
end
