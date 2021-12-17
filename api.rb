require "bundler/setup"
Bundler.require(:default)
require "uri"
require "yaml"

module LambdaFunction
  module HTTP
    MAX_REDIRECT_COUNT = 2
    # resolve redirects
    def self.get(url, redirect_count = 0)
      return if redirect_count >= MAX_REDIRECT_COUNT

      res = HTTP._get(url)
      case res
      when Net::HTTPInformation # 1xx
        raise "1xx"
      when Net::HTTPSuccess     # 2xx
        return res.body
      when Net::HTTPRedirection # 3xx
        # TODO: log.warn
        return HTTP.get(res.header["location"], redirect_count + 1)
      when Net::HTTPClientError # 4xx
        raise "4xx"
      when Net::HTTPServerError # 5xx
        raise "5xx"
      end
    end

    def self._get(url)
      uri = url.is_a?(URI) ? url : URI(url)
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "BlogCheckerBot/1.0 (@onk)"
      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(req)
      end
      res
    end
  end

  module S3
    def self.fetch_s3(url)
      uri = URI(url)
      s3_client = Aws::S3::Client.new
      obj = s3_client.get_object(
        bucket: uri.hostname,
        key: uri.path.sub(%r{^/}, "")
      )
      obj.body.read
    end
  end

  module Techwords
    PATTERN = begin
      techwords = S3.fetch_s3(ENV["TECHWORDS_PATH"]).lines.map(&:chomp)
      words_space_delimited, words_non_space_delimited = techwords.partition {|w| w =~ /[a-zA-Z0-9\u00C0-\u00FF]+/ }
      re_space_delimited = /(?:\b|(?<=[^a-zA-Z0-9\u00C0-\u00FF]))(?:#{Regexp.union(words_space_delimited).source})(?:\b|(?=[^a-zA-Z0-9\u00C0-\u00FF]))/i
      re_non_space_delimited = Regexp.union(words_non_space_delimited)
      unioned = Regexp.union([re_space_delimited, re_non_space_delimited].compact)
      Regexp.new(unioned.source, Regexp::IGNORECASE)
    end
  end

  class Handler
    def self.process(event:, context:)
      site = {
        "kind" => "other",
        "url"  => event["queryStringParameters"]["url"],
      }
      self.new.run(site)
    end

    def run(site)
      feed = fetch_feed(site)
      tech_entries = feed.entries.select {|entry|
        include_techwords?(entry.title, entry.content || entry.summary || "")
      }

      body = tech_entries.map {|entry|
        {
          title: entry.title,
          url: entry.url,
        }
      }.to_json

      { statusCode: "200", headers: { "Content-Type" => "application/json" }, body: body }
    end

    def fetch_feed(site)
      feed_url = feed_url(site)
      raise "Missing feed_url: #{site}" unless feed_url # fail to determin feed url

      sleep 1
      feed_str = HTTP.get(feed_url)

      Feedjira.parse(feed_str)
    end

    def feed_url(site)
      case site["kind"]
      when "hatenablog" # /feed
        uri = URI(site["url"])
        uri.path = "/feed"
        uri.to_s
      when "speakerdeck" # /:username.atom
        uri = URI(site["url"])
        username = uri.path.delete("/")
        uri.path = "/#{username}.atom"
        uri.to_s
      when "scrapbox" # https://scrapbox.io/api/feed/:projectname
        uri = URI(site["url"])
        projectname = uri.path.delete("/")
        uri.path = "/api/feed/#{projectname}"
        uri.to_s
      when "slideshare" # /rss/user/:username
        uri = URI(site["url"])
        username = uri.path.delete("/")
        uri.path = "/rss/user/#{username}"
        uri.to_s
      else
        # TODO: cache feed_url
        FeedSearcher.search(site["url"]).first
      end
    end

    def include_techwords?(title, body)
      Sanitize.clean(title + body).scan(Techwords::PATTERN).size >= 3
    end
  end
end
