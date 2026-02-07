# frozen_string_literal: true

require "test_helper"

class RolloutProgressTest < Minitest::Test
  def test_renders_pods_table
    mock_kubectl = MockKubectl.new([
      { name: "web-abc", app: "myapp-web", ready_count: 1, total: 1, status: "Running", ready: true }
    ])

    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:wait, { kubectl: mock_kubectl, deployments: [ "myapp-web" ] })
    end

    assert_includes text, "web-abc"
    assert_includes text, "1/1"
    assert_includes text, "Running"
  end

  def test_ignores_other_events
    text = capture_output do |out|
      progress = RbrunCli::RolloutProgress.new(output: out)
      progress.call(:start, nil)
    end

    assert_equal "", text
  end

  def test_timeout_prints_logs_from_failing_pods
    mock_kubectl = MockKubectl.new(
      [ { name: "web-abc", app: "myapp-web", ready_count: 0, total: 1, status: "CrashLoopBackOff", ready: false } ],
      logs: { "myapp-web" => "Error: something went wrong\nStack trace here" }
    )

    text, _error = capture_timeout_output(mock_kubectl, [ "myapp-web" ])

    assert_includes text, "Logs from myapp-web:"
    assert_includes text, "Error: something went wrong"
  end

  def test_timeout_prints_inspect_command
    mock_kubectl = MockKubectl.new(
      [ { name: "web-abc", app: "myapp-web", ready_count: 0, total: 1, status: "CrashLoopBackOff", ready: false } ],
      logs: {}
    )

    text, _error = capture_timeout_output(mock_kubectl, [ "myapp-web" ])

    assert_includes text, "Inspect with:"
    assert_includes text, "rbrun release logs --process web"
  end

  def test_timeout_error_message_lists_stuck_pods
    mock_kubectl = MockKubectl.new(
      [ { name: "web-abc", app: "myapp-web", ready_count: 0, total: 1, status: "CrashLoopBackOff", ready: false } ],
      logs: {}
    )

    _text, error = capture_timeout_output(mock_kubectl, [ "myapp-web" ])

    assert_includes error.message, "web-abc - CrashLoopBackOff"
    refute_includes error.message, "Rollout timed out"
  end

  private

    def capture_timeout_output(kubectl, deployments)
      out = StringIO.new
      progress = RbrunCli::RolloutProgress.new(output: out)
      error = nil
      # Temporarily set timeout to 0 to trigger immediate timeout
      original_timeout = RbrunCli::RolloutProgress::TIMEOUT
      RbrunCli::RolloutProgress.send(:remove_const, :TIMEOUT)
      RbrunCli::RolloutProgress.const_set(:TIMEOUT, 0)
      begin
        progress.call(:wait, { kubectl:, deployments: })
      rescue RbrunCore::Error::Standard => e
        error = e
      ensure
        RbrunCli::RolloutProgress.send(:remove_const, :TIMEOUT)
        RbrunCli::RolloutProgress.const_set(:TIMEOUT, original_timeout)
      end
      [ out.string, error ]
    end

    class MockKubectl
      def initialize(pods, logs: {})
        @pods = pods
        @logs = logs
      end

      def get_pods
        @pods
      end

      def logs(deployment, tail: 100)
        output = @logs[deployment] || "(no logs)"
        { output:, exit_code: 0 }
      end
    end
end
