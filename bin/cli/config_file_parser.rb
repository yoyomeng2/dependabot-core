# frozen_string_literal: true

require "yaml"
require "json"
require "json-schema"
require "dependabot/utils"

module CLI
  class ConfigFileParser
    class Unparseable < StandardError; end

    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.map { |e| e.fetch(:message) }.join("\n"))
      end
    end

    PACKAGE_MANAGER_LOOKUP = {
      "bundler" => "bundler",
      "cargo" => "cargo",
      "composer" => "composer",
      "docker" => "docker",
      "elm" => "elm",
      "github-actions" => "github_actions",
      "gitsubmodule" => "submodules",
      "gomod" => "go_modules",
      "gradle" => "gradle",
      "maven" => "maven",
      "mix" => "hex",
      "nuget" => "nuget",
      "npm" => "npm_and_yarn",
      "pip" => "pip",
      "terraform" => "terraform",
    }.freeze

    REQUIREMENT_UPDATE_STRATEGY_LOOKUP = {
      "widen" => "widen_ranges",
      "increase" => "bump_versions",
      "increase-if-necessary" => "bump_versions_if_necessary",
    }.freeze

    UPDATE_STRATEGIES = {
      "npm_and_yarn" => %w(widen_ranges bump_versions bump_versions_if_necessary),
      "composer" => %w(widen_ranges bump_versions bump_versions_if_necessary),
      "bundler" => %w(bump_versions bump_versions_if_necessary),
    }.freeze

    def self.token_for(package_manager:)
      PACKAGE_MANAGER_LOOKUP.invert.fetch(package_manager)
    end

    def initialize(config_file:)
      @config_file = config_file
    end

    def run
      validated_config_file
    end

    def updates
      @updates ||= validated_config_file["updates"].
                  map { |uc| transform_update_config_details(uc) }
    end

    def registries
      @registries ||= validated_config_file["registries"]
    end

    private

    attr_reader :config_file

    def validated_config_file
      return @validated_config_file if defined?(@validated_config_file)

      # NOTE: Supporting aliases would be nice, but can create recursive
      # structures that have memory leaks
      parsed_config_file = YAML.safe_load(config_file.content, aliases: false)
      validate_parsed_config_file(parsed_config_file)
      @validated_config_file = parsed_config_file
    rescue Psych::SyntaxError, Psych::DisallowedClass => e
      raise Unparseable, e.message
    rescue Psych::BadAlias
      raise Unparseable, "YAML aliases are not supported"
    end

    def validate_parsed_config_file(config_hash)
      # JSON::Validator blows up unless we provide a hash
      unless config_hash.is_a?(Hash)
        errs = [
          {
            fragment: "#/",
            message: "Top level entity must be an Object, "\
                    "not a #{config_hash.class}",
          },
        ]
        raise Invalid, errs
      end

      validate_top_level_config(config_hash)
      validate_unique_update_configs(config_hash)
      validate_update_configs(config_hash)
      validate_registries(config_hash)
      validate_update_config_registries(config_hash)
      validate_ignore_conditions(config_hash)
    end

    def validate_top_level_config(config_hash)
      config_errors = JSON::Validator.fully_validate(
        schema, config_hash,
        version: :draft6,
        parse_data: false,
        errors_as_objects: true,
        fragment: "#/definitions/top_level",
      )

      raise Invalid, sanitize_errors(config_errors) if config_errors.any?
    end

    # rubocop:disable Metrics/MethodLength
    def validate_unique_update_configs(config_hash)
      config_errors = []
      unique_configs = []
      config_hash["updates"].each_with_index do |c, index|
        unique_config = [
          c["package-ecosystem"],
          c["directory"],
          c["target-branch"],
        ]
        if unique_configs.include?(unique_config)
          fragment = "#/updates/#{index}"
          config_errors.push(
            fragment: fragment,
            message: "The property '#{fragment}' is a duplicate. Update "\
                    "configs must have a unique combination of "\
                    "'package-ecosystem', 'directory', and 'target-branch'",
          )
        else
          unique_configs.push(unique_config)
        end
      end
      raise Invalid, config_errors if config_errors.any?
    end
    # rubocop:enable Metrics/MethodLength

    def validate_update_configs(config_hash)
      config_errors = []
      config_hash["updates"].each_with_index do |config, index|
        package_manager = config["package-ecosystem"]
        errors = JSON::Validator.fully_validate(
          schema, config,
          version: :draft6,
          parse_data: false,
          errors_as_objects: true,
          fragment: "#/definitions/#{package_manager}",
        )
        config_errors.push(errors: errors, index: index) if errors.any?
      end
      return if config_errors.empty?

      errors = flatten_config_errors(config_errors, "updates")
      errors = sanitize_errors(errors)

      raise Invalid, errors
    end

    def validate_registries(config_hash)
      config_errors = []
      config_hash["registries"]&.each do |name, registry|
        registry_type = registry["type"]
        errors = JSON::Validator.fully_validate(
          schema, registry,
          version: :draft6,
          parse_data: false,
          errors_as_objects: true,
          fragment: "#/definitions/#{registry_type}",
        )
        config_errors.push(errors: errors, index: name) if errors.any?
      end
      return if config_errors.empty?

      errors = flatten_config_errors(config_errors, "registries")
      errors = sanitize_errors(errors)

      raise Invalid, errors
    end

    def validate_update_config_registries(config_hash)
      registry_names = config_hash.fetch("registries", {}).keys

      errors = []
      config_hash["updates"].each_with_index do |config, index|
        next unless config.key?("registries")
        next if config["registries"] == "*"

        nonexistent_registries = config["registries"] - registry_names

        nonexistent_registries.each do |name|
          fragment = "#/updates/#{index}/registries"
          errors.push(
            fragment: fragment,
            message: "The property '#{fragment}' includes the \"#{name}\" registry " \
              "which is not defined in the top-level 'registries' definition"
          )
        end
      end
      return if errors.empty?

      raise Invalid, errors
    end

    def validate_ignore_conditions(config_hash)
      config_errors = []
      config_hash["updates"].each_with_index do |config, index|
        config_errors += ignore_errors(config, index)
      end
      raise Invalid, config_errors if config_errors.any?
    end

    # rubocop:disable Metrics/MethodLength
    def ignore_errors(config, index)
      config_errors = []

      package_manager = config.fetch("package-ecosystem")
      transformed_package_manager = transform_package_manager(config)

      config.fetch("ignore", []).
        each_with_index do |ic, i|
          next unless (versions = ic["versions"])

          [versions].flatten.each do |version_reqs|
            requirements = IgnoreCondition.parse_requirement_string(
              transformed_package_manager,
              version_reqs
            )
            requirement_class(transformed_package_manager).new(requirements)
          end
        rescue Gem::Requirement::BadRequirementError
          fragment = "#/updates/#{index}/ignore/#{i}/"\
                    "versions"
          config_errors.push(
            fragment: fragment,
            message: "The property '#{fragment}' is an invalid version "\
                    "requirement for a #{package_manager} ignore condition",
          )
        end

      config_errors
    end
    # rubocop:enable Metrics/MethodLength

    # rubocop:disable Metrics/MethodLength
    def transform_update_config_details(uc_details)
      {
        "package-manager" => transform_package_manager(uc_details),
        "directory" => uc_details.fetch("directory"),
        "update-schedule" => uc_details.dig("schedule", "interval"),
        "update-schedule-time-of-day" => uc_details.dig("schedule", "time"),
        "update-schedule-day-of-week" => uc_details.dig("schedule", "day"),
        "update-schedule-timezone" => uc_details.dig("schedule", "timezone"),
        "target-branch" => uc_details.fetch("target-branch", nil)&.presence&.strip,
        "default-reviewers" => transform_default_reviewers(uc_details),
        "default-assignees" => uc_details.fetch("assignees", nil),
        "default-milestone" => uc_details.fetch("milestone", nil),
        "custom-labels" => uc_details.fetch("labels", nil),
        "lockfile-only" => transform_lockfile_only(uc_details),
        "requirements-update-strategy" =>
          transform_requirements_update_strategy(uc_details),
        "allowed-updates" => transform_allowed_updates(uc_details),
        "ignore-conditions" => transform_ignore_conditions(uc_details),
        "commit-message-prefix" => uc_details.dig("commit-message", "prefix"),
        "commit-message-prefix-development" =>
          uc_details.dig("commit-message", "prefix-development"),
        "commit-message-include-scope" =>
          transform_commit_message_include_scope(uc_details),
        "open-pull-requests-limit" =>
          uc_details.fetch("open-pull-requests-limit", nil),
        "rebase-strategy" => uc_details.fetch("rebase-strategy", nil),
        "pull-request-branch-name-separator" =>
          uc_details.dig("pull-request-branch-name", "separator"),
        "vendor" => uc_details.fetch("vendor", false),
        "registries" => uc_details.fetch("registries", nil),
        "insecure-external-code-execution" => uc_details.fetch("insecure-external-code-execution", nil),
      }
    end
    # rubocop:enable Metrics/MethodLength

    def transform_package_manager(uc_details)
      PACKAGE_MANAGER_LOOKUP.fetch(uc_details.fetch("package-ecosystem"))
    end

    def transform_default_reviewers(uc_details)
      team_reviewers = []
      user_reviewers = []

      uc_details.fetch("reviewers", []).each do |reviewer|
        # Only supports team reviewers that include the org/account name e.g.
        # dependabot/admins
        if (account_prefix = reviewer.match(%r{\A.+/}))
          team_slug = reviewer.sub(account_prefix[0], "")
          team_reviewers.push(team_slug)
        else
          user_reviewers.push(reviewer)
        end
      end

      default_reviewers = {}
      default_reviewers["reviewers"] = user_reviewers
      default_reviewers["team_reviewers"] = team_reviewers
      default_reviewers = nil if default_reviewers.values.flatten.empty?
      default_reviewers
    end

    def transform_lockfile_only(uc_details)
      version_req = uc_details.fetch("versioning-strategy", nil)
      version_req == "lockfile-only"
    end

    def transform_requirements_update_strategy(uc_details)
      package_manager = transform_package_manager(uc_details)
      version_req = uc_details.fetch("versioning-strategy", nil)
      allowed_strategies = UPDATE_STRATEGIES.fetch(package_manager, [])
      update_strategy = REQUIREMENT_UPDATE_STRATEGY_LOOKUP.fetch(version_req, nil)
      return update_strategy if allowed_strategies.include?(update_strategy)
    end

    def transform_allowed_updates(uc_details)
      value = uc_details.fetch("allow", [])

      if value.empty?
        [
          { "dependency_type" => "direct", "update_type" => "all" },
        ]
      else
        value.map do |au|
          {
            "dependency_name" => au["dependency-name"],
            "dependency_type" => au["dependency-type"],
          }.compact
        end
      end
    end

    def transform_ignore_conditions(uc_details)
      ignore_conditions = flattened_ignore_conditions(uc_details)
      return unless ignore_conditions

      ignore_conditions.map do |ic|
        next unless ic["dependency-name"]

        {
          "dependency_name" => ic["dependency-name"],
          "version_requirement" =>
            ic["versions"] || ">= 0",
        }
      end.compact
    end

    def flattened_ignore_conditions(uc_details)
      ignore_conditions = uc_details["ignore"]
      return unless ignore_conditions

      ignore_conditions.each_with_object([]) do |ic, memo|
        versions = [ic["versions"]].flatten
        versions.each do |version|
          memo.push(
            "dependency-name" => ic["dependency-name"],
            "versions" => version,
          )
        end
        memo
      end
    end

    def transform_commit_message_include_scope(uc_details)
      commit_message_include = uc_details.dig("commit-message", "include")
      return unless commit_message_include

      commit_message_include == "scope"
    end

    def flatten_config_errors(config_errors, root)
      config_errors.flat_map do |config_error|
        index = config_error[:index]
        config_error[:errors].map do |schema_error|
          schema_error[:message] =
            schema_error[:message].
            sub(/^The property '#/, "The property '#/#{root}/#{index}")
          schema_error[:fragment] =
            schema_error[:fragment].
            sub(/^#/, "#/#{root}/#{index}")
          schema_error
        end
      end
    end

    def sanitize_errors(errors)
      errors.map do |error|
        err = error.dup
        err[:message] = sanitize_schema_error(error[:message])
        err
      end
    end

    def sanitize_schema_error(error_message)
      # Removing useless hashed reference to schema:
      # e.g. "... in schema 18a1ffbb-4681-5b00-bd15-2c76aee4b28f"
      error_message.sub(/ in schema [-a-zA-Z0-9]+#?$/, "")
    end

    def requirement_class(package_manager)
      Dependabot::Utils.requirement_class_for_package_manager(package_manager)
    end

    def schema
      @schema ||= JSON.parse(File.read(File.join(__dir__, "config_file_json_schema.json")))
    end
  end
end
