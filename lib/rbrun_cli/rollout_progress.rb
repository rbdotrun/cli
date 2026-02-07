# frozen_string_literal: true

module RbrunCli
  class RolloutProgress
    TIMEOUT = 300
    INTERVAL = 2

    def initialize(output: $stdout)
      @output = output
      @tty = output.respond_to?(:tty?) && output.tty?
      @last_line_count = 0
    end

    def call(event, data)
      return unless event == :wait && data

      kubectl = data[:kubectl]
      deployments = data[:deployments]

      wait_for_pods(kubectl, deployments)
    end

    private

      def wait_for_pods(kubectl, deployments)
        deadline = Time.now + TIMEOUT

        loop do
          pods = kubectl.get_pods
          relevant = pods.select { |p| deployments.any? { |d| p[:app]&.include?(d) } }

          render(relevant)

          all_ready = deployments.all? do |dep|
            dep_pods = relevant.select { |p| p[:app]&.include?(dep) }
            dep_pods.any? && dep_pods.all? { |p| p[:ready] }
          end

          break if all_ready

          if Time.now >= deadline
            stuck = relevant.reject { |p| p[:ready] }
            print_failure_details(kubectl, stuck, deployments)
            raise RbrunCore::Error::Standard, format_stuck(stuck)
          end

          sleep INTERVAL
        end
      end

      def render(pods)
        lines = []
        lines << "#{"NAME".ljust(55)}#{"READY".ljust(8)}STATUS"

        pods.each do |p|
          ready_str = "#{p[:ready_count]}/#{p[:total]}"
          status = p[:ready] ? "\e[32m#{p[:status]}\e[0m" : p[:status]
          lines << "#{p[:name][0, 54].ljust(55)}#{ready_str.ljust(8)}#{status}"
        end

        if @tty && @last_line_count > 0
          @output.print "\e[#{@last_line_count}A\e[J"
        end

        lines.each { |l| @output.puts l }
        @last_line_count = lines.size
      end

      def format_stuck(pods)
        pods.map { |p| "  #{p[:name]} - #{p[:status]}" }.join("\n")
      end

      def print_failure_details(kubectl, stuck_pods, deployments)
        # Find unique failing deployments
        failing_deployments = stuck_pods.map { |p| p[:app] }.compact.uniq

        failing_deployments.each do |deployment|
          @output.puts "\n\e[33mLogs from #{deployment}:\e[0m"
          begin
            result = kubectl.logs(deployment, tail: 50)
            result[:output].each_line { |line| @output.puts "  #{line}" }
          rescue StandardError => e
            @output.puts "  (could not fetch logs: #{e.message})"
          end
        end

        @output.puts "\n\e[36mInspect with:\e[0m"
        failing_deployments.each do |deployment|
          @output.puts "  rbrun release logs --process #{deployment.split('-').last}"
        end
        @output.puts ""
      end
  end
end
