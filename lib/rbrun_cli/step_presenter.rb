# frozen_string_literal: true

module RbrunCli
  class StepPresenter
    STREAM_LABELS = [ "Image", "Manifests" ].freeze

    def initialize(output: $stdout)
      @output = output
      @tty = output.respond_to?(:tty?) && output.tty?
      @current_label = nil
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
          finish_line if @current_label
          @output.puts ""
          @output.puts "#{label}..."
        when :done
          @output.puts ""
        end
      end

      def handle_step(label, status, message)
        case status
        when :in_progress
          finish_line if @current_label
          text = "#{label}: #{message || '...'}"
          @current_label = label
          if @tty
            @output.print text
            @output.flush
          else
            @output.puts text
          end

        when :done
          text = "#{label}: #{message || 'done'}"

          if @tty && @current_label == label
            @output.print "\r\e[K#{text}\n"
          else
            finish_line if @current_label && @current_label != label
            @output.puts text
          end
          @current_label = nil
        end
      end

      def finish_line
        @output.puts "" if @tty
        @current_label = nil
      end
  end
end
