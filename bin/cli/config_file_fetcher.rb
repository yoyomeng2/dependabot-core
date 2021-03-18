# frozen_string_literal: true

require "dependabot/file_fetchers"
require "dependabot/file_fetchers/base"
require "dependabot/errors"

module CLI
  class ConfigFileFetcher < Dependabot::FileFetchers::Base
    CONFIG_FILE_PATHS = %w(.github/dependabot.yml .github/dependabot.yaml).freeze

    def self.required_files_in?(filenames)
      CONFIG_FILE_PATHS.any? { |file| filenames.include?(file) }
    end

    def self.required_files_message
      "Repo must contain either a #{CONFIG_FILE_PATHS.join(' or a ')} file"
    end

    def config_file
      files.first
    end

    private

    def fetch_files
      fetched_files = []

      CONFIG_FILE_PATHS.each do |file|
        config_file = fetch_file_if_present(file)
        if config_file
          fetched_files << config_file
          break
        end
      end

      unless self.class.required_files_in?(fetched_files.map(&:name))
        raise Dependabot::ConfigFileFileNotFound, self.class.required_files_message
      end

      fetched_files
    end
  end
end
