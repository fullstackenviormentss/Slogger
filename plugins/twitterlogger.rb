# encoding: UTF-8
=begin
Plugin: Twitter Logger
Version: 3.0
Description: Logs updates and favorites for specified Twitter users
Author: [Brett Terpstra](http://brettterpstra.com)
Configuration:
  twitter_users: [ "handle1" , "handle2", ... ]
  save_images: true
  droplr_domain: d.pr
  twitter_tags: "#social #blogging"
Notes:

=end
config = {
  'description' => [
    'Logs updates and favorites for specified Twitter users',
    'twitter_users should be an array of Twitter usernames, e.g. [ ttscoff, markedapp ]',
    'save_images (true/false) determines whether TwitterLogger will look for image urls and include them in the entry',
    'save_favorites (true/false) determines whether TwitterLogger will look for the favorites of the given usernames and include them in the entry',
    'save_images_from_favorites (true/false) determines whether TwitterLogger will download images for the favorites of the given usernames and include them in the entry',
    'save_retweets (true/false) determines whether TwitterLogger will include retweets in the posts for the day',
    'droplr_domain: if you have a custom droplr domain, enter it here, otherwise leave it as d.pr ',
    'oauth_token and oauth_secret should be left blank and will be filled in by the plugin'],
    'twitter_users' => [],
    'save_favorites' => true,
    'save_images' => true,
    'save_images_from_favorites' => true,
    'droplr_domain' => 'd.pr',
    'twitter_tags' => '#social #twitter',
    'oauth_token' => '',
    'oauth_token_secret' => '',
    'exclude_replies' => true
}
$slog.register_plugin({ 'class' => 'TwitterLogger', 'config' => config })

require 'digest/sha1'
require 'twitter'
require 'twitter_oauth'

class TwitterLogger < Slogger

  def get_body(target, depth = 0)
    final_url = RedirectFollower.new(target).resolve
    url = URI.parse(final_url.url)

    host, port = url.host, url.port if url.host && url.port
    req = Net::HTTP::Get.new(url.path)
    res = Net::HTTP.start(host, port) {|http| http.request(req) }
    res.body
  end

  def download_images(images)
    images.each do |image|
      options = {}
      options['content'] = image['content']
      options['uuid'] = generate_uuid_for_tweet(image['content'])
      next if options['content'].nil? || options['url'].nil?
      sl = DayOne.new
      path = sl.save_image(options['url'], options['uuid'])
      sl.to_dayone(options)
    end
    true
  end

  def get_tweets(user, type='timeline', max_id = nil)
    @log.info("Getting Twitter #{type} for #{user}")

    Twitter.configure do |auth_config|
      auth_config.consumer_key = "53aMoQiFaQfoUtxyJIkGdw"
      auth_config.consumer_secret = "Twnh3SnDdtQZkJwJ3p8Tu5rPbL5Gt1I0dEMBBtQ6w"
      auth_config.oauth_token = @twitter_config["oauth_token"]
      auth_config.oauth_token_secret = @twitter_config["oauth_token_secret"]
    end

    case type
    when 'favorites'
      params = { "count" => 250, "screen_name" => user, "include_entities" => true }
      tweet_obj = Twitter.favorites(params)
    when 'timeline'
      params = { "count" => 250, "screen_name" => user, "include_entities" => true, "exclude_replies" => @twitter_config['exclude_replies'], "include_rts" => @twitter_config['save_retweets']}
      tweet_obj = Twitter.user_timeline(params)
    end

    images = []
    tweets = []
    begin
      tweet_obj.each do |tweet|
        today = @timespan
        tweet_date = tweet.created_at
        break if tweet_date < today
        tweet_text = tweet.text.gsub(/\n/,"\n\t")
        if type == 'favorites'
          # TODO: Prepend favorite's username/link
          screen_name = tweet.user.status.user.screen_name
          tweet_text = "[#{screen_name}](http://twitter.com/#{screen_name}): #{tweet_text}"
          tweet_text = "☆  #{tweet_text}\n[#{screen_name}](http://twitter.com/#{screen_name})"
        end

        tweet_id = tweet.id
        unless tweet.urls.empty?
          tweet.urls.each { |url|
            tweet_text.gsub!(/#{url.url}/,"[#{url.display_url}](#{url.expanded_url})")
          }
        end
        begin
          if @twitter_config['save_images']
            tweet_images = []
            unless tweet.media.empty?
              tweet.media.each { |img|
                tweet_images << { 'content' => tweet_text, 'date' => tweet_date.utc.iso8601, 'url' => img.media_url }
              }
            end
          end
          tweet_images.concat parse_images_from_tweet(tweet_text, tweet_date)
        end
        if tweet_images.empty?
          tweets.push({
            'content' => "#{tweet_text}\n\n[[#{tweet_date.strftime('%I:%M %p')}](https://twitter.com/#{user}/status/#{tweet_id})]",
            'uuid' => generate_uuid_for_tweet(tweet_text),
              'datestamp' => tweet_date.utc.iso8601
          })
        else
          images.concat(tweet_images)
        end
        oldest_id = tweet_id
      end
      if @twitter_config['save_images'] && images != []
        self.download_images(images)
      end
      sl = DayOne.new
      tweets.each do |tweet|
        sl.to_dayone(tweet)
      end
      if tweets.length > 0 && $options[:archive]
        older_tweets = get_tweets(user, type, oldest_id)
      end
      true
    end
  end

  def do_log
    if @config.key?(self.class.name)
      @twitter_config = @config[self.class.name]
      if !@twitter_config.key?('twitter_users') || @twitter_config['twitter_users'] == []
        @log.warn("Twitter users have not been configured, please edit your slogger_config file.")
        return
      end
    else
      @log.warn("Twitter users have not been configured, please edit your slogger_config file.")
      return
    end

    if @twitter_config['oauth_token'] == '' || @twitter_config['oauth_token_secret'] == ''
      client = TwitterOAuth::Client.new(
        :consumer_key => "53aMoQiFaQfoUtxyJIkGdw",
        :consumer_secret => "Twnh3SnDdtQZkJwJ3p8Tu5rPbL5Gt1I0dEMBBtQ6w"
      )

      request_token = client.authentication_request_token(
        :oauth_callback => 'oob'
      )
      @log.info("Twitter requires configuration, please run from the command line and follow the prompts")
      puts
      puts "------------- Twitter Configuration --------------"
      puts "Slogger will now open an authorization page in your default web browser. Copy the code you receive and return here."
      print "Press Enter to continue..."
      gets
      %x{open "#{request_token.authorize_url}"}
      print "Paste the code you received here: "
      code = gets.strip

      access_token = client.authorize(
        request_token.token,
        request_token.secret,
        :oauth_verifier => code
      )
      if client.authorized?
        @twitter_config['oauth_token'] = access_token.params["oauth_token"]
        @twitter_config['oauth_token_secret'] = access_token.params["oauth_token_secret"]
        puts
        log.info("Twitter successfully configured, run Slogger again to continue")
        return @twitter_config
      end
    end
    @twitter_config['save_images'] ||= true
    @twitter_config['droplr_domain'] ||= 'd.pr'

    @twitter_config['twitter_users'].each do |user|
      with_retries {
        get_tweets(user,'timeline')
      }
      with_retries {
        get_tweets(user,'favorites')
      }
    end
  end

  def parse_images_from_tweet(tweet_text, tweet_date)
    tweet_images = []
    urls = []
    tweet_text.scan(/\((http:\/\/twitpic.com\/\w+?)\)/).each do |picurl|
      aurl=URI.parse(picurl[0])
      burl="http://twitpic.com/show/large#{aurl.path}"
      curl = RedirectFollower.new(burl).resolve
      urls << curl.url
    end
    tweet_text.scan(/\((http:\/\/campl.us\/\w+?)\)/).each do |picurl|
      aurl=URI.parse(picurl[0])
      burl="http://campl.us/#{aurl.path}:800px"
      curl = RedirectFollower.new(burl).resolve
      urls << curl.url
    end
    tweet_text.scan(/\((http:\/\/instagr\.am\/\w\/\w+?\/)\)/).each do |picurl|
      final_url = self.get_body(picurl[0]).match(/http:\/\/distilleryimage.+\.com[\W][a-z0-9_]+\.jpg/)
      urls << final_url[0] if final_url
    end
    tweet_text.scan(/http:\/\/[\w\.]*yfrog\.com\/[\w]+/).each do |picurl|
      aurl=URI.parse(picurl)
      burl="http://yfrog.com#{aurl.path}:medium"
      curl = RedirectFollower.new(burl).resolve
      urls << curl.url
    end
    urls.compact.each do |url|
      tweet_images << {
        'content' => tweet_text,
        'datestamp' => tweet_date.utc.iso8601,
        'url' => url
      }
    end
    tweet_images
  end

  def generate_uuid_for_tweet(text)
    Digest::SHA1.hexdigest(text)[0...32].upcase
  end

  def with_retries(&block)
    retries = 0
    success = false
    returned = nil
    until success
      returned = yield
      if returned
        success = true
      else
        break if $options[:max_retries] == retries
        retries += 1
        sleep 2
      end
    end

    return @twitter_config
  end

  def try(&action)
    retries = 0
    success = false
    until success || $options[:max_retries] == retries
      result = yield
      if result
        success = true
      else
        retries += 1
        @log.error("Error performing action, retrying (#{retries}/#{$options[:max_retries]})")
        sleep 2
      end
    end
    result
  end
end
