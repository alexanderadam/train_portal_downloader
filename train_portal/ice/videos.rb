require 'tempfile'
require 'nokogiri'
require 'm3u8'
require 'open3'
require 'stringex'
require 'open-uri'
require 'zip'

if OpenSSL::SSL.const_defined?(:OP_IGNORE_UNEXPECTED_EOF)
  OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:options] |= OpenSSL::SSL::OP_IGNORE_UNEXPECTED_EOF
end

module TrainPortal::Ice
  module Videos
    module_function
    BASE_URL = 'https://api.filme-serien.iceportal.de'
    BENTO_PLATFORMS ={
      linux: 'x86_64-unknown-linux',
      osx: 'universal-apple-macosx',
      win: 'x86_64-microsoft-win32'
    }
    BENTO_URL = 'https://www.bok.net/Bento4/binaries/Bento4-SDK-1-6-0-641.{platform}.zip'
    READ_TIMEOUT = 60 # seconds

    def title = '🍿 Videos'

    def all
      @@all ||= get_json('/api/portal-teasers')['hydra:member'].sort_by { |h| h['titleFull'] }
    end

    def select_hash
      all.map.with_index { |video, index| ["#{video['titleFull']} (#{video['contentType']})", index] }.to_h
    end

    # data was prepared by https://github.com/shaka-project/shaka-packager
    # https://github.com/TheRadziu/VODSubDL
    def download(base_json)
      if base_json['serie']
        dowload_series(base_json)
      else
        download_movie(base_json)
      end
    end

    def dowload_series(base_json)
      info_path = "/api/portal-pages/#{base_json['slug']}"
      details = get_json(info_path)
      season_overview = details['contents']['hydra:member'].detect { |m| m['type'] == 'tabSwitch' }
      season_overview = season_overview['contents'].detect { |m| m['type'] == 'episodesTab' }['contents'].first
      episodes = season_overview['contents']
      directory = File.join(sanitize_string(base_json['titleFull']), sanitize_string(season_overview['name']))
      episodes.each do |episode|
        details = get_details(episode['slug'])
        manifests = get_manifests(details)
        file_name = File.join(directory, [sanitize_string(details['slug']), sanitize_string(details['name'])].join('_-_'))
        puts file_name
        download_video(manifests, file_name)
        return
      end
    end

    def download_movie(base_json)
      details = get_details(base_json['slug'])
      file_name = sanitize_string(base_json['titleFull'])
      file_name << "_#{sanitize_string(base_json['year'])}" if base_json['year']
      file_name << "_(#{sanitize_string(base_json['originalTitle'])})" if base_json['titleFull'] != base_json['originalTitle']
      download_video(get_manifests(details), file_name)
    end

    def download_video(manifests, file_name)
      # m3u8 = read_m3u8(manifests.detect { |url| url.end_with?('.m3u8') })
      # mpd_manifest = read_mpd_manifest(manifests.detect { |url| url.end_with?('manifest.mpd') })
      manifest_mpd_url = manifests.detect { |url| url.end_with?('manifest.mpd') }

      yt_dlp(manifest_mpd_url, full_path(file_name))
      file_name = full_path(file_name, 'mp4')
      mp4decode(file_name, manifest_mpd_url)
      reencode(file_name)
  end

    def yt_dlp(download_url, file_name)
      raise ArgumentError, 'file_name is required' if file_name.nil?
      return if full_path(file_name, 'mp4') # file exists

      unless system('which yt-dlp > /dev/null 2>&1')
        raise "yt-dlp is not installed or not found in PATH"
      end

      command = [
        'yt-dlp', '--quiet', '--no-warnings', '--progress', '-N', '16',
        '-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/mp4', '--output', file_name, '--allow-u', download_url
      ]
      puts command.join(' ')

      IO.popen(command) do |io|
        io.each do |line|
          puts line
        end
      end

      raise "Error during download" unless $?.success?

      file_name
    end

    def reencode(file_name)
      unless system('which ffmpeg > /dev/null 2>&1')
        raise "ffmpeg is not installed or not found in PATH"
      end

      output_file = file_name.sub(/\.\w+$/, '_x265.mp4')
      ffmpeg_command = [
        'ffmpeg', '-i', file_name, '-c:v', 'libx264', '-c:a', 'copy', '-strict', 'experimental', '-fflags', '+genpts', output_file
      ]
      puts ffmpeg_command.join(' ')

      IO.popen(ffmpeg_command) do |io|
        io.each { |line| puts line }
      end

      raise "Error during re-encoding" unless $?.success?

      File.delete(file_name) if File.exist?(file_name)

      output_file
    end

    def mp4decode(input_file, manifest_mpd_url)
      mp4decrypt_path = `which mp4decrypt > /dev/null 2>&1`.strip

      if mp4decrypt_path.empty?
        mp4decrypt_path = File.join(tmp_dir, 'bin', 'mp4decrypt')
        download_mp4decrypt(mp4decrypt_path) unless File.exist?(mp4decrypt_path)
      end

      manifest = Nokogiri::XML(URI.open(manifest_mpd_url).read)
      manifest.remove_namespaces!
      video_definitions = manifest.css('AdaptationSet[contentType="video"]')
      max_quality_video = video_definitions.max_by { |v| v['maxWidth'] }
      crypto_parameters = max_quality_video.css('ContentProtection[default_KID]').first
      key_id = crypto_parameters['default_KID']
      crypto_mode = crypto_parameters['value']
      scheme_id_uri = crypto_parameters['schemeIdUri']
      pssh = max_quality_video.css('ContentProtection pssh').first.content

      binding.irb
      key = get_decryption_key(pssh)

      output_file = input_file.sub(/\.\w+$/, '_dec.mp4')
      # Decrypt the video file
      decrypt_command = [
        'mp4decrypt', "--key", "#{key_id}:#{key}", input_file, output_file
      ]
      puts decrypt_command.join(' ')

      IO.popen(decrypt_command) do |io|
        io.each { |line| puts line }
      end

      raise "Error during decryption" unless $?.success?

      output_file
    end

    def get_decryption_key(pssh)
      binding.irb
      # Implement the logic to derive the key from the pssh
      # This is a placeholder implementation
      "your_decryption_key"
    end

    def get_json(path) = API.get_json(path, base_url: BASE_URL)
    def get_details(slug) = get_json("/api/portal-players/#{slug}")
    def get_manifests(details) = details['video']['hydra:member'].flat_map { |vh| vh['manifests'] }
    def read_m3u8(url) = M3u8::Playlist.read(URI.open(url).read)
    def read_mpd_manifest(url) = Nokogiri::XML(URI.open(url).read)
    def sanitize_string(string) = string.to_url(force_downcase: false).gsub('-', '_')
    def tmp_dir = TrainPortal.download_directory('tmp')

    def full_path(sub_path, extension = nil)
      result = TrainPortal.download_directory(File.join('videos', sub_path))
      return result if extension.nil?

      Dir.glob("#{result}*.#{extension}").first
    end

    def download_mp4decrypt(destination_path)
      puts 'downloading mp4decrypt'
      # Download and unpack Bento4 SDK
      platform = case RUBY_PLATFORM
                 when /linux/
                   'linux'
                 when /darwin/
                   'osx'
                 when /mingw|mswin/
                   'win'
                 else
                   raise "Unsupported platform: #{RUBY_PLATFORM}"
                 end

      bento_url = BENTO_URL.gsub('{platform}', BENTO_PLATFORMS[platform.to_sym])
      FileUtils.mkdir_p(File.join(tmp_dir, 'bin'))
      zip_path = File.join(tmp_dir, 'bento4.zip')

      File.open(zip_path, 'wb') do |file|
        uri = URI.parse(bento_url).open(open_timeout: READ_TIMEOUT, read_timeout: READ_TIMEOUT)
        file.write(uri.read)
      end

      Zip::File.open(zip_path) do |zip_file|
        zip_file.each do |entry|
          entry.extract(destination_path) if entry.name.end_with?('/bin/mp4decrypt')
        end
      end
      destination_path
    end
  end
end
