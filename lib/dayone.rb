require 'fileutils'

class DayOne < Slogger

  def to_dayone(options = {})
    @dayonepath = storage_path
    content = options['content'] || ''
    uuid = options['uuid']
    datestamp = options['datestamp'] || options['date'] || Time.now.utc.iso8601
    entry = CGI.escapeHTML(content) unless content.nil?
    starred = options['starred'] || false

    @log.info("=====[ Saving entry to entries/#{uuid} ]")
    ext = ".doentry"
    entry_dir = File.join(File.expand_path(@dayonepath), "entries")
    Dir.mkdir(entry_dir, 0700) unless File.directory?(entry_dir)
    File.open("#{entry_dir}/#{uuid}#{ext}",'w+') do |f|
      f << @template.result(binding)
    end
    return true
  end

  def save_image(imageurl, uuid)
    @dayonepath = Slogger.new.storage_path
    source = imageurl.gsub(/^https/,'http')
    match = source.match(/(\..{3,4})($|\?|%22)/)
    ext = match.nil? ? match[1] : '.jpg'
    @log.info("Original image has extension #{ext}. Coverting for Day One recognition.")
    photo_dir = File.join(File.expand_path(Slogger.new.storage_path), "photos")
    FileUtils..mkdir_p(photo_dir) unless File.directory?(photo_dir)
    target = File.join(photo_dir,"#{uuid}.jpg")
    Net::HTTP.get_response(URI.parse(imageurl)) do |http|
      data = http.body
      @log.info("Retrieving image -\n           Source: #{imageurl}\n      Target UUID: #{uuid}")
      if data == false || data == 'false'
        @log.warn("Download failed")
        return false
      else
        puts "writing to #{target}"
        File.open( File.expand_path(target), "wb" ) { |file| file.write(data) }
      end
    end
    target
  end

end
