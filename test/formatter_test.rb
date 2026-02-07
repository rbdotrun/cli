# frozen_string_literal: true

require "test_helper"

class FormatterTest < Minitest::Test
  def test_log_outputs_category_and_message
    text = capture_output do |out|
      RbrunCli::Formatter.new(output: out).log("deploy", "Starting deployment")
    end

    assert_equal "[deploy] Starting deployment\n", text
  end

  def test_state_change_outputs_nothing
    text = capture_output do |out|
      RbrunCli::Formatter.new(output: out).state_change(:deployed)
    end

    assert_empty text
  end

  def test_error_outputs_error_message
    text = capture_output do |out|
      RbrunCli::Formatter.new(output: out).error("Something went wrong")
    end

    assert_equal "Error: Something went wrong\n", text
  end

  def test_summary_shows_deployed_message
    text = capture_output do |out|
      ctx = build_context
      ctx.state = :deployed
      ctx.server_ip = "1.2.3.4"
      RbrunCli::Formatter.new(output: out).summary(ctx)
    end

    assert_includes text, "Deployed successfully"
    assert_includes text, "1.2.3.4"
  end

  def test_status_table_renders_headers
    text = render_status_table

    assert_includes text, "NAME"
    assert_includes text, "IP"
    assert_includes text, "STATUS"
  end

  def test_status_table_renders_server_data
    text = render_status_table

    assert_includes text, "myapp-web"
    assert_includes text, "1.2.3.4"
  end

  def test_status_table_empty_produces_no_output
    text = capture_output do |out|
      RbrunCli::Formatter.new(output: out).status_table([])
    end

    assert_empty text
  end

  private

    def render_status_table
      capture_output do |out|
        servers = [
          RbrunCore::Clients::Compute::Types::Server.new(
            name: "myapp-web", public_ipv4: "1.2.3.4", status: "running", instance_type: "cpx11"
          )
        ]
        RbrunCli::Formatter.new(output: out).status_table(servers)
      end
    end
end
