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

  class MockKubectl
    def initialize(pods)
      @pods = pods
    end

    def get_pods
      @pods
    end
  end
end
