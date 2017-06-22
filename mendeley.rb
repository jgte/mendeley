#!/usr/bin/env ruby
require 'rubygems'
require 'sqlite3'
require 'pp'
require 'yaml'
require 'uri'
require 'fileutils'
require 'digest'
require "i18n"

#NOTICE: sqlite3 gem can (only?) be installed in ubuntu with 'sudo apt-get install libsqlite3-dev' and only then 'sudo gem install sqlite3'

# https://gist.github.com/ChuckJHardySnippets/2000623
class String
  def to_b
    return true   if self == true   || self =~ (/(true|t|yes|y|1)$/i)
    return false  if self == false  || self.blank? || self =~ (/(false|f|no|n|0)$/i)
    raise ArgumentError.new("invalid value for Boolean: \"#{self}\"")
  end
end

# https://stackoverflow.com/questions/18358717/ruby-elegantly-convert-variable-to-an-array-if-not-an-array-already
class  Object;    def  ensure_array;  [self]  end  end
class  Array;     def  ensure_array;  to_a    end  end
class  NilClass;  def  ensure_array;  to_a    end  end

class LibUtils

  def LibUtils.calling_methods(debugdeep=false)
    LibUtils.peek(caller.join("\n"),'caller.join("\n")',debugdeep)
    out=Array.new
    caller[1..-1].each do |c|
      c1=c.to_s.slice(/`.*'/)
      out.push(c1[1...-1].sub("block in ","")) unless c1.nil?
    end
    LibUtils.peek(out.join("\n"),'out.join("\n")',debugdeep)
    return out
  end

  @TABLEN=50
  @NAMLEN=20
  @VARLEN=24

  def LibUtils.peek(var,varname,disp=true,args=Hash.new)
    return unless disp
    args={
      :show_caller    => true,
      :return_string  => false,
    }.merge(args)
    if args[:show_caller]
      caller_str=caller[0].split("/")[-1]
    else
      caller_str=nil
    end
    out =              caller_str.ljust(@TABLEN)+" : "
    out+=            varname.to_s.ljust(@NAMLEN)+" : "
    case var
    when Hash
      out+=var.pretty_inspect.chomp.ljust(@VARLEN)+" : "
    when Array
      out+=var.join(',').ljust(@VARLEN)+" : "
    else
      if var.to_s.nil?
        out+="to_s returned nil!".ljust(@VARLEN)+" : "
      else
        out+=var.to_s.ljust(@VARLEN)+" : "
      end
    end
    out+=var.class.to_s
    if args[:return_string]
      return out
    else
      puts out
    end
  end

  def LibUtils.natural_sort(x)
    return x.ensure_array.sort_by {|e| e.split(/(\d+)/).map {|a| a =~ /\d+/ ? a.to_i : a }}
  end

end

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

  def Utils.clean_filename(f)
    return f.
      gsub(' ','\ ').
      gsub('(','\(').
      gsub(')','\)').
      gsub(':','\:').
      gsub('@','\@').
      gsub("'","*")
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

#https://stackoverflow.com/questions/7749568/how-can-i-do-standard-deviation-in-ruby
module Enumerable
  def sum
    # self.inject(0){|accum, i| accum + i }
    self.inject(:+)
  end

  def mean
    self.sum/self.length.to_f
  end

  def sample_variance
    m = self.mean
    sum = self.inject(0){|accum, i| accum +(i-m)**2 }
    sum/(self.length - 1).to_f
  end

  def std
    return Math.sqrt(self.sample_variance)
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
        @db = SQLite3::Database.open(filename)
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

  class FileDetails
    attr_reader :name
    attr_reader :dirname
    attr_reader :basename
    attr_reader :filename
    attr_reader :extension
    attr_reader :iscomp
    attr_reader :isexist
    attr_reader :size
    attr_accessor :hash
    attr_reader :dbentry
    attr_reader :dbentry_checked
    attr_reader :tlname
    attr_reader :url
    attr_reader :dbname
    attr_reader :isadded
    attr_reader :dbhash
    attr_reader :dburl
    PROTOCAL_SEP='://'
    VALID_EXTENSION=["pdf","bin","ps","html","sh"]
    def FileDetails.filename2url(filename,protocol="file")
      protocol+PROTOCAL_SEP+URI.escape(filename)
    end
    def FileDetails.url2filename(url)
      tmp=URI.unescape(url).split(PROTOCAL_SEP)
      protocol=tmp[0]
      filename=tmp[1]
      return filename,protocol
    end
    def initialize(args)
      raise RuntimeError,"Mendeley.FileDetails: need either :filename or :url", caller if args[:filename].nil? & args[:url].nil?
      if args[:url].nil?
        @name=args[:filename]
      else
        @url=args[:url]
        @name,protocol=FileDetails.url2filename(@url)
      end
      @hash=args[:hash] unless args[:hash].nil?
      @dbentry_checked=false
    end
    def dirname
      @dirname=File.expand_path(File.dirname(@name)) if @dirname.nil?
      @dirname
    end
    def basename
      @basename=File.basename(@name) if @basename.nil?
      @basename
    end
    def filename
      @filename=self.dirname+'/'+self.basename if @filename.nil?
      @filename
    end
    def extension
      if @extension.nil?
        @extension=self.basename.split('.')[-1]
        @extension=nil unless VALID_EXTENSION.include?(@extension)
      end
      @extension
    end
    def comp?
      @iscomp=COMPDB.include?(self) if @iscomp.nil?
    end
    def compname
      self.tlname
    end
    def exist?
      @isexist=File.exist?(self.filename) if @isexist.nil?
      @isexist
    end
    def size
      @size=(self.exist? ? File.stat(self.filename).size : -1) if @size.nil?
      @size
    end
    def hash
      @hash=(self.exist? ? Digest::SHA1.file(self.filename).hexdigest : nil) if @hash.nil?
      @hash
    end
    def tlname
      if @tlname.nil?
        I18n.config.available_locales = :en
        begin
          @tlname=I18n.transliterate(self.basename).gsub('?','')
        rescue
          @tlname=self.basename
        end
      end
      @tlname
    end
    def url
      @url=FileDetails.filename2url(self.filename) if @url.nil?
      @url
    end
    def baseurl
      File.basename(self.url)
    end
    def dbentry
      unless @dbentry_checked
        @dbentry=MENDTBL.find({:hash    =>self.hash})
        @dbentry=MENDTBL.find({:basename=>self.basename}) if @dbentry.nil?
        @dbentry=MENDTBL.find({:baseurl =>self.baseurl} ) if @dbentry.nil?
        @isadded= ! @dbentry.nil?
        if @isadded
          @dbhash= @dbentry.hash
          @dburl = @dbentry.url
        end
        @dbentry_checked=true
      end
      @dbentry
    end
    def added?
      self.dbentry unless @dbentry_checked
      @isadded
    end
    def dbhash
      self.dbentry unless @dbentry_checked
      @dbhash
    end
    def dburl
      self.dbentry unless @dbentry_checked
      @dburl
    end
    def to_s
      "\nname   : #{@name}\n"+
      "basename : #{self.basename}\n"+
      "dirname  : #{self.dirname}\n"+
      "filename : #{self.filename}\n"+
      "url      : #{self.url}\n"+
      "comp?    : #{self.comp?}\n"+
      "exist?   : #{self.exist?}\n"+
      "size     : #{self.size}\n"+
      "hash     : #{self.hash}\n"+
      "tlname   : #{self.tlname}\n"+
      "dbentry  : #{self.dbentry}\n"+
      "added?   : #{self.added?}\n"+
      "dbhash   : #{self.dbhash}\n"+
      "dburl    : #{self.dburl}\n"
    end
  end

  class TableFiles
    attr_reader :list
    def initialize(mendeley_db)
      @list=mendeley_db.table("Files")
      @list.map!{ |f| FileDetails.new({:url=>f["localUrl"],:hash=>f["hash"]}) }
    end
    def to_s
      @list.map{ |f| f.basename }.sort
    end
    def each
      @list.each{|f| yield f}
    end
    def find(args)
      unless args[:hash].nil?
        @list.each do |f|
           # puts f.hash+' '+f.filename
          return f if f.hash==args[:hash]
        end
      end
      unless args[:basename].nil?
        @list.each do |f|
          # puts "--\n"+f.basename+"\n"+args[:basename] if f.basename[0..5]==args[:basename][0..5]
          return f if f.basename==args[:basename]
        end
      end
      unless args[:baseurl].nil?
        @list.each do |f|
          # puts "--\n"+File.basename(f.url)+"\n"+args[:baseurl] if File.basename(f.url)[0..5]==args[:baseurl][0..5]
          return f if File.basename(f.url)==args[:baseurl]
        end
      end
      return nil
    end
  end

  class CompDB
    attr_reader :db
    attr_reader :filename
    def initialize(filename)
      @filename=filename
      if ! File.exist?(filename)
        @db=Array.new
      else
        #backup db
        FileUtils.cp(filename,filename.sub('.txt','.'+Time.now.strftime("%Y%m%d-%H%M%S")+'.txt'))
        @db=File.open(filename, 'rb') { |f| f.read }.split("\n")
      end
    end
    def include?(f)
      @db.include?(f.compname)
    end
    def add(f)
      @db << f.compname
      return self
    end
    def remove(f)
      @db.delete(f.compname)
      return self
    end
    def save(filename=@filename)
      raise "Need a valid filename to save the compressed file list." if filename.nil?
      File.open(filename, 'w') { |f| f.write(@db.join("\n")) }
      return self
    end
  end

  def Mendeley.debug(message,always_show_msg=false)
    raise RuntimeError,"Mendeley.debug: need a block. Debug needed!", caller unless block_given?
    puts message if DRYRUN || always_show_msg
    yield unless DRYRUN
  end

  def Mendeley.rename(f_old,f_new,rename_file=true,rename_mendeley=true)
    msg="From #{f_old.filename}\nTo   #{f_new.filename}"
    unless BATCH
      m="Renaming"
      m+=" files" if rename_file
      m+=" and" if rename_file & rename_mendeley
      m+=" DB" if rename_mendeley
      m+=":\n"+msg+"\nContinue? [Y/n]"
      puts m
      return if STDIN.gets.chomp.downcase == "n"
    end
    if rename_file
      #sanity
      raise RuntimeError,"Mendeley.rename: hash must be the same in old and new url (variable f_old and f_new).",
        caller unless f_old.hash==f_new.hash
      raise RuntimeError,"Mendeley.rename: Could not find file #{f_old.filename}, cannot rename.",
        caller unless f_old.exist?
      begin
        Mendeley.debug("rename file:\n"+msg) do
          FileUtils.mv(f_old.filename,f_new.filename,{:force=>true,:verbose=>true})
        end
      rescue
        puts "WARNING: Mendeley.rename: Could not rename #{f_old.filename}."
      end
    end
    if rename_mendeley
      Mendeley.debug("rename DB:\n"+msg,true) do
        MENDDB.change("Files",{"hash" => f_new.hash},{"localUrl" => f_new.url.gsub("'","''")})
      end
    end
  end

  def Mendeley.rehash(f_old,f_new)
    msg="From : #{f_old.hash} : #{f_old.filename}\nTo   : #{f_old.hash} : #{f_new.filename}"
    unless BATCH
      puts "rehashing:\n"+msg+"\nContinue? [Y/n]"
      return if STDIN.gets.chomp.downcase == "n"
    end
    raise RuntimeError,"Mendeley.rehash: name must be the same in old and new url (variable f_old and f_new).",
      caller unless f_old.filename==f_new.filename
    Mendeley.debug("rehashing:\n"+msg,true) do
      MENDDB.change("Files",{"localUrl" => f_new.url.gsub("'","''")},{"hash" => f_new.hash})
    end
  end

  def Mendeley.fix_extension
    MENDTBL.each do |f|
      case f.extension
      when NilClass
        #add pdf extension if there is no extension
        f_new=FileDetails.new({:url=>f.url+".pdf",:hash=>f.hash})
        Mendeley.rename(f,f_new)
      when "bin"
        #replace bin extension with pdf
        f_new=FileDetails.new({:url=>f.url.sub(/\.bin$/,".pdf"),:hash=>f.hash})
        Mendeley.rename(f,f_new)
      when "pd"
        #replace bin extension with pdf
        f_new=FileDetails.new({:url=>f.url.sub(/\.pd$/,".pdf"),:hash=>f.hash})
        Mendeley.rename(f,f_new)
      end
    end
    files=`ls | egrep -v '(.pdf$|.ps$|.html$|.sh$|.rb$|.txt$|.uncompressed|^papers.sublime-*)'`.chomp.split("\n")
    return if files.empty?
    Mendeley.debug("The following files are going to be deleted:\n#{files.join("\n")}",true) do
      puts "Continue? [Y/n]"
      FileUtils.remove(files) unless STDIN.gets.chomp.downcase == "n"
    end
  end

  def Mendeley.remove_parenthesis
    MENDTBL.each do |f|
      if f.url =~ /\(\d\)/
        #remove number between brackets
        f_new=FileDetails.new({:url=>f.url.sub(/\(\d\)/,''),:hash=>f.hash})
        #rename only if the un-parenthesised name is not present in the mendeley DB
        next unless MENDTBL.find({:url=>f_new.url}).nil?
        Mendeley.rename(f,f_new)
      end
    end
    #invalid byte sequence in US-ASCII (Argument Error)
    #put this in .profile:
    # export LANG=en_US.UTF-8
    # export LANGUAGE=en_US.UTF-8
    # export LC_ALL=en_US.UTF-8
    # https://stackoverflow.com/questions/17031651/invalid-byte-sequence-in-us-ascii-argument-error-when-i-run-rake-dbseed-in-ra
  end

  #NOTICE: This is not working, possibly because cannot change hashes outside of mendeley
  def Mendeley.switch_to_compressed_pdf(f)
    LibUtils.peek(f,"in:f",DEBUG)
    #get this file entry in the mendeley DB
    f_old=MENDTBL.find({:basename=>f.basename})
    LibUtils.peek(f_old,"f_old",DEBUG)
    raise RuntimeError,"Cannot find #{f.basename} in the Mendeley DB" if f_old.nil?
    #update hash
    f_new=f_old
    f_new.hash=f.hash
    LibUtils.peek(f_new,"f_new",DEBUG)
    #update database
    Mendeley.rehash(f_old,f_new)
  end

  # screen ebook printer prepress default
  PDFSETTINGS_DEFAULT="ebook"

  def Mendeley.compress_pdf(fin)
    #skip compressed PDFs
    return if fin.comp?
    #compressed filename
    fout="#{fin.filename}.compressed"
    #user feedback
    puts "Compressing #{fin.basename}"
    #compress it
    com="gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/#{PDFSETTINGS_DEFAULT} -dNOPAUSE -dQUIET -dBATCH "+
      "-sOutputFile=\"#{fout}\" \"#{fin.filename}\""
    LibUtils.peek(com,'com',DEBUG)
    unless BATCH
      puts "Continue? [Y/n]"
      return if STDIN.gets.chomp.downcase == "n"
    end
    #if this is debug, we're done
    return if DRYRUN
    #execute ghostscript call
    out=`#{com}`.chomp
    #check if succeeded
    if (File.exist?(fout) && $? == 0)
      #gather sizes of original and compressed PDFs
      delta,finsize,foutsize=Mendeley.compress_gain(fin.filename,fout)
      #user feedback
      puts "Original  : "+((finsize /1024).to_s+"Kb").rjust(8)+"\n" +
           "Compressed: "+((foutsize/1024).to_s+"Kb").rjust(8)+", "+('%.2f' % (foutsize.to_f/finsize.to_f*100)+"%").rjust(8)+"\n" +
           "Delta     : "+((delta   /1024).to_s+"Kb").rjust(8)+", "+('%.2f' % (   delta.to_f/finsize.to_f*100)+"%").rjust(8)
      #if compressed size is larger or only slightly smaller, then keep original
      if delta/1024 >= -10
        puts "Keeping original, not enough or unfavorable gain"
        File.delete(fout)
      else
        #if compressed size is smaller, replace it in the mendelet DB
        FileUtils.mv(fin.filename, fin.filename+".uncompressed",{:force=>true,:verbose=>false})
        FileUtils.mv(fout,         fin.filename,                {:force=>true,:verbose=>false})
        # Mendeley.switch_to_compressed_pdf(fin)
      end
      #either way, add this file to the compressed DB
      COMPDB.add(fin).save
    end
  end

  def Mendeley.all_compress_pdf
    #get list of PDFs
    Dir.glob("*.pdf",File::FNM_CASEFOLD).each do |f|
      Mendeley.compress_pdf(FileDetails.new(:filename=>f))
    end
  end

  def Mendeley.compress_gain(fin,fout)
    finsize =File.stat(fin).size
    foutsize=File.stat(fout).size
    delta=foutsize-finsize
    return delta,finsize,foutsize
  end

  def Mendeley.operation_dialogue(f,op,reason)
    case op
    when :delete
      op_str="Deleting"
    when :zero
      op_str="Zeroing"
    else
      raise RuntimeError,"Unknown op #{op}"
    end
    Mendeley.debug(op_str+" the file below because "+reason+":\n"+f.filename+"\n",true) do
      unless BATCH
        puts "Continue? [Y/n]"
        continue=(STDIN.gets.chomp.downcase != "n")
      else
        continue=true
      end
      if continue
        case op
        when :delete
          File.delete(f.filename)
        when :zero
          File.open(f.filename, "w") {}
        end
      end
    end
  end

  def Mendeley.clean_orphan_files
    #inits
    tab=24
    #loop over all files
    Dir.foreach('.') do |f|
      #skip directories
      if File.directory?(f)
        reason='directory'
        puts "Skipping: "+reason.rjust(tab)+": "+f if VERBOSE
        next
      end
      #skip irrelevant files
      skip=false
      [".sh$",".rb$","^papers.sublime","^.DS",".ruby-version",".txt$"].each do |fp|
        if f=~Regexp.new(fp)
          skip=true
          break
        end
      end
      if skip
        reason='irrelevant'
        puts "Skipping: "+reason.rjust(tab)+": "+f if VERBOSE
        next
      end
      #init object
      fd=FileDetails.new({:filename => f})
      #skip non-existing files
      unless fd.exist?
        reason='file disappeard'
        puts "Skipping: "+reason.rjust(tab)+": "+f if VERBOSE
        next
      end
      #look for this file in the mendeley database
      if ! fd.added?
        LibUtils.peek(fd,'fd',DEBUG)
        Mendeley.operation_dialogue(fd,:delete,reason="it is not part of Mendeley")
        next
      end
    end
  end

end

DATABASE="J.G.deTeixeiradaEncarnacao@tudelft.nl@www.mendeley.com.sqlite"

if OS.linux?
  FILENAME="#{ENV['HOME']}/.local/share/data/Mendeley Ltd./Mendeley Desktop/#{DATABASE}"
elsif OS.mac?
  FILENAME="#{ENV['HOME']}/Library/Application\ Support/Mendeley\ Desktop/#{DATABASE}"
else
  raise RuntimeError,"Cannot determine OS type"
end

MENDDB=SQLite::SQLdb.new(FILENAME)
MENDTBL=Mendeley::TableFiles.new(MENDDB)
COMPDB=Mendeley::CompDB.new("compressed_files.txt")

DRYRUN=ARGV.include?('dryrun') || ARGV.include?('dry-run')
DEBUG=ARGV.include?('debug')
VERBOSE=ARGV.include?('verbose')
BATCH=ARGV.include?('batch')

Mendeley.fix_extension if ARGV.include?('extension')
Mendeley.remove_parenthesis if ARGV.include?('parenthesis')
Mendeley.clean_orphan_files if ARGV.include?('orphans')
Mendeley.all_compress_pdf if ARGV.include?('compress')


