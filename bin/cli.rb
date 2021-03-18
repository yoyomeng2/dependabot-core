#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH << "./bundler/lib"
$LOAD_PATH << "./cargo/lib"
$LOAD_PATH << "./common/lib"
$LOAD_PATH << "./composer/lib"
$LOAD_PATH << "./dep/lib"
$LOAD_PATH << "./docker/lib"
$LOAD_PATH << "./elm/lib"
$LOAD_PATH << "./git_submodules/lib"
$LOAD_PATH << "./github_actions/lib"
$LOAD_PATH << "./go_modules/lib"
$LOAD_PATH << "./gradle/lib"
$LOAD_PATH << "./hex/lib"
$LOAD_PATH << "./maven/lib"
$LOAD_PATH << "./npm_and_yarn/lib"
$LOAD_PATH << "./nuget/lib"
$LOAD_PATH << "./python/lib"
$LOAD_PATH << "./terraform/lib"

require "bundler"
ENV["BUNDLE_GEMFILE"] = File.join(__dir__, "../omnibus/Gemfile")
Bundler.setup

require "json"
require "byebug"
require "logger"
require "dependabot/logger"
require "stackprof"

Dependabot.logger = Logger.new($stdout)

require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"

require "dependabot/bundler"
require "dependabot/cargo"
require "dependabot/composer"
require "dependabot/dep"
require "dependabot/docker"
require "dependabot/elm"
require "dependabot/git_submodules"
require "dependabot/github_actions"
require "dependabot/go_modules"
require "dependabot/gradle"
require "dependabot/hex"
require "dependabot/maven"
require "dependabot/npm_and_yarn"
require "dependabot/nuget"
require "dependabot/python"
require "dependabot/terraform"

require_relative "./cli/config_file_parser"
require_relative "./cli/config_file_fetcher"
require_relative "./cli/github_graphql"
require_relative "./cli/parser"
require_relative "./cli/utils"

TOP_LEVEL_DEPENDENCY_TYPES = %w(direct production development).freeze

# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Metrics/PerceivedComplexity
def allowed_update?(allowed_updates, security_advisories, dependency)
  allowed_updates.any? do |update|
    # Check the update-type (defaulting to all)
    update_type = update.fetch("update-type", "all")
    next false if update_type == "security" && !vulnerable?(dependency)

    # Check the dependency-name (defaulting to matching)
    condition_name = update.fetch("dependency-name", dependency.name)
    next false unless CLI::Utils.wildcard_match?(condition_name, dependency.name)

    # Check the dependency-type (defaulting to all)
    dep_type = update.fetch("dependency-type", "all")
    next false if dep_type == "indirect" &&
                  dependency.requirements.any?
    next false if dependency.requirements.none? &&
                  TOP_LEVEL_DEPENDENCY_TYPES.include?(dep_type)
    next false if dependency.production? && dep_type == "development"
    next false if !dependency.production? && dep_type == "production"

    true
  end
end
# rubocop:enable Metrics/CyclomaticComplexity

def security_advisories_for(security_advisories, dep)
  relevant_advisories =
    security_advisories.
    select { |adv| adv.fetch("dependency-name").casecmp(dep.name).zero? }

  relevant_advisories.map do |adv|
    vulnerable_versions = adv["affected-versions"] || []
    safe_versions = (adv["patched-versions"] || []) +
                    (adv["unaffected-versions"] || [])

    Dependabot::SecurityAdvisory.new(
      dependency_name: dep.name,
      package_manager: package_manager,
      vulnerable_versions: vulnerable_versions,
      safe_versions: safe_versions,
    )
  end
end

def fetch_update_configs(options:, credentials:)
  config_file_source = Dependabot::Source.new(
    provider: options.provider,
    repo: options.repo,
    directory: "/",
  )

  file_fetcher = CLI::ConfigFileFetcher.new(source: config_file_source, credentials: credentials)
  config_file = file_fetcher.config_file
  config_file_parser = CLI::ConfigFileParser.new(config_file: config_file)
  config_file_parser.updates
end

def vulnerable?(security_advisories, dependency)
  return false if security_advisories.none?

  # Can't (currently) detect whether dependencies without a version
  # (i.e., for repos without a lockfile) are vulnerable
  return false unless dependency.version

  # Can't (currently) detect whether git dependencies are vulnerable
  version_class =
    Dependabot::Utils.
    version_class_for_package_manager(dependency.package_manager)
  return false unless version_class.correct?(dependency.version)

  version = version_class.new(dependency.version)
  security_advisories.any? { |a| a.vulnerable?(version) }
end

def build_credentials
  credentials = []
  unless ENV["LOCAL_GITHUB_ACCESS_TOKEN"].to_s.strip.empty?
    credentials << {
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => ENV["LOCAL_GITHUB_ACCESS_TOKEN"]
    }
  end
  credentials
end

def fetch_files(options:, credentials:, update_config:)
  source = Dependabot::Source.new(
    provider: options.provider,
    repo: options.repo,
    directory: update_config["directory"],
    branch: update_config["target-branch"],
  )

  package_manager = update_config["package-manager"]
  always_clone = Dependabot::Utils.always_clone_for_package_manager?(package_manager)
  if always_clone
    repo_contents_path = Dir.mktmpdir
    puts "=> cloning into #{repo_contents_path}"
  end

  fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).
            new(source: source, credentials: credentials,
                repo_contents_path: repo_contents_path)
  if always_clone
    fetcher.clone_repo_contents
    fetcher.files
    {
      files: fetcher.files,
      repo_contents_path: repo_contents_path,
    }
  else
    {
      files: fetcher.files,
      repo_contents_path: nil,
    }
  end
end

def parse_dependencies(options:, credentials:, files:, update_config:, repo_contents_path:)
  # Parse the dependency files
  puts "=> parsing dependency files"

  source = Dependabot::Source.new(
    provider: options.provider,
    repo: options.repo,
    directory: update_config["directory"],
    branch: update_config["target-branch"],
  )

  package_manager = update_config["package-manager"]

  parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
    dependency_files: files,
    repo_contents_path: repo_contents_path,
    source: source,
    credentials: credentials,
    reject_external_code: update_config["insecure-external-code-execution"] != "allow",
  )

  parser.parse
end

def fetch_security_advisories(dependencies:)
  # advisories_query = GitHubGraphQL.client.parse <<-'GRAPHQL'
  #   mutation($id: ID!, $reaction: ReactionContent!) {
  #     addReaction(input: { subjectId: $id, content: $reaction }) {
  #       reaction {
  #         content
  #       }
  #       subject {
  #         id
  #       }
  #     }
  #   }
  # GRAPHQL
  # GitHubGraphQL.client.query(
  #   advisories_query,
  #   context: {
  #     access_token: ENV["LOCAL_GITHUB_ACCESS_TOKEN"],
  #     accept_header: "application/json",
  #   },
  # )
  []
end

module CLI
  def self.update(args)
    options = CLI::Parser.parse(args)
    credentials = build_credentials
    update_configs = fetch_update_configs(options: options, credentials: credentials)
    update_configs.each do |update_config|
      package_manager = update_config["package-manager"]
      puts "\n===\nchecking for #{package_manager} updates in #{update_config["directory"]}\n===\n\n"
      files, repo_contents_path = fetch_files(options: options, credentials: credentials,
                                              update_config: update_config).
        values_at(:files, :repo_contents_path)
      dependencies = parse_dependencies(files: files, options: options, credentials: credentials,
                                        update_config: update_config,
                                        repo_contents_path: repo_contents_path)

      security_advisories = fetch_security_advisories(dependencies: dependencies)
      if options.dependency_names.nil?
        dependencies = dependencies.select(&:top_level?)

        # Return dependencies in a random order, with top-level dependencies
        # considered first so that dependency runs which time out don't always hit
        # the same dependencies
        allowed_deps = dependencies.select do |d|
          allowed_update?(update_config["allowed-updates"], security_advisories_for(security_advisories, d), d)
        end.shuffle

        if dependencies.any? && allowed_deps.none?
          puts "Found no dependencies to update after filtering allowed updates"
        end

        # Consider updating vulnerable deps first. Only consider the first 10,
        # though, to ensure they don't take up the entire update run
        deps = allowed_deps.select { |d| vulnerable?(security_advisories_for(security_advisories, d), d) }.sample(10) +
              allowed_deps.reject { |d| vulnerable?(security_advisories_for(security_advisories, d), d) }

        deps
      else
        dependencies = dependencies.select do |d|
          options.dependency_names.include?(d.name.downcase)
        end
      end

      dependencies.each_with_index do |dep, index|
        ignore_conditions = update_config["ignore-conditions"]&.
          select { |ic| CLI::Utils.wildcard_match?(ic["dependency-name"], dep.name) }&.
          map { |ic| ic["version-requirement"] }

        checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
          dependency: dep,
          dependency_files: files,
          credentials: credentials,
          repo_contents_path: repo_contents_path,
          requirements_update_strategy: update_config["requirements-update-strategy"],
          ignored_versions: ignore_conditions || [],
          security_advisories: security_advisories_for(security_advisories, dep)
        )
        name_version = "\n=== #{dep.name} (#{dep.version})"
        vulnerable = checker.vulnerable? ? " (vulnerable 🚨)" : ""
        puts name_version + vulnerable

        puts " => checking for updates #{index + 1}/#{dependencies.count}"
        puts " => latest available version is #{checker.latest_version}"

        if options.security_updates_only? && !checker.vulnerable?
          if checker.version_class.correct?(checker.dependency.version)
            puts "    (no security update needed as it's not vulnerable)"
          else
            puts "    (can't update vulnerable dependencies for "\
                 "projects without a lockfile as the currently "\
                 "installed version isn't known 🚨)"
          end
          next
        end

        if checker.vulnerable?
          if checker.lowest_security_fix_version
            puts " => earliest available non-vulnerable version is "\
                 "#{checker.lowest_security_fix_version}"
          else
            puts " => there is no available non-vulnerable version"
          end
        end

        latest_allowed_version = if checker.vulnerable?
                                   checker.lowest_resolvable_security_fix_version
                                 else
                                   checker.latest_resolvable_version
                                 end
        puts " => latest allowed version is #{latest_allowed_version || dep.version}"

        if checker.up_to_date?
          puts "    (no update needed as it's already up-to-date)"
          next
        end

        requirements_to_unlock =
          if update_config["lockfile-only"] || !checker.requirements_unlocked_or_can_be?
            if checker.can_update?(requirements_to_unlock: :none) then :none
            else :update_not_possible
            end
          elsif checker.can_update?(requirements_to_unlock: :own) then :own
          elsif checker.can_update?(requirements_to_unlock: :all) then :all
          else :update_not_possible
          end

        puts " => requirements to unlock: #{requirements_to_unlock}"

        if checker.respond_to?(:requirements_update_strategy)
          puts " => requirements update strategy: "\
               "#{checker.requirements_update_strategy}"
        end

        if requirements_to_unlock == :update_not_possible
          conflicting_dependencies = checker.conflicting_dependencies
          if conflicting_dependencies.any?
            puts " => The update is not possible because of the following conflicting "\
              "dependencies:"

            conflicting_dependencies.each do |conflicting_dep|
              puts "   #{conflicting_dep['explanation']}"
            end
          end

          if checker.vulnerable? || options.security_updates_only?
            puts "    (no security update possible 🙅‍♀️)"
          else
            puts "    (no update possible 🙅‍♀️)"
          end
          next
        end

        updated_deps = checker.updated_dependencies(
          requirements_to_unlock: requirements_to_unlock
        )

        peer_dependencies_can_update = checker.updated_dependencies(requirements_to_unlock: requirements_to_unlock).
          reject { |dep| dep.name == checker.dependency.name }.
          any? do |dep|
            original_peer_dep = ::Dependabot::Dependency.new(
              name: dep.name,
              version: dep.previous_version,
              requirements: dep.previous_requirements,
              package_manager: dep.package_manager
            )
            Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
              dependency: original_peer_dep,
              dependency_files: files,
              credentials: credentials,
              repo_contents_path: repo_contents_path,
              requirements_update_strategy: update_config["requirements-update-strategy"],
              ignored_versions: ignore_conditions || [],
              security_advisories: security_advisories_for(security_advisories, dep)
            ).can_update?(requirements_to_unlock: :own)
          end

        if peer_dependencies_can_update
          puts "    (no update possible, peer dependency can be updated)"
          next
        end

        if updated_deps.count == 1
          updated_dependency = updated_deps.first
          prev_v = updated_dependency.previous_version
          prev_v_msg = prev_v ? "from #{prev_v} " : ""
          puts " => updating #{updated_dependency.name} #{prev_v_msg}to " \
               "#{updated_dependency.version}"
        else
          dependency_names = updated_deps.map(&:name)
          puts " => updating #{dependency_names.join(', ')}"
        end

        updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
          dependencies: updated_deps,
          dependency_files: files,
          repo_contents_path: repo_contents_path,
          credentials: credentials
        )

        updated_files = updater.updated_dependency_files

        # Currently unused but used to create pull requests
        updated_deps.reject! do |d|
          next false if d.name == checker.dependency.name
          next true if d.requirements == d.previous_requirements

          d.version == d.previous_version
        end

        if options.security_updates_only? &&
           updated_deps.none? { |dep| security_fix?(dep) }
          puts "    (updated version is still vulnerable 🚨)"
        end

        updated_files.each do |updated_file|
          if updated_file.deleted?
            puts "deleted #{updated_file.name}"
          else
            original_file = files.find { |f| f.name == updated_file.name }
            if original_file
              CLI::Utils.show_diff(original_file, updated_file)
            else
              puts "added #{updated_file.name}"
            end
          end
        end
      end
    end
  end
end
