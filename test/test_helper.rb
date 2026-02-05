# frozen_string_literal: true

require "bundler/setup"
require "rbrun_cli"
require "minitest/autorun"
require "sshkey"

# Pre-generate SSH keypair once (avoids 200-500ms per test)
TEST_SSH_KEY = SSHKey.generate(type: "RSA", bits: 4096, comment: "rbrun-cli-test")
TEST_SSH_KEY_DIR = Dir.mktmpdir("rbrun-cli-test-keys")
TEST_SSH_KEY_PATH = File.join(TEST_SSH_KEY_DIR, "id_rsa")
File.write(TEST_SSH_KEY_PATH, TEST_SSH_KEY.private_key)
File.write("#{TEST_SSH_KEY_PATH}.pub", TEST_SSH_KEY.ssh_public_key)
Minitest.after_run { FileUtils.rm_rf(TEST_SSH_KEY_DIR) }

module RbrunCliTestSetup
  private

    def build_config(target: nil)
      config = RbrunCore::Configuration.new
      config.target = target
      config.compute(:hetzner) do |c|
        c.api_key = "test-hetzner-key"
        c.ssh_key_path = TEST_SSH_KEY_PATH
        c.server = "cpx11"
      end
      config.cloudflare do |cf|
        cf.api_token = "test-cloudflare-key"
        cf.account_id = "test-account-id"
        cf.domain = "test.dev"
      end
      config.git do |g|
        g.pat = "test-github-token"
        g.repo = "owner/test-repo"
      end
      config
    end

    def build_context(target: :production, **overrides)
      RbrunCore::Context.new(config: build_config, target:, **overrides)
    end

    def capture_output
      output = StringIO.new
      yield output
      output.string
    end
end

module Minitest
  class Test
    include RbrunCliTestSetup
  end
end
