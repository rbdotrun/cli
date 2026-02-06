# frozen_string_literal: true

module RbrunCli
  # Displays rollout progress using TTY::Spinner::Multi.
  #
  # Usage:
  #   progress = RolloutProgress.new
  #   progress.call(:start, ["myapp-web", "myapp-worker"])
  #   progress.call(:update, { name: "myapp-web", ready: 1, desired: 2, ready?: false })
  #   progress.call(:done, nil)
  #
  class RolloutProgress
    SPINNER_FORMAT = :dots
    SUCCESS_MARK = "\e[32m\u2713\e[0m"  # Green checkmark
    ERROR_MARK = "\e[31m\u2717\e[0m"    # Red X

    def initialize(output: $stdout)
      @output = output
      @tty = output.respond_to?(:tty?) && output.tty?
      @multi = nil
      @spinners = {}
      @short_names = {}
    end

    def call(event, data)
      case event
      when :start
        start_spinners(data)
      when :update
        update_spinner(data)
      when :done
        finish_all
      end
    end

    private

      def start_spinners(deployments)
        if @tty
          @multi = TTY::Spinner::Multi.new(
            "[:spinner] Rolling out...",
            format: SPINNER_FORMAT,
            output: @output
          )

          deployments.each do |name|
            short_name = name.split("-").last(2).join("-")
            @short_names[name] = short_name
            # Empty format - we'll set the full message on success
            @spinners[name] = @multi.register(
              "[:spinner] #{short_name}",
              format: SPINNER_FORMAT,
              success_mark: SUCCESS_MARK,
              error_mark: ERROR_MARK
            )
          end

          @multi.auto_spin
        else
          # Non-TTY fallback: just log that we're starting
          @output.puts "[wait_rollout] Waiting for #{deployments.length} deployment(s)..."
        end
      end

      def update_spinner(status)
        return unless status

        name = status[:name]
        ready = status[:ready] || 0
        desired = status[:desired] || 0
        is_ready = status[:ready?]

        if @tty && @spinners[name]
          spinner = @spinners[name]

          if is_ready
            spinner.success("(#{ready}/#{desired})")
          end
          # Don't update while spinning - tty-spinner token updates are unreliable
        elsif !@tty && is_ready
          @output.puts "[wait_rollout] #{name}: #{ready}/#{desired} \u2713"
        end
      end

      def finish_all
        return unless @tty && @multi

        # Mark any remaining spinners as done
        @spinners.each_value do |spinner|
          spinner.success unless spinner.done?
        end
      end
  end
end
