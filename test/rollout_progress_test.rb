# frozen_string_literal: true

require "test_helper"

class RolloutProgressTest < Minitest::Test
  def test_start_logs_deployment_count_in_non_tty_mode
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:start, %w[myapp-web myapp-worker])
    end

    assert_includes text, "Waiting for 2 deployment(s)"
  end

  def test_update_logs_replica_status_when_ready_in_non_tty_mode
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:update, { name: "myapp-web", ready: 2, desired: 2, ready?: true })
    end

    assert_includes text, "myapp-web: 2/2"
    assert_includes text, "\u2713"
  end

  def test_update_does_not_log_when_not_ready_in_non_tty_mode
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:update, { name: "myapp-web", ready: 1, desired: 3, ready?: false })
    end

    assert_equal "", text
  end

  def test_full_sequence_in_non_tty_mode
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:start, %w[myapp-web])
      progress.call(:update, { name: "myapp-web", ready: 0, desired: 2, ready?: false })
      progress.call(:update, { name: "myapp-web", ready: 1, desired: 2, ready?: false })
      progress.call(:update, { name: "myapp-web", ready: 2, desired: 2, ready?: true })
      progress.call(:done, nil)
    end

    assert_includes text, "Waiting for 1 deployment(s)"
    assert_includes text, "myapp-web: 2/2"
  end

  def test_handles_nil_status_gracefully
    # Should not raise
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:update, nil)
    end

    assert_equal "", text
  end

  def test_handles_missing_status_fields_when_ready
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:update, { name: "myapp-web", ready?: true })
    end

    assert_includes text, "myapp-web: 0/0"
  end
end
