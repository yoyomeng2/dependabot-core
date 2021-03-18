# frozen_string_literal: true

require "graphql/client"
require "graphql/client/http"

module GitHubGraphQL
  class ServerError < StandardError; end
  class UnauthorizedError < StandardError; end

  module Client
    DEFAULT_ENDPOINT = "https://api.github.com/graphql"

    # This schema is available via CURL:
    # curl -H "Authorization: bearer $LOCAL_GITHUB_ACCESS_TOKEN" \
    #   https://api.github.com/graphql > bin/cli/github_graphql_schema.json
    SCHEMA = File.join(__dir__, "github_graphql_schema.json").to_s

    def self.build
      http_adapter = GraphQL::Client::HTTP.new(DEFAULT_ENDPOINT) do
        def headers(context) # rubocop:disable Lint/NestedMethodDefinition
          raise "Missing GitHub access token" unless context[:access_token]

          {
            "Authorization" => "Bearer #{context[:access_token]}",
            "Accept" => context[:accept_header]
          }.compact
        end
      end

      GraphQL::Client.new(schema: SCHEMA, execute: http_adapter).tap do |client|
        client.allow_dynamic_queries = true
      end
    end
  end

  def self.client
    @client ||= Client.build
  end
end
