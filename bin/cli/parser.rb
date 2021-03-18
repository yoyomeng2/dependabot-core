# frozen_string_literal: true

require "optparse"

Options = Struct.new(:repo, :dependency_names, :dry_run, :provider, :security_updates_only) do
  alias_method :dry_run?, :dry_run
  alias_method :security_updates_only?, :security_updates_only
end

module CLI
  class Parser
    def self.parse(options)
      args = Options.new(options.first, nil, false, "github", false)

      opt_parser = OptionParser.new do |opts|
        opts.banner = "usage: bin/update REPO/REPO"

        opts.on("--dep DEPENDENCIES", "Comma separated list of dependencies to update") do |value|
          args.dependency_names = value.split(",").map { |o| o.strip.downcase }
        end

        opts.on("--dry-run", "Dry run the update without creating a pull request") do |_value|
          args.dry_run = true
        end

        opts.on("--security-updates-only", "Only update vulnerable dependencies") do |_value|
          args.security_updates_only = true
        end

        opts.on("--provider PROVIDER", "SCM provider e.g. github, azure, bitbucket") do |value|
          args.provider = value
        end

        opts.on("-h", "--help", "Prints help") do
          puts opts
          exit
        end
      end

      # Print help
      options << "-h" unless args.repo

      opt_parser.parse!(options)
      return args
    end
  end
end
