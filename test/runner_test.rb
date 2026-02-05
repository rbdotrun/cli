# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "yaml"

class RunnerTest < Minitest::Test
  def test_load_config_returns_validated_configuration
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      config = runner.load_config

      assert_instance_of RbrunCore::Configuration, config
    end
  end

  def test_load_config_raises_on_missing_file
    runner = RbrunCli::Runner.new(config_path: "/nonexistent/config.yaml")

    assert_raises(Errno::ENOENT) { runner.load_config }
  end

  def test_build_context_returns_context_with_target
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      ctx = runner.build_context(target: :production)

      assert_instance_of RbrunCore::Context, ctx
      assert_equal :production, ctx.target
    end
  end

  def test_build_context_with_sandbox_target_and_slug
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      ctx = runner.build_context(target: :sandbox, slug: "ab12cd")

      assert_equal :sandbox, ctx.target
      assert_equal "ab12cd", ctx.slug
    end
  end

  def test_find_server_raises_when_no_match
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      config = runner.load_config
      config.git { |g| g.repo = "owner/test-repo" }

      compute_client = config.compute_config.client
      compute_client.define_singleton_method(:list_servers) { [] }

      error = assert_raises(RbrunCore::Error) do
        runner.find_server(config)
      end
      assert_includes error.message, "No server found"
    end
  end

  def test_find_server_returns_matching_server
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      config = runner.load_config
      config.git { |g| g.repo = "owner/test-repo" }

      server = RbrunCore::Clients::Compute::Types::Server.new(
        name: "test-repo-production", public_ipv4: "1.2.3.4", status: "running"
      )
      compute_client = config.compute_config.client
      compute_client.define_singleton_method(:list_servers) { [server] }

      found = runner.find_server(config)
      assert_equal "1.2.3.4", found.public_ipv4
    end
  end

  def test_find_server_by_name_appends_to_prefix
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      config = runner.load_config
      config.git { |g| g.repo = "owner/test-repo" }

      worker = RbrunCore::Clients::Compute::Types::Server.new(
        name: "test-repo-production-worker-1", public_ipv4: "5.6.7.8", status: "running"
      )
      master = RbrunCore::Clients::Compute::Types::Server.new(
        name: "test-repo-production", public_ipv4: "1.2.3.4", status: "running"
      )
      compute_client = config.compute_config.client
      compute_client.define_singleton_method(:list_servers) { [master, worker] }

      found = runner.find_server(config, "worker-1")
      assert_equal "5.6.7.8", found.public_ipv4
    end
  end

  # ── --config / --folder resolution ──

  def test_relative_config_resolves_against_folder_not_cwd
    # Config lives in folder_dir, CWD is somewhere else entirely
    with_config_file do |_path, folder_dir|
      Dir.mktmpdir do |other_dir|
        Dir.chdir(other_dir) do
          runner = RbrunCli::Runner.new(config_path: "config.yaml", folder: folder_dir)
          config = runner.load_config

          assert_instance_of RbrunCore::Configuration, config
        end
      end
    end
  end

  def test_absolute_config_works_regardless_of_folder
    with_config_file do |abs_path, _dir|
      Dir.mktmpdir do |unrelated_folder|
        runner = RbrunCli::Runner.new(config_path: abs_path, folder: unrelated_folder)
        config = runner.load_config

        assert_instance_of RbrunCore::Configuration, config
      end
    end
  end

  def test_relative_config_without_folder_resolves_against_cwd
    with_config_file do |_path, dir|
      Dir.chdir(dir) do
        runner = RbrunCli::Runner.new(config_path: "config.yaml")
        config = runner.load_config

        assert_instance_of RbrunCore::Configuration, config
      end
    end
  end

  def test_relative_config_with_wrong_folder_raises
    Dir.mktmpdir do |empty_dir|
      runner = RbrunCli::Runner.new(config_path: "config.yaml", folder: empty_dir)

      assert_raises(Errno::ENOENT) { runner.load_config }
    end
  end

  # ── CWD restoration ──

  def test_load_config_restores_cwd
    with_config_file do |path, dir|
      original_cwd = Dir.pwd
      runner = RbrunCli::Runner.new(config_path: path, folder: dir)
      runner.load_config

      assert_equal original_cwd, Dir.pwd
    end
  end

  def test_build_context_restores_cwd
    with_config_file do |path, dir|
      original_cwd = Dir.pwd
      runner = RbrunCli::Runner.new(config_path: path, folder: dir)
      runner.build_context(target: :production)

      assert_equal original_cwd, Dir.pwd
    end
  end

  def test_load_config_restores_cwd_even_on_error
    Dir.mktmpdir do |dir|
      bad_path = File.join(dir, "missing.yaml")
      original_cwd = Dir.pwd
      runner = RbrunCli::Runner.new(config_path: bad_path, folder: dir)

      assert_raises(Errno::ENOENT) { runner.load_config }
      assert_equal original_cwd, Dir.pwd
    end
  end

  # ── build_operational_context ──

  def test_build_operational_context_sets_server_ip_and_ssh_keys
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      config = runner.load_config
      config.git { |g| g.repo = "owner/test-repo" }

      server = RbrunCore::Clients::Compute::Types::Server.new(
        name: "test-repo-production", public_ipv4: "1.2.3.4", status: "running"
      )

      # Stub both load_config and find_server via the runner
      runner.define_singleton_method(:load_config) { config }
      compute_client = config.compute_config.client
      compute_client.define_singleton_method(:list_servers) { [server] }

      ctx = runner.build_operational_context
      assert_equal "1.2.3.4", ctx.server_ip
      assert_equal TEST_SSH_KEY.private_key, ctx.ssh_private_key
    end
  end

  def test_build_kubectl_returns_kubectl_instance
    with_config_file do |path, _dir|
      runner = RbrunCli::Runner.new(config_path: path)
      ctx = build_context
      ctx.server_ip = "1.2.3.4"
      ctx.ssh_private_key = TEST_SSH_KEY.private_key

      kubectl = runner.build_kubectl(ctx)
      assert_instance_of RbrunCore::Clients::Kubectl, kubectl
    end
  end

  private

    def with_config_file
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "config.yaml")
        File.write(config_path, YAML.dump(
          "target" => "production",
          "compute" => {
            "provider" => "hetzner",
            "api_key" => "test-key",
            "ssh_key_path" => TEST_SSH_KEY_PATH,
            "server" => "cpx11"
          }
        ))
        yield config_path, dir
      end
    end
end
