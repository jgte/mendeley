#!/usr/bin/ruby
require 'rubygems'
require 'sqlite3'
require 'pp'
require 'yaml'
require 'uri'
require 'fileutils'
require 'clipboard'
require 'digest'
require "i18n"

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
      begin
        @dirname=File.dirname(tmp[1])
        @basename=File.basename(tmp[1])
        @extension=@basename.split('.')[-1]
        @extension=nil unless VALID_EXTENSION.include?(@extension)
        @basename=@basename.sub(/\.#{@extension}$/,'') unless @extension.nil?
      rescue
        @dirname=''
        @basename=''
        @extension=nil
      end
      begin
        @hash=hash
      rescue
        @hash=''
      end
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
    def find(hash)
      @list.each do |f|
        return f if f.hash==hash
      end
      return nil
    end
  end

  class CompUncoPair
    attr_reader :root
    attr_reader :path
    attr_reader :comp
    attr_reader :unco
    def CompUncoPair.get_details(filename,db)
      if File.exist?(filename)
        return {
          :name => filename,
          :size => File.stat(filename).size,
          :added => ! db.find(Digest::SHA1.file(filename).hexdigest).nil?,
          :exist => true,
        }
      else
        return {
          :name => filename,
          :size => -1,
          :added => false,
          :exist => false,
        }
      end
    end
    def initialize(filename,db)
      @root=File.basename(filename).sub(/.pdf$/i,'').sub(/-compressed$/i,'')
      @path=File.dirname(filename)
      @unco=CompUncoPair.get_details("#{@path}/#{root}.pdf",db)
      @comp=CompUncoPair.get_details("#{@path}/#{root}-compressed.pdf",db)
    end


  end

  def Mendeley.debug(message,debug_flag,always_show_msg=false)
    raise RuntimeError,"Mendeley.debug: need a block. Debug needed!", caller unless block_given?
    puts message if debug_flag || always_show_msg
    yield unless debug_flag
  end

  def Mendeley.rename(old_lu,new_lu,debug_flag=false,rename_file=true,rename_mendeley=true)
    if rename_file
      #sanity
      raise RuntimeError,"Mendeley.rename: hash must be the same in old and new localUrl (variable old_lu and new_lu).",
        caller unless old_lu.hash==new_lu.hash
      raise RuntimeError,"Mendeley.rename: Could not find file #{old_lu.filename}, cannot rename.",
        caller unless File.exist?(old_lu.filename)
      begin
        Mendeley.debug("rename:\n#{old_lu.filename}\n#{new_lu.filename}",debug_flag) do
          FileUtils.mv(old_lu.filename,new_lu.filename,{:force=>true,:verbose=>true})
        end
      rescue
        puts "WARNING: Mendeley.rename: Could not rename #{old_lu.filename}."
      end
    end
    if rename_mendeley
      Mendeley.debug("update:#{old_lu.hash}\n#{old_lu.localUrl}\n#{new_lu.localUrl}",debug_flag,true) do
        DB.change("Files",{"hash" => new_lu.hash},{"localUrl" => new_lu.localUrl.gsub("'","''")})
      end
    end
  end

  def Mendeley.fix_extension(debug_flag)
    TableFiles.new(DB).each do |f|
      case f.extension
      when NilClass
        #add pdf extension if there is no extension
        new_lu=LocalUrl.new(f.localUrl+".pdf",f.hash)
        Mendeley.rename(f,new_lu,debug_flag)
      when "bin"
        #replace bin extension with pdf
        new_lu=LocalUrl.new(f.localUrl.sub(/\.bin$/,".pdf"),f.hash)
        Mendeley.rename(f,new_lu,debug_flag)
      when "pd"
        #replace bin extension with pdf
        new_lu=LocalUrl.new(f.localUrl.sub(/\.pd$/,".pdf"),f.hash)
        Mendeley.rename(f,new_lu,debug_flag)
      end
    end
    files=`ls | egrep -v '(.pdf$|.ps$|.html$|.sh$|.rb$|^papers.sublime-*)'`.chomp.split("\n")
    return if files.empty?
    Mendeley.debug("The following files are going to be deleted:\n#{files.join("\n")}",debug_flag,true) do
      puts "Continue? [Y/n]"
      FileUtils.remove(files) unless STDIN.gets.chomp.downcase == "n"
    end
  end

  def Mendeley.remove_parentheses(debug_flag)
    TableFiles.new(DB).each do |f|
      if f.localUrl =~ /\(\d\)/
        #remove number between brackets
        new_lu=LocalUrl.new(f.localUrl.sub(/\(\d\)/,''),f.hash)
        Mendeley.rename(f,new_lu,debug_flag)
      end
    end
    #invalid byte sequence in US-ASCII (Argument Error)
    #put this in .profile:
    # export LANG=en_US.UTF-8
    # export LANGUAGE=en_US.UTF-8
    # export LC_ALL=en_US.UTF-8
    # https://stackoverflow.com/questions/17031651/invalid-byte-sequence-in-us-ascii-argument-error-when-i-run-rake-dbseed-in-ra
    files=`find . -name \\*\\([0-9]\\)\\*`.chomp.split("\n")
    return if files.empty?
    Mendeley.debug("The following files are going to be deleted:\n#{files.join("\n")}",debug_flag,true) do
      puts "Continue? [Y/n]"
      FileUtils.remove(files) unless STDIN.gets.chomp.downcase == "n"
    end
  end

  # screen ebook printer prepress default
  PDFSETTINGS_DEFAULT="ebook"

  def Mendeley.compress_pdf(debug_flag)
    files=Array.new
    #get list of PDFs
    Dir.glob("*.pdf",File::FNM_CASEFOLD) do |fin|
      #skip compressed PDFs
      next if fin =~ /compressed\.pdf$/i
      #compressed PDF filename
      fout=Mendeley.compress_filename(fin)
      #skip if this PDF is already compressed
      next if File.exist?(fout)
      if debug_flag
        files << fin
      else
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
          puts "Original  : "+((finsize /1024).to_s+"Kb").rjust(8)+"\n" +
               "Compressed: "+((foutsize/1024).to_s+"Kb").rjust(8)+", "+('%.2f' % (foutsize.to_f/finsize.to_f*100)+"%").rjust(8)+"\n" +
               "Delta     : "+((delta   /1024).to_s+"Kb").rjust(8)+", "+('%.2f' % (   delta.to_f/finsize.to_f*100)+"%").rjust(8)
          #create empty file if compressed size is larger
          File.open(fout, "w") {} if delta > 0
        else
          #create empty file
          File.open(fout, "w") {}
        end
      end
    end
    puts "The following files would have been compressed if the debug flag was unset:\n#{files.join("\n")}\n" if debug_flag && ! files.empty?
  end

  def Mendeley.compress_filename(f)
    f.sub('.pdf','-compressed.pdf')
  end
  def Mendeley.uncompress_filename(f)
    f.sub('-compressed.pdf','.pdf')
  end

  def Mendeley.compress_gain(f)
    finsize =File.stat(f).size
    foutsize=File.stat(Mendeley.compress_filename(f)).size
    delta=foutsize-finsize
    return delta,finsize,foutsize
  end

  def Mendeley.operation_dialogue(f,op,reason,debug_flag)
    case op
    when :delete
      op_str="Deleting"
    when :zero
      op_str="Zeroing"
    else
      raise RuntimeError,"Unknown op #{op}"
    end
    f_clean=f.sub(/.pdf$/i,'').sub(/-compressed$/i,'')
    Clipboard.copy(f_clean)
    system_list="System list is:\n"+`ls -la #{Utils.clean_filename(f_clean)}*`
    Mendeley.debug(op_str+" the file below because "+reason+":\n"+f+"\n"+system_list,debug_flag,true) do
      if ARGV.include?('force')
        continue=true
      else
        puts "Continue? [Y/n]"
        continue=(STDIN.gets.chomp.downcase != "n")
      end
      if continue
        case op
        when :delete
          File.delete(f)
        when :zero
          File.open(f, "w") {}
        end
      end
    end
  end


  #NOTICE: This is not working, possibly because cannot change hashes outside of mendeley
  def Mendeley.switch_to_compressed_pdf(debug_flag)
    TableFiles.new(DB).each do |f|
      unless f.localUrl =~ /-compressed/
        #save filenames
        fn={
          :comp => f.basename+"-compressed.pdf",
          :unco => f.basename+".pdf"
        }
        #sanity
        fn.each do |k,v|
          raise RuntimeError,"Cannot find file #{v}" unless File.exist?(v)
        end
        #get file sizes
        fs=Hash[fn.map{|k,v| [k,File.stat(v).size]}]
        #do nothing if compressed PDF has non-zero size
        if fs[:comp]==0
          puts "Uncompressable: "+(fs[:unco]/1024).to_s.rjust(8)+"Kb "+fn[:unco] if debug_flag
          next
        end
        #check if this is a bloated compressed file (should be cleaned at Mendeley.compress_pdf)
        raise RuntimeError,"Bloated compressed file found:\n"+
          "  Compressed: "+(fs[:comp]/1024).to_s.rjust(8)+"Kb "+fn[:comp]+"\n"+
          "Uncompressed: "+(fs[:unco]/1024).to_s.rjust(8)+"Kb "+fn[:unco]+"\n" if fs[:unco]<fs[:comp]
        #keep only one file if they are both of the same size
        if fs[:unco]==fs[:comp]
          #check what is in Mendeley
          if f.localUrl=~/-compressed\.pdf$/i
            # if it is the compressed one, delete the uncompressed
            Mendeley.operation_dialogue(fn[:unco],:delete,reason="compressed already in Mendeley and is of the same size as uncompressed")
          else
            #if it's the uncompressed one, zero the compressed
            Mendeley.operation_dialogue(fn[:comp],:zero,reason="compressed not added to Mendeley and is of the same size uncompressed")
          end
          #we're done for this one
          next
        end
        #compute SHA1 of both files
        fsha1=Hash[fn.map{|k,v| [k,Digest::SHA1.file(v).hexdigest]}]
        #sanity on the hash algorithm used
        raise RuntimeError,"Could not replicate SHA1 hash in Mendeley:\n"+
        "File:          "+fn[:unco]+"\n"+
        "Mendeley hash: "+f.hash+"\n"+
        "SHA-1 hash:    "+fsha1[:unco]+"\n" unless fsha1[:unco]==f.hash
        #build new LocalUrl
        new_lu=LocalUrl.new(f.localUrl.sub(/\.pdf$/i,'-compressed.pdf'),fsha1[:comp])
        #rename files in mendeley only (not the files on the hard disk)
        Mendeley.rename(f,new_lu,debug_flag,rename_file=false)
      end

return

    end
  end

  def Mendeley.clean_orphan_files(debug_flag,verbose_flag)
    #inits
    db=TableFiles.new(DB)
    tab=24
    #loop over all files
    Dir.foreach('.') do |f|
      #skip directories
      if File.directory?(f)
        reason='directory'
        puts "Skipping: "+reason.rjust(tab)+": "+f if verbose_flag
        next
      end
      #skip irrelevant files
      skip=false
      [".sh$",".rb$","^papers.sublime","^.DS"].each do |fp|
        if f=~Regexp.new(fp)
          skip=true
          break
        end
      end
      if skip
        reason='irrelevant'
        puts "Skipping: "+reason.rjust(tab)+": "+f if verbose_flag
        next
      end
      #init object
      cup=CompUncoPair.new(f,db)
      #skip empty compressed files if uncompressed is in Mendeley
      if cup.comp[:size]==0 && cup.unco[:added]
        reason='cannot compress'
        puts "Skipping: "+reason.rjust(tab)+": "+f if verbose_flag
        next
      end
      #skip if uncompressed is smaller than compressed (compress not yet added to Mendeley)
      if cup.comp[:size] < cup.unco[:size] && cup.comp[:size]>0
        reason='compressed not yet added'
        puts "Skipping: "+reason.rjust(tab)+": "+f if verbose_flag
        next
      end
      #delete empty compressed file if there is no uncompressed in Mendeley
      if cup.comp[:size]==0 && ! cup.unco[:added]
        Mendeley.operation_dialogue(cup.comp[:name],:delete,reason="it is empty and there is no uncompressed version added to Mendeley",debug_flag)
      end
      #zero compressed if larger or equal to uncompressed
      if cup.comp[:size] >= cup.unco[:size] && cup.unco[:size] > 0
        Mendeley.operation_dialogue(cup.comp[:name],:zero,reason="it is larger than or equal to uncompressed",debug_flag)
      end
      #skip non-existing files
      unless File.exist?(f)
        reason='file disappeard'
        puts "Skipping: "+reason.rjust(tab)+": "+f if verbose_flag
        next
      end
      #look for this file in the mendeley database
      fm=db.find(Digest::SHA1.file(f).hexdigest)
      if fm.nil?
        Mendeley.operation_dialogue(f,:delete,reason="it is not part of Mendeley",debug_flag)
        next
      end
      #check if the filename matches (which is possible, if the files are the same except for the name)
      I18n.config.available_locales = :en
      fme=I18n.transliterate(File.basename(fm.filename)).gsub('?','')
       fe=I18n.transliterate(f).gsub('?','')
      if fme != fe
        # a=fme
        # puts "<#{a}>\nlength=#{a.length}\nbytesize=#{a.bytesize}\nencoding=#{a.encoding}\nascii=#{a.split('').map(&:ord)}"
        # a=fe
        # puts "<#{a}>\nlength=#{a.length}\nbytesize=#{a.bytesize}\nencoding=#{a.encoding}\nascii=#{a.split('').map(&:ord)}"
        Mendeley.operation_dialogue(f,:delete,reason="this hash refers to file:\n#{File.basename(fm.filename)}\ninstead of file",debug_flag)
      end
    end
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
    #compute the total space that can be saved
    sizes=Hash.new
    sizes[:all]=rec.map{ |file,size| size[0] if size[0]<0 }.compact
    sizes[:sum]=sizes[:all].sum
    sizes[:std]=sizes[:all].std
    #get the top-most space-saving compressions
    out=rec.sort_by{ |file,size| size }[0..9]
    #user feedback
    puts "Potential total delta space: #{sizes[:sum]/1024/1024}Mb; std=#{"%.3f" % (sizes[:std]/1024)}Kb"
    puts "Delta (Kb)".rjust(PADDING[0])+"Original".rjust(PADDING[1])+"Compressed".rjust(PADDING[2])+"   "+"Filename".ljust(PADDING[3])
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

DATABASE="J.G.deTeixeiradaEncarnacao@tudelft.nl@www.mendeley.com.sqlite"

if OS.linux?
  FILENAME="#{ENV['HOME']}/.local/share/data/Mendeley Ltd./Mendeley Desktop/#{DATABASE}"
elsif OS.mac?
  FILENAME="#{ENV['HOME']}/Library/Application\ Support/Mendeley\ Desktop/#{DATABASE}"
else
  raise RuntimeError,"Cannot determine OS type"
end

DB=SQLite::SQLdb.new(FILENAME)

debug_flag=ARGV.include?('debug')
Mendeley.fix_extension(debug_flag)
Mendeley.remove_parentheses(debug_flag)
Mendeley.clean_orphan_files(debug_flag,ARGV.include?('verbose')) if ARGV.include?('orphans')
puts "Compress PDFs (usually this is done only at one computer, since mendeley will download all PDFs, including compressed one, and rename them)? [Y/n]"
unless STDIN.gets.chomp.downcase == "n"
  Mendeley.compress_pdf(debug_flag)
  # Mendeley.switch_to_compressed_pdf(debug_flag)
  funcomp=Mendeley.compressed_pdf_report
  fcomp=Mendeley.compress_filename(funcomp)
  Clipboard.copy(funcomp.sub('.pdf',''))
  puts "Delete #{funcomp}? [Y/n]"
  puts "(copied to clipboard: '#{Clipboard.paste}')"
  if STDIN.gets.chomp.downcase == "n"
    puts "Discard compressed version and keep uncompressed one (because it is already annotated)? [Y/n]"
    if STDIN.gets.chomp.downcase == "n"
      exit 3
    else
      File.delete(fcomp)
      `touch "#{fcomp}"`
    end
  else
    File.delete(funcomp)
    puts "Delete #{fcomp}? [y/N]"
    File.delete(fcomp) if STDIN.gets.chomp.downcase == "y"
  end
end