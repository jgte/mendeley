#!/usr/bin/ruby
require 'rubygems'
require 'sqlite3'
require 'pp'
require 'yaml'
require 'uri'
require 'fileutils'

#NOTICE: sqlite3 gem can (only?) be installed in ubuntu with 'sudo apt-get install libsqlite3-dev' and only then 'sudo gem install sqlite3'

module Utils

  def Utils.tictoc(msg,disp_flag=true)
    raise RuntimeError,"Utils:tictoc can only be called from as a block. Debug needed!", caller unless block_given?
    if disp_flag
      tic = Time.now
      yield
      puts "#{msg}#{Time.now - tic} seconds."
    else
      yield
    end
  end

end

#https://stackoverflow.com/questions/170956/how-can-i-find-which-operating-system-my-ruby-program-is-running-on
module OS
  def OS.windows?
    (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
  end

  def OS.mac?
   (/darwin/ =~ RUBY_PLATFORM) != nil
  end

  def OS.unix?
    !OS.windows?
  end

  def OS.linux?
    OS.unix? and not OS.mac?
  end
end

module SQLite

  def SQLite.version
    begin
      db = SQLite3::Database.new ":memory:"
      return db.get_first_value 'SELECT SQLITE_VERSION()'
    rescue SQLite3::Exception => e
        puts "Exception occured"
        puts e
    ensure
        db.close if db
    end
  end

  class SQLdb

    attr_reader :db
    attr_reader :tables

    def sanity
      raise RuntimeError,"SQLite::SQLdb.sanity: need a block. Debug needed!", caller unless block_given?
      begin
        yield
      rescue SQLite3::Exception => e
        puts "Exception occured"
        puts e
      end
    end

    def initialize(filename)
      sanity do
        @db = SQLite3::Database.open filename
        @tables=Array.new
        tmp = db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
        tmp.each do |t|
          if t.length==1
            @tables.push(t[0])
          else
            raise RuntimeError,"SQLite::SQLdb.initialize: found a table with more than one entry. Debug needed!", caller
          end
        end
      end
    end

    def close
      @db.close if @db
    end

    def table_info(table)
      sanity do
        db.prepare("PRAGMA table_info('#{table}')").execute
      end
    end

    PADLEN=2

    def to_s
      struct=Hash.new
      collen=Array.new(7,0)
      @tables.each do |t|
        #init
        struct[t] = Array.new
        #updated column lengths
        collen[0]=[collen[0],t.length].max
        #retrieving table info
        table_info(t).each do |ti|
          struct[t].push(ti)
        end
        #updated column lengths: looping over rows
        struct[t].each do |ti|
          #sanity
          raise RuntimeError,"SQLite::SQLdb.to_s: expecting number of metadata columns to be #{collen.length-1} " +
            "but the metadata of table #{t} has #{ti.length} columns. Debug needed!", caller unless ti.length==(collen.length-1)
          #looping over columns
          ti.each_index do |i|
            # puts "ti[#{i}]=#{ti[i]}, class=#{ti[i].class}, collen[#{i+1}]=#{collen[i+1]}, class=#{collen[i+1].class}"
            collen[i+1]=[collen[i+1],ti[i].to_s.length].max unless ti[i].nil?
          end
        end
      end
      #building output string
      out=String.new
      struct.each do |k,v|
        #looping over rows
        v.each do |ti|
          out+=k.ljust(collen[0]+PADLEN)
          #looping over columns
          ti.each_index do |i|
            out+=ti[i].to_s.ljust(collen[i+1]+PADLEN)
          end
          out+="\n"
        end
      end
      #printing
      return out
    end

    def table(name)
      raise RuntimeError,"SQLite::SQLdb.table: unknown table #{name}", caller unless @tables.include?(name)
      out=Array.new
      sanity do
        @db.results_as_hash = true
        @db.prepare("SELECT * FROM #{name}").execute.each do |r|
          out.push(r)
        end
        @db.results_as_hash = false
      end
      return out
    end

    def change(table_name,where,changed)
      raise RuntimeError,"SQLite::SQLdb.table: unknown table #{name}", caller unless @tables.include?(table_name)
      raise RuntimeError,"SQLite::SQLdb.table: input 'where' must be a Hash, not a #{where.class}", caller unless where.is_a?(Hash)
      raise RuntimeError,"SQLite::SQLdb.table: input 'changed' must be a Hash, not a #{changed.class}", caller unless changed.is_a?(Hash)
      raise RuntimeError,"SQLite::SQLdb.table: input 'changed' and 'where' must have the same number of elements.",
        caller unless changed.length==where.length
      #don't do anything with Mendeley open
      begin
        out="Unknown OS"
        out=`ps -eF | grep    mendeley | grep -v grep | grep -v mendeley.rb`.chomp if OS.linux?
        out=`ps -e  | grep -i mendeley | grep -v grep | grep -v mendeley.rb`.chomp if OS.mac?
        mendeleyclosed=( out.length == 0 )
        break if mendeleyclosed
        puts "Mendeley is running:\n#{out}\nClose it first.\nContinue? [Y/n]"
        exit if STDIN.gets.chomp.downcase == "n"
      end until mendeleyclosed
      #unwrapping keys and values
      where_keys=where.keys
      where_values=where.values
      changed_keys=changed.keys
      changed_values=changed.values
      sanity do
        @db.transaction
        where_keys.each_index do |i|
          com="UPDATE #{table_name} SET #{changed_keys[i]}='#{changed_values[i]}' WHERE #{where_keys[i]}='#{where_values[i]}'"
          puts com
          @db.prepare(com).execute
        end
        @db.commit
      end
    end


  end

end

module Mendeley

  FILENAME="../j.g.deteixeiradaencarnacao@tudelft.nl@www.mendeley.com.sqlite"

  DB=SQLite::SQLdb.new(FILENAME)

  class LocalUrl
    attr_reader :localUrl
    attr_reader :protocol
    attr_reader :dirname
    attr_reader :basename
    attr_reader :extension
    attr_reader :hash
    PROTOCAL_SEP='://'
    VALID_EXTENSION=["pdf","bin","ps","html","sh"]
    def initialize(url,hash)
      @localUrl=url
      tmp=URI.unescape(@localUrl).split(PROTOCAL_SEP)
      @protocol=tmp[0]
      @dirname=File.dirname(tmp[1])
      @basename=File.basename(tmp[1])
      @extension=@basename.split('.')[-1]
      @extension=nil unless VALID_EXTENSION.include?(@extension)
      @basename=@basename.sub(/\.#{@extension}$/,'') unless @extension.nil?
      @hash=hash
    end
    def to_s
      "hash     = #{@hash}\n" +
      "localUrl = #{@localUrl}\n" +
      "protocol = #{protocol}\n" +
      "dirname  = #{dirname}\n" +
      "basename = #{basename}\n" +
      "extension= #{extension}"
    end
    def filename
      out= @dirname + "/" +  @basename
      out+='.' + @extension unless @extension.nil?
      return out
    end
  end

  class TableFiles
    attr_reader :list
    def initialize(db)
      @list=DB.table("Files")
      @list.map!{ |f| LocalUrl.new(f["localUrl"],f["hash"]) }
    end
    def to_s
      @list.map{ |f| "---\n" + f.to_s }
    end
    def each
      @list.each{|f| yield f}
    end
  end

  def Mendeley.debug(message,debug_flag)
    raise RuntimeError,"Mendeley.debug: need a block. Debug needed!", caller unless block_given?
    if debug_flag
      puts message
    else
      yield
    end
  end

  def Mendeley.rename(old_lu,new_lu)
    debug_flag=false
    #sanity
    raise RuntimeError,"Mendeley.rename: hash must be the same in old and new localUrl (variable old_lu and new_lu).",
      caller unless old_lu.hash==new_lu.hash
    if File.exist?(old_lu.filename)
      begin
        Mendeley.debug("rename:\n#{old_lu.filename}\n#{new_lu.filename}",debug_flag) do
          File.rename(old_lu.filename,new_lu.filename)
        end
      rescue
        raise RuntimeError,"Mendeley.rename: Could not rename #{old_lu.filename}.", caller
      end
      Mendeley.debug("update:#{old_lu.hash}\n#{old_lu.localUrl}\n#{new_lu.localUrl}",debug_flag) do
        DB.change("Files",{"hash" => old_lu.hash},{"localUrl" => new_lu.localUrl.gsub("'","''")})
      end
    else
      raise RuntimeError,"Mendeley.fix_extension: Could not find file #{old_lu.filename}, cannot rename.", caller
    end
  end

  def Mendeley.fix_extension
    TableFiles.new(DB).each do |f|
      case
      when f.extension.nil?
        #add pdf extension if there is no extension
        new_lu=LocalUrl.new(f.localUrl+".pdf",f.hash)
        Mendeley.rename(f,new_lu)
      when f.extension == "bin"
        #replace bin extension with pdf
        new_lu=LocalUrl.new(f.localUrl.sub(/\.bin$/,".pdf"),f.hash)
        Mendeley.rename(f,new_lu)
      end
    end
    files=`ls | egrep -v '(.pdf$|.ps$|.html$|.sh$|.rb$|^papers.sublime-*)'`.chomp.split("\n")
    unless files.empty?
      puts "The following files are going to be deleted:\n#{files.join("\n")}\nContinue? [Y/n]"
      FileUtils.remove(files) unless STDIN.gets.chomp.downcase == "n"
    end
  end

  def Mendeley.remove_parentheses
    TableFiles.new(DB).each do |f|
      if f.basename =~ /\(\d\)/
        #remove number between brackets
        new_lu=LocalUrl.new(f.localUrl.sub(/\(\d\)/,''),f.hash)
        Mendeley.rename(f,new_lu)
      end
    end
    #invalid byte sequence in US-ASCII (Argument Error)
    #put this in .profile:
    # export LANG=en_US.UTF-8
    # export LANGUAGE=en_US.UTF-8
    # export LC_ALL=en_US.UTF-8
    # https://stackoverflow.com/questions/17031651/invalid-byte-sequence-in-us-ascii-argument-error-when-i-run-rake-dbseed-in-ra
    files=`find . -name \\*\\([0-9]\\)\\*`.chomp.split("\n")
    unless files.empty?
      puts "The following files are going to be deleted:\n#{files.join("\n")}\nContinue? [Y/n]"
      FileUtils.remove(files) unless STDIN.gets.chomp.downcase == "n"
    end
  end

  # screen ebook printer prepress default
  PDFSETTINGS_DEFAULT="ebook"

  def Mendeley.compress_pdf
    #get list of PDFs
    Dir.glob("*.pdf",File::FNM_CASEFOLD) do |fin|
      #skip compressed PDFs
      next if fin =~ /compressed\.pdf$/i
      #compressed PDF filename
      fout=Mendeley.compress_filename(fin)
      #skip if this PDF is already compressed
      next if File.exist?(fout)
      #user feedback
      puts "Compressing #{fin}:"
      #compress it
      com="gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/#{PDFSETTINGS_DEFAULT} -dNOPAUSE -dQUIET -dBATCH -sOutputFile=\"#{fout}\" \"#{fin}\""
      puts com
      out=`#{com}`.chomp
      #check if succeeded
      if (File.exist?(fout) && $? == 0)
        #gather sizes of original and compressed PDFs
        delta,finsize,foutsize=Mendeley.compress_gain(fin)
        #user feedback
        puts "Original  : #{finsize/1024}Kb\n" +
             "Compressed: #{foutsize/1024}Kb (#{'%.2f' % (foutsize.to_f/finsize.to_f*100)}%)\n" +
             "Gain      :#{delta/1024}Kb (#{'%.2f' % (delta.to_f/finsize.to_f*100)}%)"
        #create empty file if compressed size is larger
        File.open(fout, "w") {} if delta > 0
      else
        #create empty file
        File.open(fout, "w") {}
      end
    end
  end

  def Mendeley.compress_filename(f)
    f.sub('.pdf','-compressed.pdf')
  end

  def Mendeley.compress_gain(f)
    finsize =File.stat(f).size
    foutsize=File.stat(Mendeley.compress_filename(f)).size
    delta=foutsize-finsize
    return delta,finsize,foutsize
  end

  PADDING=[12,12,12,60]

  #TODO: check if there are notes in the PDFs
  def Mendeley.compressed_pdf_report
    rec=Hash.new
    #get list of PDFs
    Dir.glob("*.pdf",File::FNM_CASEFOLD) do |fin|
      #skip compressed PDFs
      next if fin =~ /compressed\.pdf$/i
      #skip if compressed PDF has zero size
      next if File.stat(Mendeley.compress_filename(fin)).size == 0
      #save size gain
      rec[fin]=Mendeley.compress_gain(fin)
    end
    #get the top-most space-saving compressions
    out=rec.sort_by{ |file,size| size }[0..9]
    #user feedback
    puts "Delta".rjust(PADDING[0])+"Original".rjust(PADDING[1])+"Compressed".rjust(PADDING[2])+"   "+"Filename".ljust(PADDING[3])
    out.each do |o|
      puts  (o[1][0]/1024).to_s.rjust(PADDING[0])+
            (o[1][1]/1024).to_s.rjust(PADDING[1])+
            (o[1][2]/1024).to_s.rjust(PADDING[2])+
            "   "+
            o[0].ljust(PADDING[3])
    end
    return out[0][0]
  end

end

Mendeley.fix_extension
Mendeley.remove_parentheses
Mendeley.compress_pdf
fdel=Mendeley.compressed_pdf_report
puts "Delete #{fdel}? [Y/n]"
exit 3 if STDIN.gets.chomp.downcase == "n"
File.delete(fdel)