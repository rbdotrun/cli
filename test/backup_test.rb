# frozen_string_literal: true

require "test_helper"

module RbrunCli
  class BackupTest < Minitest::Test
    def test_uses_backend_bucket_naming
      # Verify the constant exists and has correct value
      assert_equal "postgres-backups/", RbrunCore::Naming::POSTGRES_BACKUPS_PREFIX
    end

    def test_uses_backend_bucket_method
      bucket = RbrunCore::Naming.backend_bucket("myapp", "staging")
      assert_equal "myapp-staging-backend", bucket
    end
  end
end
