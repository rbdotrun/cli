# frozen_string_literal: true

require "tty-spinner"

module RbrunCli
  class StepPresenter
    STREAM_LABELS = [ "Image", "Manifests" ].freeze
    INDENT = "  "
    LABEL_WIDTH = 10

    def initialize(output: $stdout)
      @output = output
      @tty = output.respond_to?(:tty?) && output.tty?
      @spinners = {}
      @has_message = {}
    end

    def call(label, status, message = nil)
      if STREAM_LABELS.include?(label)
        handle_stream(label, status)
      else
        handle_step(label, status, message)
      end
    end

    private

      def handle_stream(label, status)
        case status
        when :in_progress
          stop_all_spinners
          @output.puts ""
          @output.puts "#{INDENT}#{label}..."
        when :done
          @output.puts ""
        end
      end

      def handle_step(label, status, message)
        case status
        when :in_progress
          start_spinner(label, message)
        when :done
          stop_spinner(label, message)
        end
      end

      def start_spinner(label, message)
        padded = label.to_s.ljust(LABEL_WIDTH)
        @has_message[label] = !message.nil?
        format = "#{INDENT}#{padded} :spinner #{message || ''}"

        if @tty
          spinner = TTY::Spinner.new(format.rstrip, output: @output, format: :dots)
          @spinners[label] = spinner
          spinner.auto_spin
        else
          text = "#{INDENT}#{padded} ... #{message || ''}"
          @output.puts text.rstrip
        end
      end

      def stop_spinner(label, message)
        padded = label.to_s.ljust(LABEL_WIDTH)

        if @tty && @spinners[label]
          if @has_message[label]
            @spinners[label].success
          else
            @spinners[label].success(message || "done")
          end
          @spinners.delete(label)
          @has_message.delete(label)
        else
          done_text = message || "done"
          @output.puts "#{INDENT}#{padded} #{done_text}"
        end
      end

      def stop_all_spinners
        @spinners.each_value(&:stop)
        @spinners.clear
        @has_message.clear
      end
  end
end
