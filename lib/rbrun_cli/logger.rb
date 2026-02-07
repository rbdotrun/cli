# frozen_string_literal: true

module RbrunCli
  # Logger with multi-destination output for CLI deploy commands.
  #
  # Writes formatted output to stdout and optionally to a file.
  # Handles color/TTY detection per-destination.
  #
  # Usage:
  #   logger = RbrunCli::Logger.new
  #   logger = RbrunCli::Logger.new(file: "/var/log/deploy.log")
  #   logger = RbrunCli::Logger.new(color: false)
  #
  #   logger.log(:server, "Creating myserver")
  #
  class Logger
    COLORS = {
      cyan: "\e[36m",
      reset: "\e[0m"
    }.freeze

    def initialize(stdout: $stdout, file: nil, color: :auto)
      @outputs = []
      add_output(stdout, color:) if stdout
      add_output(File.open(file, "a"), color: false) if file
    end

    # Log a status message with category prefix.
    def log(category, message)
      write("[#{category}] #{message}")
    end

    # Close any file handles opened by the logger.
    def close
      @outputs.each do |output|
        output.io.close if output.io.respond_to?(:close) && output.io != $stdout && output.io != $stderr
      end
    end

    private

      def add_output(io, color:)
        use_color = case color
        when :auto then io.respond_to?(:tty?) && io.tty?
        else color
        end
        @outputs << Output.new(io, color: use_color)
      end

      def write(line)
        @outputs.each { |o| o.puts(line) }
      end

      # Internal output destination wrapper.
      class Output
        attr_reader :io

        def initialize(io, color:)
          @io = io
          @color = color
        end

        def puts(line)
          formatted = @color ? colorize(line) : line
          @io.puts(formatted)
          @io.flush if @io.respond_to?(:flush)
        end

        private

          def colorize(line)
            line.sub(/\A(\[[^\]]+\])/) { "#{COLORS[:cyan]}#{$1}#{COLORS[:reset]}" }
          end
      end
  end
end
