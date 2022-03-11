# frozen_string_literal: true

require "dependabot/utils"
require "rubygems_version_patch"
require "semver_dialects"

# NuGet supports Semantic Versioning 2.0 since NuGet 4.3.0+
module Dependabot
  module Nuget
    class Version < Gem::Version
      # rubocop:disable Layout/LineLength
      SEMVER_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/.freeze
      # rubocop:enable Layout/LineLength

      def self.correct?(version)
        return false if version.nil?

        version.to_s.match?(SEMVER_PATTERN)
      end

      def initialize(version)
        @semver = SemanticVersion.new(version.to_s)
        version, @build_info = version.to_s.split("+") if version.to_s.include?("+")
        super
      end

      def to_s
        @semver.to_s
      end

      def inspect # :nodoc:
        "#<#{self.class} #{@semver}>"
      end

      def <=>(other)
        @semver <=> SemanticVersion.new(other.to_s)
      end
    end
  end
end

Dependabot::Utils.register_version_class("nuget", Dependabot::Nuget::Version)
