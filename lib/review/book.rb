#
# $Id: book.rb 4315 2009-09-02 04:15:24Z kmuto $
#
# Copyright (c) 2002-2008 Minero Aoki
#               2009 Minero Aoki, Kenshi Muto
#
# This program is free software.
# You can distribute or modify this program under the terms of
# the GNU LGPL, Lesser General Public License version 2.1.
# For details of the GNU LGPL, see the file "COPYING".
#

require 'review/index'
require 'review/volume'
require 'review/exception'
require 'review/compat'
require 'forwardable'
require 'nkf'

module ReVIEW

  @default_book = nil

  def ReVIEW.book
    @default_book ||= Book.load_default
  end

  class Book

    attr_accessor :param

    def Book.load_default
      %w( . .. ../.. ).each do |basedir|
        if File.file?("#{basedir}/CHAPS")
          book = load(basedir)
          if File.file?("#{basedir}/config.rb")
            book.instance_variable_set("@parameters", Parameters.load("#{basedir}/config.rb"))
          end
          return book
        end
      end
      new('.')
    end

    def Book.load(dir)
      update_rubyenv dir
      new(dir)
    end

    @basedir_seen = {}

    def Book.update_rubyenv(dir)
      return if @basedir_seen.key?(dir)
      if File.directory?("#{dir}/lib/review")
        $LOAD_PATH.unshift "#{dir}/lib"
      end
      if File.file?("#{dir}/review-ext.rb")
        Kernel.load File.expand_path("#{dir}/review-ext.rb")
      end
      @basedir_seen[dir] = true
    end

    def initialize(basedir, parameters = Parameters.default)
      @basedir = basedir
      @parameters = parameters
      @parts = nil
      @chapter_index = nil
    end

    extend Forwardable
    def_delegators '@parameters',
                   :chapter_file,
                   :part_file,
                   :bib_file,
                   :reject_file,
                   :predef_file,
                   :postdef_file,
                   :ext,
                   :image_dir,
                   :image_types,
                   :page_metric

    def no_part?
      false
    end

    def parts
      @parts ||= read_parts()
    end

    def part(n)
      parts.detect {|part| part.number == n }
    end

    def each_part(&block)
      parts.each(&block)
    end

    def chapters
      parts().map {|p| p.chapters }.flatten
    end

    def each_chapter(&block)
      chapters.each(&block)
    end

    def chapter_index
      @chapter_index ||= ChapterIndex.new(chapters())
      @chapter_index
    end

    def chapter(id)
      chapter_index()[id]
    end

    def volume
      Volume.sum(chapters.map {|chap| chap.volume })
    end

    def read_CHAPS
      res = ""
      File.open("#{@basedir}/#{chapter_file}") do |f|
        while line = f.gets
          if /\A#/ =~ line
            next
          end
          line.gsub!(/#.*$/, "")
          res << line
        end
      end
      res
    rescue Errno::ENOENT
      Dir.glob("#{@basedir}/*#{ext()}").sort.join("\n")
    end

    def read_PART
      @read_PART ||= File.read("#{@basedir}/#{part_file}")
    end

    def part_exist?
      File.exist?("#{@basedir}/#{part_file}")
    end

    def read_bib
      File.read("#{@basedir}/#{bib_file}")
    end

    def bib_exist?
      File.exist?("#{@basedir}/#{bib_file}")
    end

    def prefaces
      if File.file?("#{@basedir}/#{predef_file}")
        begin
          return mkpart_from_namelistfile("#{@basedir}/#{predef_file}")
        rescue FileNotFound => err
          raise FileNotFound, "preface #{err.message}"
        end
      else
        mkpart_from_namelist(%w(preface))
      end
    end

    def postscripts
      if File.file?("#{@basedir}/#{postdef_file}")
        begin
          return mkpart_from_namelistfile("#{@basedir}/#{postdef_file}")
        rescue FileNotFound => err
          raise FileNotFound, "postscript #{err.message}"
        end
      else
        mkpart_from_namelist(%w(appendix postscript))
      end
    end

    def basedir
      @basedir
    end

    private

    def read_parts
      list = parse_chapters
      if pre = prefaces
        list.unshift pre
      end
      if post = postscripts
        list.push post
      end
      list
    end

    def parse_chapters
      part = 0
      num = 0
      chap = read_CHAPS()\
          .strip.lines.map {|line| line.strip }.join("\n").split(/\n{2,}/)\
          .map {|part_chunk|
            chaps = part_chunk.split.map {|chapid|
              Chapter.new(self, (num += 1), chapid, "#{@basedir}/#{chapid}")
            }
            if part_exist? && read_PART.split("\n").size >= part
              Part.new((part += 1), chaps, read_PART.split("\n")[part-1])
            else
              Part.new((part += 1), chaps)
            end
          }
      return chap
    end

    def mkpart_from_namelistfile(path)
      mkpart(File.read(path).split.map {|name| mkchap(name) })
    end

    def mkpart_from_namelist(names)
      mkpart(names.map {|n| mkchap_ifexist(n) }.compact)
    end

    def mkpart(chaps)
      chaps.empty? ? nil : Part.new(nil, chaps)
    end

    def mkchap(name)
      name += ext if File.extname(name) == ""
      path = "#{@basedir}/#{name}"
      raise FileNotFound, "file not exist: #{path}" unless File.file?(path)
      Chapter.new(self, nil, name, path)
    end

    def mkchap_ifexist(id)
      name = "#{id}#{ext()}"
      path = "#{@basedir}/#{name}"
      File.file?(path) ? Chapter.new(self, nil, name, path) : nil
    end

  end


  class ChapterSet

    def ChapterSet.for_argv
      if ARGV.empty?
        new([Chapter.for_stdin])
      else
        for_pathes(ARGV)
      end
    end

    def ChapterSet.for_pathes(pathes)
      new(Chapter.intern_pathes(pathes))
    end

    def initialize(chapters)
      @chapters = chapters
    end

    def no_part?
      true
    end

    attr_reader :chapters

    def each_chapter(&block)
      @chapters.each(&block)
    end

    def ext
      '.re'
    end

  end


  class Parameters

    def Parameters.default
      new()
    end

    def Parameters.load(path)
      mod = Module.new
      mod.module_eval File.read(path), path
      new(
        :chapter_file => const_get_safe(mod, :CHAPS_FILE),
        :part_file    => const_get_safe(mod, :PART_FILE),
        :bib_file     => const_get_safe(mod, :BIB_FILE),
        :reject_file  => const_get_safe(mod, :REJECT_FILE) ||
                         const_get_safe(mod, :WORDS_FILE),
        :predef_file  => const_get_safe(mod, :PREDEF_FILE),
        :postdef_file => const_get_safe(mod, :POSTDEF_FILE),
        :ext          => const_get_safe(mod, :EXT),
        :image_dir    => const_get_safe(mod, :IMAGE_DIR),
        :image_types  => const_get_safe(mod, :IMAGE_TYPES),
        :page_metric  => get_page_metric(mod)
      )
    end

    def Parameters.get_page_metric(mod)
      if paper = const_get_safe(mod, :PAPER)
        unless PageMetric.respond_to?(paper.downcase)
          raise ConfigError, "unknown paper size: #{paper}"
        end
        return PageMetric.send(paper.downcase)
      end
      PageMetric.new(const_get_safe(mod, :LINES_PER_PAGE_list) || 46,
                     const_get_safe(mod, :COLUMNS_list)        || 80,
                     const_get_safe(mod, :LINES_PER_PAGE_text) || 30,
                     const_get_safe(mod, :COLUMNS_text)        || 74)  # 37zw
    end

    def Parameters.const_get_safe(mod, name)
      return nil unless mod.const_defined?(name)
      mod.const_get(name)
    end
    private_class_method :const_get_safe

    def initialize(params = {})
      @chapter_file = params[:chapter_file] || 'CHAPS'
      @part_file = params[:part_file]       || 'CHAPS'
      @reject_file  = params[:reject_file]  || 'REJECT'
      @predef_file  = params[:predef_file]  || 'PREDEF'
      @postdef_file = params[:postdef_file] || 'POSTDEF'
      @page_metric  = params[:page_metric]  || PageMetric.a5
      @ext          = params[:ext]          || '.re'
      @image_dir    = params[:image_dir]    || 'images'
      @image_types  = unify_exts(params[:image_types]  ||
                                 %w( eps ai tif tiff png bmp jpg jpeg gif svg pdf ))
      @bib_file  = params[:bib_file]        || "bib#{@ext}"
    end

    def unify_exts(list)
      list.map {|ext| (ext[0] == '.') ? ext : ".#{ext}" }
    end
    private :unify_exts

    def self.path_param(name)
      module_eval(<<-End, __FILE__, __LINE__ + 1)
        def #{name}
          "\#{@basedir}/\#{@#{name}}"
        end
      End
    end

    path_param  :chapter_file
    path_param  :part_file
    path_param  :bib_file
    path_param  :reject_file
    path_param  :predef_file
    path_param  :postdef_file
    attr_reader :ext
    path_param  :image_dir
    attr_reader :image_types
    attr_reader :page_metric

  end


  class PageMetric

    MetricData = Struct.new(:n_lines, :n_columns)

    def PageMetric.a5
      new(46, 80, 30, 74, 1)
    end

    def PageMetric.b5
      new(46, 80, 30, 74, 2)
    end
  
    def initialize(list_lines, list_columns, text_lines, text_columns, page_per_kbyte)
      @list = MetricData.new(list_lines, list_columns)
      @text = MetricData.new(text_lines, text_columns)
      @page_per_kbyte = page_per_kbyte
    end

    attr_reader :list
    attr_reader :text
    attr_reader :page_per_kbyte

  end


  class Part

    def initialize(number, chapters, name="")
      @number = number
      @chapters = chapters
      @name = name
    end

    attr_reader :number
    attr_reader :chapters
    attr_reader :name

    def each_chapter(&block)
      @chapters.each(&block)
    end

    def volume
      Volume.sum(@chapters.map {|chap| chap.volume })
    end

  end


  class Chapter

    def Chapter.intern_pathes(pathes)
      books = {}
      pathes.map {|path|
        basedir = File.dirname(path)
        book = (books[File.expand_path(basedir)] ||= Book.load(basedir))
        begin
          book.chapter(File.basename(path, '.*'))
        rescue KeyError => err
          raise FileNotFound, "no such file: #{path}"
        end
      }
    end

    def Chapter.for_stdin
      new(nil, nil, '-', nil, $stdin)
    end

    def Chapter.for_path(number, path)
      new(nil, number, File.basename(path), path)
    end

    def initialize(book, number, name, path, io = nil)
      @book = book
      @number = number
      @name = name
      @path = path
      @io = io
      @title = nil
      @content = nil
      @list_index = nil
      @table_index = nil
      @footnote_index = nil
      @image_index = nil
      @icon_index = nil
      @numberless_image_index = nil
      @indepimage_index = nil
      @headline_index = nil
    end

    def env
      @book
    end

    def inspect
      "\#<#{self.class} #{@number} #{@path}>"
    end

    attr_reader :book
    attr_reader :number
    attr_reader :path

    def dirname
      return nil unless @path
      File.dirname(@path)
    end

    def basename
      return nil unless @path
      File.basename(@path)
    end

    def name
      File.basename(@name, '.*')
    end

    alias id name

    def title
      @title = ""
      open {|f|
        f.each_line {|l|
          if l =~ /\A=+/
            @title = l.sub(/\A=+/, '').strip
            break
          end
        }
      }
      if ReVIEW.book.param["inencoding"] =~ /^EUC$/
        @title = NKF.nkf("-E -w", @title)
      elsif ReVIEW.book.param["inencoding"] =~ /^SJIS$/
        @title = NKF.nkf("-S -w", @title)
      elsif ReVIEW.book.param["inencoding"] =~ /^JIS$/
        @title = NKF.nkf("-J -w", @title)
      else
        @title = NKF.nkf("-w", @title)
      end
    end

    def size
      File.size(path())
    end

    def volume
      @volume ||= Volume.count_file(path())
    end

    def open(&block)
      return (block_given?() ? yield(@io) : @io) if @io
      File.open(path(), &block)
    end

    def content
      if ReVIEW.book.param["inencoding"] =~ /^EUC$/i
        @content = NKF.nkf("-E -w", File.read(path()))
      elsif ReVIEW.book.param["inencoding"] =~ /^SJIS$/i
        @content = NKF.nkf("-S -w", File.read(path()))
      elsif ReVIEW.book.param["inencoding"] =~ /^JIS$/i
        @content = NKF.nkf("-J -w", File.read(path()))
      else
        @content = NKF.nkf("-w", File.read(path())) # auto detect
      end
    end

    def lines
      # FIXME: we cannot duplicate Enumerator on ruby 1.9 HEAD
      (@lines ||= content().lines.to_a).dup
    end

    def list(id)
      list_index()[id]
    end

    def list_index
      @list_index ||= ListIndex.parse(lines())
      @list_index
    end

    def table(id)
      table_index()[id]
    end

    def table_index
      @table_index ||= TableIndex.parse(lines())
      @table_index
    end

    def footnote(id)
      footnote_index()[id]
    end

    def footnote_index
      @footnote_index ||= FootnoteIndex.parse(lines())
      @footnote_index
    end

    def image(id)
      return image_index()[id] if image_index().has_key?(id)
      return icon_index()[id] if icon_index().has_key?(id)
      return numberless_image_index()[id] if numberless_image_index().has_key?(id)
      indepimage_index()[id]
    end

    def numberless_image_index
      @numberless_image_index ||=
        NumberlessImageIndex.parse(lines(), id(),
                                   "#{book.basedir}#{@book.image_dir}",
                                   @book.image_types)
    end

    def image_index
      @image_index ||= ImageIndex.parse(lines(), id(),
                                        "#{book.basedir}#{@book.image_dir}",
                                        @book.image_types)
      @image_index
    end

    def icon_index
      @icon_index ||= IconIndex.parse(lines(), id(),
                                        "#{book.basedir}#{@book.image_dir}",
                                        @book.image_types)
      @icon_index
    end

    def indepimage_index
      @indepimage_index ||=
        IndepImageIndex.parse(lines(), id(),
                                   "#{book.basedir}#{@book.image_dir}",
                                   @book.image_types)
    end

    def bibpaper(id)
      bibpaper_index()[id]
    end

    def bibpaper_index
      raise FileNotFound, "no such bib file: #{@book.bib_file}" unless @book.bib_exist?
      @bibpaper_index ||= BibpaperIndex.parse(@book.read_bib.lines.to_a)
      @bibpaper_index
    end

    def headline(caption)
      headline_index()[caption]
    end

    def headline_index
      @headline_index ||= HeadlineIndex.parse(lines(), self)
    end

    def on_CHAPS?
      @book.read_CHAPS().lines.map(&:strip).include?(id() + @book.ext())
    end
  end
end
