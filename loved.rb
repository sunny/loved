#!/usr/bin/env ruby
require 'rubygems'
require 'librmpd'
require 'yaml'
require 'iconv'

class MPD
  class Song
    def to_s
      "#{artist} - #{title}" + \
        ("\n   tags: #{tags.join(' ')}" if tags.any?).to_s
    end
  end
end

module Loved
  extend self

  class NoCurrentSong < ArgumentError; end

  @@auto_tags = %w(artist genre date)

  def playlists_directory=(directory)
    @@directory = directory
    FileUtils.mkdir_p(@@directory) unless File.directory?(@@directory)
  end

  def mpd
    @mpd ||= begin
      MPD.new.tap { |mpd| mpd.connect }
    rescue SocketError, Errno::ECONNREFUSED
      abort "Couldn't connect to MPD"
    end
  end

  def love_current_mpd_song!(tags=[])
    raise NoCurrentSong unless song = mpd.current_song
    love_it!(song, tags)
  end

  def append_found_songs_to_mpd_playlist!(tags=[])
    by_tags(tags).tap do |songs|
      songs.each { |song| mpd.add(song) }
    end
  end

  def love_it!(song, tags=[])
    auto_tags = @@auto_tags.map { |key| song[key] }.compact
    song.tags = tags + auto_tags

    write_to_database(song)

    song
  end

  def loved?(song, tags=[])
    by_tags(tags).include?(song.file)
  end

  def all
    by_tags(['all'])
  end

  def by_tags(tags=[])
    files = tags.map! { |tag| file_name_for_tag(tag) }

    case tags.length
    when 0 then all
    when 1 then find_songs_in_file(files.first)
    else
      files.inject([]) do |songs, file|
        songs << find_songs_in_file(file)
      end
    end
  end

  private
    def write_to_database(song)
      song.tags.push('all').uniq!

      files = song.tags.map { |tag| file_name_for_tag(tag) }
      files.each do |file_name|
        File.open(file_name, 'a+') do |file|
          next unless file.grep(/^#{Regexp.quote(song.file)} /).empty?
          file.puts "#{song.file} # #{song.tags.join(' ')}"
        end
      end
    end

    def find_songs_in_file(file_name)
      File.foreach(file_name).inject([]) do |songs, line|
        songs << line.split('#').first.strip
      end
    rescue Errno::ENOENT
      []
    end

    def file_name_for_tag(tag)
      File.join(@@directory, normalize_tag_for_file_name(tag))
    end

    # thanks technoweenie!
    def normalize_tag_for_file_name(tag)
      result = Iconv.iconv('ascii//translit//IGNORE', 'utf-8', tag.to_s).to_s
      result.gsub!(/[^\x00-\x7F]+/, '') # Remove anything non-ASCII entirely (e.g. diacritics).
      result.gsub!(/[^\w_ \-]+/i, '') # Remove unwanted chars.
      result.gsub!(/[ \-]+/i, '-') # No more than one of the separator in a row.
      result.gsub!(/^\-|\-$/i, '') # Remove leading/trailing separator.
      result.downcase!
      result
    end
end

if $0 == __FILE__
  Loved.playlists_directory = File.join(ENV['HOME'], '.loved')

  if ARGV.delete('play')
    songs = Loved.append_found_songs_to_mpd_playlist!(ARGV)
    puts "Appended #{songs.length} song#{'s' if songs.length > 1} to your MPD playlist. Enjoy!"
    exit
  end

  begin
    song = Loved.love_current_mpd_song!(ARGV.dup)
    puts "Loved #{song}"
  rescue Loved::NoCurrentSong
    abort "Couldn't determine current song. Check that MPD is playing."
  end
end
