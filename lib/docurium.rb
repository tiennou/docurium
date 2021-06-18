require 'json'
require 'tempfile'
require 'version_sorter'
require 'rocco'
require 'docurium/version'
require 'docurium/layout'
require 'docurium/debug'
require 'libdetect'
require 'docurium/docparser'
require 'pp'
require 'rugged'
require 'redcarpet'
require 'redcarpet/compat'
require 'parallel'
require 'thread'

# Markdown expects the old redcarpet compat API, so let's tell it what
# to use
Rocco::Markdown = RedcarpetCompat

class Docurium
  attr_accessor :branch, :output_dir, :data, :head_data

  def initialize(config_file, cli_options = {}, repo = nil)
    raise "You need to specify a config file" if !config_file
    raise "You need to specify a valid config file" if !valid_config(config_file)
    @sigs = {}
    @head_data = nil
    @repo = repo || Rugged::Repository.discover(config_file)
    @cli_options = cli_options
  end

  def init_data(version = 'HEAD')
    data = {:files => [], :functions => {}, :callbacks => {}, :globals => {}, :types => {}, :prefix => ''}
    data[:prefix] = option_version(version, 'input', '')
    data
  end

  def option_version(version, option, default = nil)
    if @options['legacy']
      if valhash = @options['legacy'][option]
        valhash.each do |value, versions|
          return value if versions.include?(version)
        end
      end
    end
    opt = @options[option]
    opt = default if !opt
    opt
  end

  def format_examples!(data, version)
    examples = []
    if ex = option_version(version, 'examples')
      if subtree = find_subtree(version, ex) # check that it exists
        index = Rugged::Index.new
        index.read_tree(subtree)

        files = []
        index.each do |entry|
          next unless entry[:path].match(/\.c$/)
          files << entry[:path]
        end

        files.each do |file|
          # highlight, roccoize and link
          rocco = Rocco.new(file, files, {:language => 'c'}) do
            ientry = index[file]
            blob = @repo.lookup(ientry[:oid])
            blob.content
          end

          extlen = -(File.extname(file).length + 1)
          rf_path = file[0..extlen] + '.html'
          rel_path = "ex/#{version}/#{rf_path}"

          rocco_layout = Rocco::Layout.new(rocco, @tf)
          # find out how deep our file is so we can use the right
          # number of ../ in the path
          depth = rel_path.count('/') - 1
          if depth == 0
            rocco_layout[:dirsup] = "./"
          else
            rocco_layout[:dirsup] = "../"*depth
          end

          rocco_layout.version = version
          rf = rocco_layout.render


          # look for function names in the examples and link
          id_num = 0
          data[:functions].each do |f, fdata|
            rf.gsub!(/#{f}([^\w])/) do |fmatch|
              extra = $1
              id_num += 1
              name = f + '-' + id_num.to_s
              # save data for cross-link
              data[:functions][f][:examples] ||= {}
              data[:functions][f][:examples][file] ||= []
              data[:functions][f][:examples][file] << rel_path + '#' + name
              "<a name=\"#{name}\" class=\"fnlink\" href=\"../../##{version}/group/#{fdata[:group]}/#{f}\">#{f}</a>#{extra}"
            end
          end

          # write example to the repo
          sha = @repo.write(rf, :blob)
          examples << [rel_path, sha]

          data[:examples] ||= []
          data[:examples] << [file, rel_path]
        end
      end
    end

    examples
  end

  def generate_doc_for(version)
    doc_tree = @repo.branches[@options['branch']].target.tree
    js_file = doc_tree.path("#{version}.json") rescue nil
    ex_tree = doc_tree.path("ex/#{version}") rescue nil
    if @cli_options[:'only-missing'] and version != 'HEAD' and js_file
      puts "Reusing built documentation for #{version}"
      data = JSON.parse(@repo.lookup(js_file[:oid]).content, {:symbolize_names => true})
      examples = []
      @repo.lookup(ex_tree[:oid]).walk_blobs do |root, entry|
        oid = entry[:oid]
        path = entry[:name]
        path = File.join(root, entry[:name]) unless root.empty?
        examples << [path, entry[:oid]]
      end unless ex_tree.nil?

      [data, examples]
    else
      index = Rugged::Index.new
      read_subtree(index, version, option_version(version, 'input', ''))

      data = parse_headers(index, version)
      examples = format_examples!(data, version)
      [data, examples]
    end
  end

  def process_project(versions)
    nversions = versions.count
    Parallel.each_with_index(versions, finish: -> (version, index, result) do
      data, examples = result
      # There's still some work we need to do serially
      tally_sigs!(version, data)
      force_utf8(data)

      puts "Adding documentation for #{version} [#{index}/#{nversions}]"

      # Store it so we can show it at the end
      @head_data = data if version == 'HEAD'

      yield index, version, result if block_given?

    end) do |version, index|
      puts "Generating documentation for #{version} [#{index}/#{nversions}]"
      generate_doc_for(version)
    rescue Exception => e
      puts "\t version #{index}: generation failed: #{e}"
      puts e.backtrace
      []
    end
  end

  def generate_docs
    output_index = Rugged::Index.new
    write_site(output_index)
    @tf = File.expand_path(File.join(File.dirname(__FILE__), 'docurium', 'layout.mustache'))
    versions = get_versions
    versions << 'HEAD'
    # If the user specified versions, validate them and overwrite
    if !(vers = (@cli_options[:for] || [])).empty?
      vers.each do |v|
        next if versions.include?(v)
        puts "Unknown version #{v}"
        exit(false)
      end
      versions = vers
    end

    if (@repo.config['user.name'].nil? || @repo.config['user.email'].nil?)
      puts "ERROR: 'user.name' or 'user.email' is not configured. Docurium will not be able to commit the documentation"
      exit(false)
    end

    process_project(versions) do |i, version, result|
      data, examples = result
      sha = @repo.write(data.to_json, :blob)

      print "Generating documentation [#{i}/#{versions.count}]\r"

      unless dry_run?
        output_index.add(:path => "#{version}.json", :oid => sha, :mode => 0100644)
        examples.each do |path, id|
          output_index.add(:path => path, :oid => id, :mode => 0100644)
        end
      end
    end

    if head_data
      puts ''
      show_warnings(head_data)
    end

    return if dry_run?

    # We tally the signatures in the order they finished, which is
    # arbitrary due to the concurrency, so we need to sort them once
    # they've finished.
    sort_sigs!

    project = {
      :versions => versions.reverse,
      :github   => @options['github'],
      :name     => @options['name'],
      :signatures => @sigs,
    }
    sha = @repo.write(project.to_json, :blob)
    output_index.add(:path => "project.json", :oid => sha, :mode => 0100644)

    css = File.read(File.expand_path(File.join(File.dirname(__FILE__), 'docurium', 'css.css')))
    sha = @repo.write(css, :blob)
    output_index.add(:path => "ex/css.css", :oid => sha, :mode => 0100644)

    br = @options['branch']
    out "* writing to branch #{br}"
    refname = "refs/heads/#{br}"
    tsha = output_index.write_tree(@repo)
    puts "\twrote tree   #{tsha}"
    ref = @repo.references[refname]
    user = { :name => @repo.config['user.name'], :email => @repo.config['user.email'], :time => Time.now }
    options = {}
    options[:tree] = tsha
    options[:author] = user
    options[:committer] = user
    options[:message] = 'generated docs'
    options[:parents] = ref ? [ref.target] : []
    options[:update_ref] = refname
    csha = Rugged::Commit.create(@repo, options)
    puts "\twrote commit #{csha}"
    puts "\tupdated #{br}"
  end

  def force_utf8(data)
    # Walk the data to force strings encoding to UTF-8.
    if data.instance_of? Hash
      data.each do |key, value|
        if [:comment, :comments, :description].include?(key)
          data[key] = value.force_encoding('UTF-8') unless value.nil?
        else
          force_utf8(value)
        end
      end
    elsif data.respond_to?(:each)
      data.each { |x| force_utf8(x) }
    end
  end

  class Warning
    class UnmatchedParameter < Warning
      def initialize(function, opts = {})
        super :unmatched_param, :function, function, opts
      end

      def _message; "unmatched param"; end
    end

    class SignatureChanged < Warning
      def initialize(function, opts = {})
        super :signature_changed, :function, function, opts
      end

      def _message; "signature changed"; end
    end

    class MissingDocumentation < Warning
      def initialize(type, identifier, opts = {})
        super :missing_documentation, type, identifier, opts
      end

      def _message
        ["%s %s is missing documentation", :type, :identifier]
      end
    end

    WARNINGS = [
      :unmatched_param,
      :signature_changed,
      :missing_documentation,
    ]

    attr_reader :warning, :type, :identifier, :file, :line, :column

    def initialize(warning, type, identifier, opts = {})
      raise ArgumentError.new("invalid warning class") unless WARNINGS.include?(warning)
      @warning = warning
      @type = type
      @identifier = identifier
      if type = opts.delete(:type)
        @file = type[:file]
        if input_dir = opts.delete(:input_dir)
          File.expand_path(File.join(input_dir, @file))
        end
        @file ||= "<missing>"
        @line = type[:line] || 1
        @column = type[:column] || 1
      end
    end

    def message
      msg = self._message
      msg.kind_of?(Array) ? msg.shift % msg.map {|a| self.send(a).to_s } : msg
    end
  end

  def collect_warnings(data)
    warnings = []
    input_dir = File.join(@project_dir, option_version("HEAD", 'input'))

    # check for unmatched paramaters
    data[:functions].each do |f, fdata|
      warnings << Warning::UnmatchedParameter.new(f, type: fdata, input_dir: input_dir) if fdata[:comments] =~ /@param/
    end

    # check for changed signatures
    sigchanges = []
    @sigs.each do |fun, sig_data|
      warnings << Warning::SignatureChanged.new(fun) if sig_data[:changes]['HEAD']
    end

    # check for undocumented things
    types = [:functions, :callbacks, :globals, :types]
    types.each do |type_id|
      under_type = type_id.tap {|t| break t.to_s[0..-2].to_sym }
      data[type_id].each do |ident, type|
        under_type = type[:type] if type_id == :types

        warnings << Warning::MissingDocumentation.new(under_type, ident, type: type, input_dir: input_dir) if type[:description].empty?

        case type[:type]
        when :struct
          if type[:fields]
            type[:fields].each do |field|
              warnings << Warning::MissingDocumentation.new(:field, "#{ident}.#{field[:name]}", type: type, input_dir: input_dir) if field[:comments].empty?
            end
          end
        end
      end
    end
    warnings
  end

  def check_warnings(options)
    versions = []
    versions << get_versions.pop
    versions << 'HEAD'

    process_project(versions)

    collect_warnings(head_data).each do |warning|
      puts "#{warning.file}:#{warning.line}:#{warning.column}: #{warning.message}"
    end
  end

  def show_warnings(data)
    out '* checking your api'

    collect_warnings(data).group_by {|w| w.warning }.each do |klass, klass_warnings|
      klass_warnings.group_by {|w| w.type }.each do |type, type_warnings|
        out "  - " + type_warnings[0].message
        type_warnings.sort_by {|w| w.identifier }.each do |warning|
          out "\t" + warning.identifier
        end
      end
    end
  end

  def get_versions
    releases = @repo.tags
               .map { |tag| tag.name.gsub(%r(^refs/tags/), '') }
               .delete_if { |tagname| tagname.match(%r(-rc\d*$)) }
    VersionSorter.sort(releases)
  end

  def parse_headers(index, version)
    headers = index.map { |e| e[:path] }.grep(/\.h$/)

    files = headers.map do |file|
      [file, @repo.lookup(index[file][:oid]).content]
    end

    data = init_data(version)
    DocParser.with_files(files, :prefix => version) do |parser|
      headers.each do |header|
        records = parser.parse_file(header, debug: interesting?(:file, header))
        update_globals!(data, records)
      end
    end

    data[:groups] = group_functions!(data)
    data[:types] = data[:types].sort # make it an assoc array
    find_type_usage!(data)

    data
  end

  private

  def tally_sigs!(version, data)
    @lastsigs ||= {}
    data[:functions].each do |fun_name, fun_data|
      if !@sigs[fun_name]
        @sigs[fun_name] ||= {:exists => [], :changes => {}}
      else
        if @lastsigs[fun_name] != fun_data[:sig]
          @sigs[fun_name][:changes][version] = true
        end
      end
      @sigs[fun_name][:exists] << version
      @lastsigs[fun_name] = fun_data[:sig]
    end
  end

  def sort_sigs!
    @sigs.keys.each do |fn|
      VersionSorter.sort!(@sigs[fn][:exists])
      # Put HEAD at the back
      @sigs[fn][:exists] << @sigs[fn][:exists].shift
    end
  end

  def find_subtree(version, path)
    tree = nil
    if version == 'HEAD'
      tree = @repo.head.target.tree
    else
      trg = @repo.references["refs/tags/#{version}"].target
      if(trg.kind_of? Rugged::Tag::Annotation)
        trg = trg.target
      end

      tree = trg.tree
    end

    begin
      tree_entry = tree.path(path)
      @repo.lookup(tree_entry[:oid])
    rescue Rugged::TreeError
      nil
    end
  end

  def read_subtree(index, version, path)
    tree = find_subtree(version, path)
    index.read_tree(tree)
  end

  def valid_config(file)
    return false if !File.file?(file)
    fpath = File.expand_path(file)
    @project_dir = File.dirname(fpath)
    @config_file = File.basename(fpath)
    @options = JSON.parse(File.read(fpath))
    !!@options['branch']
  end

  def group_functions!(data)
    func = {}
    data[:functions].each_pair do |key, value|
      debug_set interesting?(:function, key)
      debug "grouping #{key}: #{value}"
      if @options['prefix']
        k = key.gsub(@options['prefix'], '')
      else
        k = key
      end
      group, rest = k.split('_', 2)
      debug "grouped: k: #{k}, group: #{group}, rest: #{rest}"
      if group.empty?
        puts "empty group for function #{key}"
        next
      end
      debug "grouped: k: #{k}, group: #{group}, rest: #{rest}"
      data[:functions][key][:group] = group
      func[group] ||= []
      func[group] << key
      func[group].sort!
    end
    func.to_a.sort
  end

  def find_type_usage!(data)
    # go through all functions, callbacks, and structs
    # see which other types are used and returned
    # store them in the types data
    h = {}
    h.merge!(data[:functions])
    h.merge!(data[:callbacks])

    structs = data[:types].find_all {|t, tdata| (tdata[:type] == :struct and tdata[:fields] and not tdata[:fields].empty?) }
    structs = Hash[structs.map {|t, tdata| [t, tdata] }]
    h.merge!(structs)

    h.each do |use, use_data|
      data[:types].each_with_index do |tdata, i|
        type, typeData = tdata

        data[:types][i][1][:used] ||= {:returns => [], :needs => [], :fields => []}
        if use_data[:return] && use_data[:return][:type].index(/#{type}[ ;\)\*]?/)
          data[:types][i][1][:used][:returns] << use
          data[:types][i][1][:used][:returns].sort!
        end
        if use_data[:argline] && use_data[:argline].index(/#{type}[ ;\)\*]?/)
          data[:types][i][1][:used][:needs] << use
          data[:types][i][1][:used][:needs].sort!
        end
        if use_data[:fields] and use_data[:fields].find {|f| f[:type] == type }
          data[:types][i][1][:used][:fields] << use
          data[:types][i][1][:used][:fields].sort!
        end
      end
    end
  end

  def update_globals!(data, recs)
    return if recs.empty?

    wanted = {
      :functions => %W/type value file line lineto args argline sig return group description comments/.map(&:to_sym),
      :types => %W/decl type value file line lineto block tdef description comments fields/.map(&:to_sym),
      :globals => %W/value file line comments/.map(&:to_sym),
      :meta => %W/brief defgroup ingroup comments/.map(&:to_sym),
    }

    file_map = {}

    md = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new({}), :no_intra_emphasis => true)
    recs.each do |r|

      types = %w(function file type).map(&:to_sym)
      dbg = false
      types.each do |t|
        dbg ||= if r[:type] == t and interesting?(t, r[:name])
          true
        elsif t == :file and interesting?(:file, r[:file])
          true
        elsif [:struct, :enum].include?(r[:type]) and interesting?(:type, r[:name])
          true
        else
          false
        end
      end

      debug_set dbg

      debug "processing record: #{r}"
      debug

      # initialize filemap for this file
      file_map[r[:file]] ||= {
        :file => r[:file], :functions => [], :meta => {}, :lines => 0
      }
      if file_map[r[:file]][:lines] < r[:lineto]
        file_map[r[:file]][:lines] = r[:lineto]
      end

      # process this type of record
      case r[:type]
      when :function, :callback
        t = r[:type] == :function ? :functions : :callbacks
        data[t][r[:name]] ||= {}
        wanted[:functions].each do |k|
          next unless r.has_key? k
          if k == :description || k == :comments
            contents = md.render r[k]
          else
            contents = r[k]
          end
          data[t][r[:name]][k] = contents
        end
        file_map[r[:file]][:functions] << r[:name]

      when :define, :macro
        data[:globals][r[:decl]] ||= {}
        wanted[:globals].each do |k|
          next unless r.has_key? k
          if k == :description || k == :comments
            data[:globals][r[:decl]][k] = md.render r[k]
          else
            data[:globals][r[:decl]][k] = r[k]
          end
        end

      when :file
        wanted[:meta].each do |k|
          file_map[r[:file]][:meta][k] = r[k] if r.has_key?(k)
        end

      when :enum
        if !r[:name]
          # Explode unnamed enum into multiple global defines
          r[:decl].each do |n|
            data[:globals][n] ||= {
              :file => r[:file], :line => r[:line],
              :value => "", :comments => md.render(r[:comments]),
            }
            m = /#{Regexp.quote(n)}/.match(r[:body])
            if m
              data[:globals][n][:line] += m.pre_match.scan("\n").length
              if m.post_match =~ /\s*=\s*([^,\}]+)/
                data[:globals][n][:value] = $1
              end
            end
          end
        else # enum has name
          data[:types][r[:name]] ||= {}
          wanted[:types].each do |k|
            next unless r.has_key? k
            contents = r[k]
            if k == :comments
              contents = md.render r[k]
            elsif k == :block
              old_block = data[:types][r[:name]][k]
              contents = old_block ? [old_block, r[k]].join("\n") : r[k]
            elsif k == :fields
              type = data[:types][r[:name]]
              type[:fields] = []
              r[:fields].each do |f|
                f[:comments] = md.render(f[:comments])
              end
            end
            data[:types][r[:name]][k] = contents
          end
        end

      when :struct, :fnptr
        data[:types][r[:name]] ||= {}
        known = data[:types][r[:name]]
        r[:value] ||= r[:name]
        # we don't want to override "opaque" structs with typedefs or
        # "public" documentation
        unless r[:tdef].nil? and known[:fields] and known[:comments] and known[:description]
          wanted[:types].each do |k|
            next unless r.has_key? k
            if k == :comments
              data[:types][r[:name]][k] = md.render r[k]
            else
              data[:types][r[:name]][k] = r[k]
            end
          end
        else
          # We're about to skip that type. Just make sure we preserve the
          # :fields comment
          if r[:fields] and known[:fields].empty?
            data[:types][r[:name]][:fields] = r[:fields]
          end
        end
        if r[:type] == :fnptr
          data[:types][r[:name]][:type] = "function pointer"
        end

      else
        # Anything else we want to record?
      end

      debug "processed record: #{r}"
      debug

      debug_restore
    end

    data[:files] << file_map.values[0]
  end

  def add_dir_to_index(index, prefix, dir)
    Dir.new(dir).each do |filename|
      next if [".", ".."].include? filename
      name = File.join(dir, filename)
      if File.directory? name
        add_dir_to_index(index, prefix, name)
      else
        rel_path = name.gsub(prefix, '')
        content = File.read(name)
        sha = @repo.write(content, :blob)
        index.add(:path => rel_path, :oid => sha, :mode => 0100644)
      end
    end
  end

  def write_site(index)
    here = File.expand_path(File.dirname(__FILE__))
    dirname = File.join(here, '..', 'site')
    dirname = File.realpath(dirname)
    add_dir_to_index(index, dirname + '/', dirname)
  end

  def out(text)
    puts text
  end

  def dry_run?
    @cli_options[:dry_run]
  end

  def interesting?(type, what)
    @cli_options['debug'] || (@cli_options["debug-#{type}"] || []).include?(what)
  end
end
