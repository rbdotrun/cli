# frozen_string_literal: true

module RbrunCli
  class StepPresenter
    STEPS = {
      # Infrastructure
      RbrunCore::Step::Id::CREATE_FIREWALL => { label: "Firewall", progress: "verifying", done: "created", existing: "existing" },
      RbrunCore::Step::Id::CREATE_NETWORK  => { label: "Network", progress: "verifying", done: "created", existing: "existing" },
      RbrunCore::Step::Id::CREATE_SERVER   => { label: "Server", progress: "creating", done: ->(msg) { msg ? "created (#{msg})" : "created" } },
      RbrunCore::Step::Id::WAIT_SSH        => { label: "SSH", progress: "waiting", done: "ready" },

      # K3s
      RbrunCore::Step::Id::WAIT_CLOUD_INIT      => { label: "Cloud-init", progress: "waiting", done: "ready" },
      RbrunCore::Step::Id::DISCOVER_NETWORK     => { label: "Network", progress: "discovering", done: ->(msg) { msg || "discovered" } },
      RbrunCore::Step::Id::CONFIGURE_REGISTRIES => { label: "Registries", progress: "configuring", done: "configured" },
      RbrunCore::Step::Id::INSTALL_K3S          => { label: "K3s", progress: "installing", done: "installed", existing: "installed" },
      RbrunCore::Step::Id::SETUP_KUBECONFIG     => { label: "Kubeconfig", progress: "saving", done: "saved" },
      RbrunCore::Step::Id::DEPLOY_INGRESS       => { label: "Ingress", progress: "deploying", done: "deployed" },
      RbrunCore::Step::Id::LABEL_NODES          => { label: "Nodes", progress: "labeling", done: "labeled" },
      RbrunCore::Step::Id::RETRIEVE_TOKEN       => { label: "Token", progress: "retrieving", done: "retrieved" },
      RbrunCore::Step::Id::SETUP_WORKERS        => { label: "Workers", progress: "joining", done: "joined" },

      # Deploy
      RbrunCore::Step::Id::SETUP_REGISTRY     => { label: "Registry", progress: "deploying", done: "deployed", existing: "exists" },
      RbrunCore::Step::Id::PROVISION_VOLUMES  => { label: "Volumes", progress: "provisioning", done: "provisioned" },
      RbrunCore::Step::Id::SETUP_TUNNEL       => { label: "Tunnel", progress: "creating", done: "created", existing: "exists" },
      RbrunCore::Step::Id::BUILD_IMAGE        => { label: "Building image", stream: true },
      RbrunCore::Step::Id::DEPLOY_MANIFESTS   => { label: "Deploying", stream: true },
      RbrunCore::Step::Id::WAIT_ROLLOUT       => { skip: true },
      RbrunCore::Step::Id::CLEANUP_IMAGES     => { label: "Images", progress: "cleaning", done: "cleaned" },

      # Destroy
      RbrunCore::Step::Id::CLEANUP_TUNNEL  => { label: "Tunnel", progress: "deleting", done: "deleted" },
      RbrunCore::Step::Id::STOP_CONTAINERS => { label: "Containers", progress: "stopping", done: "stopped" },
      RbrunCore::Step::Id::DETACH_VOLUMES  => { label: "Volumes", progress: "detaching", done: "detached" },
      RbrunCore::Step::Id::DELETE_SERVERS  => { label: "Servers", progress: "deleting", done: "deleted" },
      RbrunCore::Step::Id::DELETE_VOLUMES  => { label: "Volumes", progress: "deleting", done: "deleted" },
      RbrunCore::Step::Id::DELETE_FIREWALL => { label: "Firewall", progress: "deleting", done: "deleted" },
      RbrunCore::Step::Id::DELETE_NETWORK  => { label: "Network", progress: "deleting", done: "deleted" },

      # Sandbox
      RbrunCore::Step::Id::INSTALL_PACKAGES    => { label: "Packages", progress: "installing", done: "installed" },
      RbrunCore::Step::Id::INSTALL_DOCKER      => { label: "Docker", progress: "starting", done: "started" },
      RbrunCore::Step::Id::INSTALL_NODE        => { label: "Node", progress: "installing", done: "installed" },
      RbrunCore::Step::Id::INSTALL_CLAUDE_CODE => { label: "Claude Code", progress: "installing", done: "installed" },
      RbrunCore::Step::Id::INSTALL_GH_CLI      => { label: "GitHub CLI", progress: "installing", done: "installed" },
      RbrunCore::Step::Id::CONFIGURE_GIT_AUTH  => { label: "Git auth", progress: "configuring", done: "configured" },
      RbrunCore::Step::Id::CLONE_REPO          => { label: "Repo", progress: "cloning", done: "cloned" },
      RbrunCore::Step::Id::CHECKOUT_BRANCH     => { label: "Branch", progress: "checking out", done: ->(msg) { msg || "checked out" } },
      RbrunCore::Step::Id::WRITE_ENV           => { label: "Environment", progress: "writing", done: "written" },
      RbrunCore::Step::Id::GENERATE_COMPOSE    => { label: "Compose", progress: "generating", done: "generated" },
      RbrunCore::Step::Id::START_COMPOSE       => { label: "Compose", progress: "starting", done: "running" }
    }.freeze

    def initialize(output: $stdout)
      @output = output
      @tty = output.respond_to?(:tty?) && output.tty?
      @current_line = nil
    end

    def call(step_id, status, message: nil, parent: nil)
      config = STEPS[step_id]
      return unless config
      return if config[:skip]

      label = config[:label]
      return unless label

      if config[:stream]
        handle_stream(label, status)
      else
        handle_step(config, status, message)
      end
    end

    private

      def handle_stream(label, status)
        case status
        when RbrunCore::Step::IN_PROGRESS
          finish_line if @current_line
          @output.puts ""
          @output.puts "#{label}..."
        when RbrunCore::Step::DONE
          @output.puts ""
        end
      end

      def handle_step(config, status, message)
        label = config[:label]

        case status
        when RbrunCore::Step::IN_PROGRESS
          finish_line if @current_line
          text = "#{label}: #{config[:progress]}..."
          @current_line = label
          if @tty
            @output.print text
            @output.flush
          else
            @output.puts text
          end

        when RbrunCore::Step::DONE
          done_text = resolve_done(config, message)
          text = "#{label}: #{done_text}"

          if @tty && @current_line == label
            @output.print "\r\e[K#{text}\n"
          else
            finish_line if @current_line && @current_line != label
            @output.puts text
          end
          @current_line = nil
        end
      end

      def resolve_done(config, message)
        # Check for "existing" variant
        if message == "existing" && config[:existing]
          return config[:existing]
        end

        done = config[:done]
        if done.respond_to?(:call)
          done.call(message)
        else
          done
        end
      end

      def finish_line
        @output.puts "" if @tty
        @current_line = nil
      end
  end
end
