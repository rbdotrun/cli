# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"

class SandboxTest < Minitest::Test
  # ── deploy ──

  def test_deploy_generates_slug_when_omitted
    generated_slug = nil

    runner = mock_execute_runner { |slug:, **| generated_slug = slug }
    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml" })
    sandbox.instance_variable_set(:@runner, runner)
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: StringIO.new))

    sandbox.deploy

    assert_match(/\A[a-f0-9]{6}\z/, generated_slug)
  end

  def test_deploy_uses_provided_slug
    used_slug = nil

    runner = mock_execute_runner { |slug:, **| used_slug = slug }
    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd" })
    sandbox.instance_variable_set(:@runner, runner)
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: StringIO.new))

    sandbox.deploy

    assert_equal "ab12cd", used_slug
  end

  def test_deploy_forces_sandbox_target
    used_target = nil

    runner = mock_execute_runner { |target:, **| used_target = target }
    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml" })
    sandbox.instance_variable_set(:@runner, runner)
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: StringIO.new))

    sandbox.deploy

    assert_equal :sandbox, used_target
  end

  # ── destroy ──

  def test_destroy_requires_slug
    output = capture_thor(%w[sandbox destroy -c test.yaml])

    assert_match(/slug/, output)
  end

  def test_destroy_validates_slug_format
    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "bad!" })
    error_output = StringIO.new
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_output))

    assert_raises(SystemExit) { sandbox.destroy }
    assert_includes error_output.string, "Invalid slug format"
  end

  def test_destroy_forces_sandbox_target
    used_target = nil

    runner = mock_execute_runner { |target:, **| used_target = target }
    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd" })
    sandbox.instance_variable_set(:@runner, runner)
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: StringIO.new))

    sandbox.destroy

    assert_equal :sandbox, used_target
  end

  # ── exec ──

  def test_exec_uses_sandbox_prefix
    ctx = build_context(target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    kubectl = Minitest::Mock.new
    kubectl.expect(:exec, { output: "ok", exit_code: 0 }, ["rbrun-sandbox-ab12cd-web", "ls"])
    runner.define_singleton_method(:build_kubectl) { |_| kubectl }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd", process: "web" })
    sandbox.instance_variable_set(:@runner, runner)

    with_captured_stdout { sandbox.exec("ls") }
    kubectl.verify
  end

  def test_exec_service_overrides_process
    ctx = build_context(target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    kubectl = Minitest::Mock.new
    kubectl.expect(:exec, { output: "ok", exit_code: 0 }, ["rbrun-sandbox-ab12cd-redis", "ping"])
    runner.define_singleton_method(:build_kubectl) { |_| kubectl }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd", service: "redis", process: "web" })
    sandbox.instance_variable_set(:@runner, runner)

    with_captured_stdout { sandbox.exec("ping") }
    kubectl.verify
  end

  # ── ssh ──

  def test_ssh_connects_to_sandbox_server
    ctx = build_context(target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "10.0.0.1"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd" })
    sandbox.instance_variable_set(:@runner, runner)

    exec_args = intercept_kernel_exec { sandbox.ssh }
    assert_includes exec_args, "deploy@10.0.0.1"
  end

  # ── sql ──

  def test_sql_aborts_when_no_postgres
    config = build_config
    ctx = RbrunCore::Context.new(config:, target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd" })
    sandbox.instance_variable_set(:@runner, runner)
    error_out = StringIO.new
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_out))

    assert_raises(SystemExit) { sandbox.sql }
    assert_includes error_out.string, "No postgres database configured"
  end

  def test_sql_uses_sandbox_prefix_for_pod_label
    config = build_config
    config.database(:postgres) { |db| db.username = "app"; db.database = "app" }
    ctx = RbrunCore::Context.new(config:, target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd" })
    sandbox.instance_variable_set(:@runner, runner)

    exec_args = intercept_kernel_exec { sandbox.sql }
    cmd = exec_args.join(" ")
    assert_includes cmd, "rbrun-sandbox-ab12cd-postgres"
    assert_includes cmd, "deploy@1.2.3.4"
  end

  # ── logs ──

  def test_logs_uses_sandbox_prefix
    ctx = build_context(target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    kubectl = Minitest::Mock.new
    kubectl.expect(:logs, { output: "sandbox logs", exit_code: 0 }, ["rbrun-sandbox-ab12cd-web"], tail: 100)
    runner.define_singleton_method(:build_kubectl) { |_| kubectl }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd", process: "web", follow: false, tail: 100 })
    sandbox.instance_variable_set(:@runner, runner)

    out = with_captured_stdout { sandbox.logs }
    kubectl.verify
    assert_includes out, "sandbox logs"
  end

  def test_logs_follow_execs_ssh_with_sandbox_prefix
    ctx = build_context(target: :sandbox, slug: "ab12cd")
    ctx.server_ip = "1.2.3.4"
    ctx.ssh_private_key = TEST_SSH_KEY.private_key

    runner = Object.new
    runner.define_singleton_method(:build_operational_context) { |**_| ctx }

    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "ab12cd", process: "web", follow: true, tail: 50 })
    sandbox.instance_variable_set(:@runner, runner)

    exec_args = intercept_kernel_exec { sandbox.logs }
    cmd = exec_args.join(" ")
    assert_includes cmd, "rbrun-sandbox-ab12cd-web"
    assert_includes cmd, "-f"
  end

  # ── error handling ──

  def test_argument_error_exits_1
    sandbox = RbrunCli::Sandbox.new([], { config: "test.yaml", slug: "INVALID" })
    error_out = StringIO.new
    sandbox.instance_variable_set(:@formatter, RbrunCli::Formatter.new(output: error_out))

    assert_raises(SystemExit) { sandbox.exec("ls") }
    assert_includes error_out.string, "Invalid slug format"
  end

  private

    def mock_execute_runner(&on_call)
      runner = Object.new
      runner.define_singleton_method(:execute) do |command_class, **kwargs|
        on_call.call(**kwargs) if on_call
        ctx = Object.new
        ctx.define_singleton_method(:state) { :running }
        ctx.define_singleton_method(:target) { :sandbox }
        ctx.define_singleton_method(:slug) { kwargs[:slug] }
        ctx.define_singleton_method(:prefix) { "rbrun-sandbox-#{kwargs[:slug]}" }
        ctx.define_singleton_method(:server_ip) { nil }
        ctx.define_singleton_method(:servers) { {} }
        ctx
      end
      runner
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
end
