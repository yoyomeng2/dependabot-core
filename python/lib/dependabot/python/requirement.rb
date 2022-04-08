# frozen_string_literal: true

require "dependabot/utils"
require "dependabot/python/version"
require "dependabot/python/native_helpers"

module Dependabot
  module Python
    class Requirement
      attr_accessor :requirements

      # Returns an array of requirements. At least one requirement from the
      # returned array must be satisfied for a version to be valid.
      #
      # NOTE: Or requirements are only valid for Poetry.
      def self.requirements_array(requirement_string)
        [new(requirement_string)]
      end

      def initialize(requirements)
        response = SharedHelpers.run_helper_subprocess(
          command: "pyenv exec python #{NativeHelpers.python_helper_path}",
          function: "parse_constraint",
          args: [requirements.gsub(/\s+/, "")]
        )
        puts response
        raise Gem::Requirement::BadRequirementError unless response["ok"]

        @requirements = response["constraint"]
      end

      def ==(other)
        other = Python::Requirement.new(other.to_s) unless other.is_a?(Python::Requirement)
        puts "#{@requirements} == #{other.requirements}?"
        @requirements == other.requirements
      end

      def satisfied_by?(version)
        SharedHelpers.run_helper_subprocess(
          command: "pyenv exec python #{NativeHelpers.python_helper_path}",
          function: "contains",
          args: [@requirements, version]
        )
      end

      def exact?
        return false unless @requirements.scan(",").count

        %w(= == ===).include?(@requirements)
      end
    end
  end
end

Dependabot::Utils.
  register_requirement_class("pip", Dependabot::Python::Requirement)
