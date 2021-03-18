#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler"
ENV["BUNDLE_GEMFILE"] = File.join(__dir__, "../omnibus/Gemfile")
Bundler.setup

require "json"
require "byebug"

require_relative "./cli/github_graphql"

class GithubSecurityAdvisoryImporter
  class Error < StandardError; end

  class AccessError < StandardError
    def message
      <<~ERR
        There is no active Dependabot Account for GitHub!

        Dependabot cannot retrieve GHSA information unless it is installed on
        the GitHub organization in github/github.
      ERR
    end
  end

  # The package managers used in this API need to be mapped to core terminology.
  PACKAGE_MANAGER_MATRIX = {
    RUBYGEMS: "bundler",
    COMPOSER: "composer",
    NPM: "npm_and_yarn",
    PIP: "pip",
    MAVEN: "maven",
    NUGET: "nuget",
  }.freeze

  PAGE_SIZE = 50
  MAXIMUM_VULNERABILITIES = 100

  NO_PERSONAL_ACCESS_TOKEN_MSG = <<~ERR
    GHSA_ACCESS_TOKEN not set!

    Create a developer access token (https://github.com/settings/tokens) and set
    it in .env.local to access GitHub Security Advisories
  ERR

  SecurityAdvisoriesQuery = GitHubGraphQL.client.parse <<-'GRAPHQL'
    query($first: Int!, $cursor: String) {
      securityAdvisories(first: $first, after: $cursor, orderBy: { field: PUBLISHED_AT, direction: ASC }) {
        totalCount
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            ghsaId,
            publishedAt,
            updatedAt,
            withdrawnAt,
            vulnerabilities(first: $first) {
              totalCount,
              edges {
                node {
                  package {
                    name
                    ecosystem
                  }
                  vulnerableVersionRange
                  firstPatchedVersion {
                    identifier
                  }
                }
              }
            }
          }
        }
      }
    }
  GRAPHQL

  def import_all
    puts "Fetcing all github security advisories, this might take a while..."
    cursor = nil
    process_page = true
    advisories = {}

    while process_page
      puts "Fetched #{advisories.length} advisories" if advisories.any?
      response = request_vulnerability_page(cursor: cursor)

      raise Error, response.errors.messages[:data] if response.errors.any?

      security_advisories = response.data.security_advisories

      security_advisories.edges.each do |edge|
        vulns = transform_advisory(advisory: edge.node)
        vulns.each do |vuln|
          advisories[vuln[0]] ||= vuln[1]
        end
      end

      cursor = security_advisories.page_info.end_cursor
      process_page = security_advisories.page_info.has_next_page
    end

    cache_advisories_path = File.join(__dir__, "cli", "github_security_advisories.json")
    File.write(cache_advisories_path, JSON.pretty_generate(advisories))
  end

  private

  def request_vulnerability_page(cursor:)
    GitHubGraphQL.client.query(
      SecurityAdvisoriesQuery,
      context: {
        access_token: ENV["LOCAL_GITHUB_ACCESS_TOKEN"],
        accept_header: "application/json",
      },
      variables: {
        cursor: cursor,
        first: PAGE_SIZE,
      },
    )
  end

  def transform_advisory(advisory:)
    raise Error, "GHSA has too many vulnerabilities." if advisory.vulnerabilities.total_count > MAXIMUM_VULNERABILITIES

    vulnerabilities = advisory.vulnerabilities.edges.group_by do |vuln|
      {
        dependency_name: vuln.node.package.name,
        package_manager: package_manager_for(vuln.node.package.ecosystem),
      }
    end
    vulnerabilities.map do |package, vulns|
      [
        {
          dependency_name: k[:dependency_name],
          package_manager: k[:package_manager],
        },
        {
          affected_versions: vulnerabilities.map do |v|
            v.node.vulnerable_version_range
          end,
          patched_versions: vulnerabilities.map do |v|
            v.node.first_patched_version&.identifier
          end.compact,
          github_updated_at: advisory.updated_at,
          published_at: advisory.published_at,
          withdrawn_at: advisory.withdrawn_at,
        }
      ]
    end
  end

  # In the event we encounter a unknown ecosystem, we should raise as it
  # represents a new Advisory ecosystem being shipped without warning.
  def package_manager_for(ecosystem)
    PACKAGE_MANAGER_MATRIX.fetch(ecosystem&.to_sym)
  end
end

GithubSecurityAdvisoryImporter.new.import_all
