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

      if ctx.servers&.any?
        rows = ctx.servers.map do |name, info|
          [ "#{ctx.prefix}-#{name}", info[:ip] || "-", info[:group] || "-" ]
        end
        server_summary_table(rows)
      end
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

    def resources(compute_provider:, compute_inventory:, cloudflare_inventory: nil)
      section(compute_provider.capitalize)

      compute_inventory.each do |resource_type, items|
        label = resource_type.to_s.tr("_", " ").capitalize
        if items.empty?
          @output.puts "  #{label}: (none)"
        else
          @output.puts "  #{label}: #{items.length}"
          items.each { |item| @output.puts "    - #{format_resource(item)}" }
        end
      end

      return unless cloudflare_inventory

      section("Cloudflare")

      tunnels = cloudflare_inventory[:tunnels] || []
      if tunnels.empty?
        @output.puts "  Tunnels: (none)"
      else
        @output.puts "  Tunnels: #{tunnels.length}"
        tunnels.each { |t| @output.puts "    - #{t[:name]} (#{t[:status]})" }
      end

      (cloudflare_inventory[:zones] || []).each do |zone|
        @output.puts "  Zone: #{zone[:name]} (#{zone[:status]})"
        records = zone[:dns_records] || []
        if records.empty?
          @output.puts "    DNS Records: (none)"
        else
          @output.puts "    DNS Records: #{records.length}"
          records.each { |r| @output.puts "      #{r[:type].ljust(6)} #{r[:name]} → #{r[:content]}" }
        end
      end
    end

    def server_summary_table(rows)
      return if rows.empty?

      headers = %w[NAME IP GROUP]
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

    def topology(data)
      @output.puts header("Cluster Topology")
      @output.puts

      # Nodes section
      @output.puts subsection("Nodes")
      data[:nodes].each do |node|
        status = node[:ready] ? colorize("Ready", :green) : colorize("NotReady", :red)
        roles = node[:roles].empty? ? "worker" : node[:roles].join(", ")
        @output.puts "  #{colorize(node[:name], :bold)} [#{status}] (#{roles})"
      end
      @output.puts

      # Placement section (node -> pods)
      @output.puts subsection("Pod Placement")
      data[:placement].each do |node_name, pods|
        @output.puts "  #{colorize(node_name, :bold)}:"
        if pods.empty?
          @output.puts "    (no pods)"
        else
          pods.each do |pod|
            status = pod[:ready] ? colorize("*", :green) : colorize("o", :red)
            app = pod[:app] || "unknown"
            @output.puts "    #{status} #{pod[:name]} (#{app})"
          end
        end
      end
      @output.puts

      # Summary
      @output.puts subsection("Summary")
      ready_nodes = data[:nodes].count { |n| n[:ready] }
      ready_pods = data[:pods].count { |p| p[:ready] }
      total_pods = data[:pods].count
      @output.puts "  Nodes: #{ready_nodes}/#{data[:nodes].count} ready"
      @output.puts "  Pods:  #{ready_pods}/#{total_pods} ready"
    end

    private

      def header(text)
        if @tty
          "\n#{colorize("=" * 50, :bold)}\n#{colorize(text, :bold)}\n#{colorize("=" * 50, :bold)}"
        else
          "\n#{"=" * 50}\n#{text}\n#{"=" * 50}"
        end
      end

      def subsection(text)
        if @tty
          colorize("-- #{text} --", :bold)
        else
          "-- #{text} --"
        end
      end

      def section(title)
        if @tty
          @output.puts colorize(title, :bold)
        else
          @output.puts title
        end
      end

      def format_resource(item)
        parts = [ item.name ]
        parts << item.status if item.respond_to?(:status) && item.status
        parts << item.public_ipv4 if item.respond_to?(:public_ipv4) && item.public_ipv4
        parts << "#{item.size_gb}GB" if item.respond_to?(:size_gb) && item.size_gb
        parts << item.location if item.respond_to?(:location) && item.location
        parts.join(" | ")
      end

      def colorize(text, color)
        "#{ANSI[color]}#{text}#{ANSI[:reset]}"
      end
  end
end
