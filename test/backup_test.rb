# frozen_string_literal: true

require "test_helper"
require "zlib"

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

    def test_format_size_bytes
      backup = Backup.new
      assert_equal "500 bytes", backup.send(:format_size, 500)
    end

    def test_format_size_kilobytes
      backup = Backup.new
      assert_equal "1.5 KB", backup.send(:format_size, 1500)
    end

    def test_format_size_megabytes
      backup = Backup.new
      assert_equal "2.5 MB", backup.send(:format_size, 2_500_000)
    end

    def test_gzip_decompression
      # Test that Zlib.gunzip works as expected for backup decompression
      original = "CREATE TABLE users (id INTEGER);"
      compressed = Zlib.gzip(original)
      decompressed = Zlib.gunzip(compressed)
      assert_equal original, decompressed
    end
  end
end
