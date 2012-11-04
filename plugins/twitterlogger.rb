# encoding: UTF-8
=begin
Plugin: Twitter Logger
Description: Logs updates and favorites for specified Twitter users
Author: [Brett Terpstra](http://brettterpstra.com)
Configuration:
  twitter_users: [ "handle1" , "handle2", ... ]
  save_images: true
  droplr_domain: d.pr
  twitter_tags: "@social @blogging"
Notes:

=end
config = {
  'description' => [
    'Logs updates and favorites for specified Twitter users',
    'twitter_users should be an array of Twitter usernames, e.g. [ ttscoff, markedapp ]',
    'save_images (true/false) determines weather TwitterLogger will look for image urls and include them in the entry',
    'droplr_domain: if you have a custom droplr domain, enter it here, otherwise leave it as d.pr '],
  'twitter_users' => [],
  'save_images' => true,
  'droplr_domain' => 'd.pr',
  'twitter_tags' => '@social @twitter'
}
$slog.register_plugin({ 'class' => 'TwitterLogger', 'config' => config })

require 'rexml/document'
require 'digest/sha1'

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
      image['uuid'] = generate_uuid_for_tweet(image['content'])
      sl = DayOne.new
      path = sl.save_image(image['url'], image['uuid'])
      sl.to_dayone(image)
    end
    true
  end

  def get_tweets(user, type='timeline', max_id = nil)
    @log.info("Getting Twitter #{type} for #{user}")
    if type == 'favorites'
      url = "http://api.twitter.com/1/favorites.xml?count=200&screen_name=#{user}&include_entities=true&count=200"
    else
      url = "http://api.twitter.com/1/statuses/user_timeline.xml?screen_name=#{user}&count=200&exclude_replies=true&include_entities=true"
      url << "&max_id=#{max_id}" if max_id
    end
    tweets = []
    images = []
    begin
      begin
        res = Net::HTTP.get_response(URI.parse(url)).body
      rescue Exception => e
        @log.warn("Failure getting response from Twitter")
        return false
      end
      oldest_id = nil
      REXML::Document.new(res).elements.each("statuses/status") do |tweet|
        tweet_date = Time.parse(tweet.elements['created_at'].text)
        tweet_text = tweet.elements['text'].text.gsub(/\n/,"\n\t")
        if type == 'favorites'
          screen_name = tweet.elements['user/screen_name'].text
          tweet_text = "☆  #{tweet_text}\n[#{screen_name}](http://twitter.com/#{screen_name})"
        end
        tweet_id = tweet.elements['id'].text
        unless tweet.elements['entities/urls'].nil? || tweet.elements['entities/urls'].length == 0
          tweet.elements.each("entities/urls/url") do |url|
            tweet_text.gsub!(/#{url.elements['url'].text}/,"[#{url.elements['display_url'].text}](#{url.elements['expanded_url'].text})")
          end
        end
        if @twitter_config['save_images']
          tweet_images = []
          unless tweet.elements['entities/media'].nil? || tweet.elements['entities/media'].length == 0
            tweet.elements.each("entities/media/creative") do |img|
              tweet_images << {
                'content' => tweet_text,
                'datestamp' => tweet_date.utc.iso8601,
                'url' => img.elements['media_url'].text
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
  end

end
