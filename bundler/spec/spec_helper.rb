# frozen_string_literal: true

def common_dir
  @common_dir ||= Gem::Specification.find_by_name("dependabot-common").gem_dir
end

def require_common_spec(path)
  require "#{common_dir}/spec/dependabot/#{path}"
end

require "#{common_dir}/spec/spec_helper.rb"

module PackageManagerHelper
  def self.use_bundler_2?
    ENV["SUITE_NAME"] == "bundler2"
  end

  def self.use_bundler_1?
    !use_bundler_2?
  end

  def self.bundler_version
    use_bundler_2? ? "2" : "1"
  end

  def self.bundler_project_dependency_files(project)
    project_dependency_files(File.join("bundler#{bundler_version}", project))
  end
end

RSpec.configure do |config|
  config.around do |example|
    if PackageManagerHelper.use_bundler_2? && example.metadata[:bundler_v1_only]
      example.skip
    elsif PackageManagerHelper.use_bundler_1? && example.metadata[:bundler_v2_only]
      example.skip
    else
      example.run
    end
  end
end
