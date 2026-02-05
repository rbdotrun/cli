# frozen_string_literal: true

module RbrunCli
  class Formatter
    STATE_COLORS = {
      deployed: :green,
      running: :green,
      provisioning: :yellow,
      destroying: :yellow,
      failed: :red,
      pending: :gray,
      destroyed: :gray
    }.freeze

    ANSI = {
      cyan: "\e[36m",
      green: "\e[32m",
      yellow: "\e[33m",
      red: "\e[31m",
      gray: "\e[90m",
      bold: "\e[1m",
      reset: "\e[0m"
    }.freeze

    def initialize(output: $stdout)
      @output = output
      @tty = output.respond_to?(:tty?) && output.tty?
    end

    def log(category, message)
      if @tty
        @output.puts "#{colorize("[#{category}]", :cyan)} #{message}"
      else
        @output.puts "[#{category}] #{message}"
      end
    end

    def state_change(state)
      state = state.to_sym
      color = STATE_COLORS.fetch(state, :gray)
      label = state.to_s

      if @tty
        @output.puts "--> State: #{colorize(label, color)}"
      else
        @output.puts "--> State: #{label}"
      end
    end

    def summary(ctx)
      state_change(ctx.state)
      @output.puts "Slug: #{ctx.slug}" if ctx.target == :sandbox
      @output.puts "Prefix: #{ctx.prefix}"
      @output.puts "Server: #{ctx.server_ip}" if ctx.server_ip

      status_table(ctx.servers.values) if ctx.servers&.any?
    end

    def status_table(servers)
      return if servers.empty?

      headers = %w[NAME IP STATUS TYPE]
      rows = servers.map do |s|
        [ s.name, s.public_ipv4 || "-", s.status || "-", s.instance_type || "-" ]
      end

      widths = headers.each_with_index.map do |h, i|
        [ h.length, *rows.map { |r| r[i].to_s.length } ].max
      end

      header_line = headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join("  ")
      separator = widths.map { |w| "-" * w }.join("  ")

      if @tty
        @output.puts colorize(header_line, :bold)
      else
        @output.puts header_line
      end
      @output.puts separator

      rows.each do |row|
        @output.puts row.each_with_index.map { |col, i| col.to_s.ljust(widths[i]) }.join("  ")
      end
    end

    def error(message)
      if @tty
        @output.puts "#{colorize("Error:", :red)} #{message}"
      else
        @output.puts "Error: #{message}"
      end
    end

    private

      def colorize(text, color)
        "#{ANSI[color]}#{text}#{ANSI[:reset]}"
      end
  end
end
