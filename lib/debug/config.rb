# frozen_string_literal: true

module DEBUGGER__
  LOG_LEVELS = {
    UNKNOWN: 0,
    FATAL:   1,
    ERROR:   2,
    WARN:    3,
    INFO:    4,
  }.freeze

  CONFIG_SET = {
    # UI setting
    log_level:      ['RUBY_DEBUG_LOG_LEVEL',      "UI: Log level same as Logger (default: WARN)",                   :loglevel],
    show_src_lines: ['RUBY_DEBUG_SHOW_SRC_LINES', "UI: Show n lines source code on breakpoint (default: 10 lines)", :int],
    show_frames:    ['RUBY_DEBUG_SHOW_FRAMES',    "UI: Show n frames on breakpoint (default: 2 frames)",            :int],
    use_short_path: ['RUBY_DEBUG_USE_SHORT_PATH', "UI: Show shorten PATH (like $(Gem)/foo.rb)",                      :bool],
    no_color:       ['RUBY_DEBUG_NO_COLOR',       "UI: Do not use colorize (default: false)",                       :bool],
    no_sigint_hook: ['RUBY_DEBUG_NO_SIGINT_HOOK', "UI: Do not suspend on SIGINT (default: false)",                  :bool],
    no_reline:      ['RUBY_DEBUG_NO_RELINE',      "UI: Do not use Reline library (default: false)",                 :bool],

    # control setting
    skip_path:      ['RUBY_DEBUG_SKIP_PATH',      "CONTROL: Skip showing/entering frames for given paths (default: [])", :path],
    skip_nosrc:     ['RUBY_DEBUG_SKIP_NOSRC',     "CONTROL: Skip on no source code lines (default: false)",              :bool],
    keep_alloc_site:['RUBY_DEBUG_KEEP_ALLOC_SITE',"CONTROL: Keep allocation site and p, pp shows it (default: false)",   :bool],
    postmortem:     ['RUBY_DEBUG_POSTMORTEM',     "CONTROL: Enable postmortem debug (default: false)",                   :bool],
    parent_on_fork: ['RUBY_DEBUG_PARENT_ON_FORK', "CONTROL: Keep debugging parent process on fork (default: false)",     :bool],
    sigdump_sig:    ['RUBY_DEBUG_SIGDUMP_SIG',    "CONTROL: Sigdump signal (default: disabled)"],

    # boot setting
    nonstop:        ['RUBY_DEBUG_NONSTOP',     "BOOT: Nonstop mode",                                                :bool],
    stop_at_load:   ['RUBY_DEBUG_STOP_AT_LOAD',"BOOT: Stop at just loading location",                               :bool],
    init_script:    ['RUBY_DEBUG_INIT_SCRIPT', "BOOT: debug command script path loaded at first stop"],
    commands:       ['RUBY_DEBUG_COMMANDS',    "BOOT: debug commands invoked at first stop. commands should be separated by ';;'"],
    no_rc:          ['RUBY_DEBUG_NO_RC',       "BOOT: ignore loading ~/.rdbgrc(.rb)",                               :bool],

    # remote setting
    port:           ['RUBY_DEBUG_PORT',      "REMOTE: TCP/IP remote debugging: port"],
    host:           ['RUBY_DEBUG_HOST',      "REMOTE: TCP/IP remote debugging: host (localhost if not given)"],
    sock_path:      ['RUBY_DEBUG_SOCK_PATH', "REMOTE: UNIX Domain Socket remote debugging: socket path"],
    sock_dir:       ['RUBY_DEBUG_SOCK_DIR',  "REMOTE: UNIX Domain Socket remote debugging: socket directory"],
    cookie:         ['RUBY_DEBUG_COOKIE',    "REMOTE: Cookie for negotiation"],
  }.freeze

  CONFIG_MAP = CONFIG_SET.map{|k, (ev, desc)| [k, ev]}.to_h.freeze

  class Config
    def self.config
      @config
    end

    def initialize argv
      if self.class.instance_variable_defined? :@config
        raise 'Can not make multiple configurations in one process'
      end

      update self.class.parse_argv(argv)
    end

    def [](key)
      config[key]
    end

    def []=(key, val)
      set_config(key => val)
    end

    def set_config(**kw)
      conf = config.dup
      kw.each{|k, v|
        if CONFIG_MAP[k]
          conf[k] = parse_config_value(k, v) # TODO: ractor support
        else
          raise "Unknown configuration: #{k}"
        end
      }

      update conf
    end

    def append_config key, val
      conf = self.config.dup

      if CONFIG_SET[key]
        if CONFIG_SET[key][2] == :path
          conf[key] = [*conf[key], *parse_config_value(key, val)];
        else
          raise "not an Array type: #{key}"
        end
      else
        raise "Unknown configuration: #{key}"
      end

      update conf
    end

    def update conf
      old_conf = self.class.instance_variable_get(:@config) || {}

      # TODO: Use Ractor.make_shareable(conf)
      self.class.instance_variable_set(:@config, conf.freeze)

      # Post process
      if_updated old_conf, conf, :keep_alloc_site do |_, new|
        if new
          require 'objspace'
          ObjectSpace.trace_object_allocations_start
        else
          ObjectSpace.trace_object_allocations_stop
        end
      end

      if_updated old_conf, conf, :postmortem do |_, new_p|
        if defined?(SESSION)
          SESSION.postmortem = new_p
        end
      end

      if_updated old_conf, conf, :sigdump_sig do |old_sig, new_sig|
        setup_sigdump old_sig, new_sig
      end
    end

    private def if_updated old_conf, new_conf, key
      old, new = old_conf[key], new_conf[key]
      yield old, new if old != new
    end

    private def enable_sigdump sig
      @sigdump_sig_prev = trap(sig) do
        str = []
        str << "Simple sigdump on #{Process.pid}"
        Thread.list.each{|th|
          str << "Thread: #{th}"
          th.backtrace.each{|loc|
            str << "  #{loc}"
          }
          str << ''
        }

        STDERR.puts str
      end
    end

    private def disable_sigdump old_sig
      trap(old_sig, @sigdump_sig_prev)
      @sigdump_sig_prev = nil
    end

    # emergency simple sigdump.
    # Use `sigdump` gem for more rich features.
    private def setup_sigdump old_sig = nil, sig = CONFIG[:sigdump_sig]
      if !old_sig && sig
        enable_sigdump sig
      elsif old_sig && !sig
        disable_sigdump old_sig
      elsif old_sig && sig
        disable_sigdump old_sig
        enable_sigdump sig
      end
    end

    private def config
      self.class.config
    end

    private def parse_config_value name, valstr
      self.class.parse_config_value name, valstr
    end

    def self.parse_config_value name, valstr
      return valstr unless valstr.kind_of? String

      case CONFIG_SET[name][2]
      when :bool
        case valstr
        when '1', 'true', 'TRUE', 'T'
          true
        else
          false
        end
      when :int
        valstr.to_i
      when :loglevel
        if DEBUGGER__::LOG_LEVELS[s = valstr.to_sym]
          s
        else
          raise "Unknown loglevel: #{valstr}"
        end
      when :path # array of String
        valstr.split(/:/).map{|e|
          if /\A\/(.+)\/\z/ =~ e
            Regexp.compile $1
          else
            e
          end
        }
      else
        valstr
      end
    end

    def self.parse_argv argv
      config = {
        mode: :start,
      }
      CONFIG_MAP.each{|key, evname|
        if val = ENV[evname]
          config[key] = parse_config_value(key, val)
        end
      }
      return config if !argv || argv.empty?

      if argv.kind_of? String
        require 'shellwords'
        argv = Shellwords.split(argv)
      end

      require 'optparse'
      require_relative 'version'

      opt = OptionParser.new do |o|
        o.banner = "#{$0} [options] -- [debuggee options]"
        o.separator ''
        o.version = ::DEBUGGER__::VERSION

        o.separator 'Debug console mode:'
        o.on('-n', '--nonstop', 'Do not stop at the beginning of the script.') do
          config[:nonstop] = '1'
        end

        o.on('-e DEBUG_COMMAND', 'Execute debug command at the beginning of the script.') do |cmd|
          config[:commands] ||= ''
          config[:commands] += cmd + ';;'
        end

        o.on('-x FILE', '--init-script=FILE', 'Execute debug command in the FILE.') do |file|
          config[:init_script] = file
        end
        o.on('--no-rc', 'Ignore ~/.rdbgrc') do
          config[:no_rc] = true
        end
        o.on('--no-color', 'Disable colorize') do
          config[:no_color] = true
        end
        o.on('--no-sigint-hook', 'Disable to trap SIGINT') do
          config[:no_sigint_hook] = true
        end

        o.on('-c', '--command', 'Enable command mode.',
                                'The first argument should be a command name in $PATH.',
                                'Example: \'rdbg -c bundle exec rake test\'') do
          config[:command] = true
        end

        o.separator ''

        o.on('-O', '--open', 'Start remote debugging with opening the network port.',
                             'If TCP/IP options are not given,',
                             'a UNIX domain socket will be used.') do
          config[:remote] = true
        end
        o.on('--sock-path=SOCK_PATH', 'UNIX Domain socket path') do |path|
          config[:sock_path] = path
        end
        o.on('--port=PORT', 'Listening TCP/IP port') do |port|
          config[:port] = port
        end
        o.on('--host=HOST', 'Listening TCP/IP host') do |host|
          config[:host] = host
        end
        o.on('--cookie=COOKIE', 'Set a cookie for connection') do |c|
          config[:cookie] = c
        end

        rdbg = 'rdbg'

        o.separator ''
        o.separator '  Debug console mode runs Ruby program with the debug console.'
        o.separator ''
        o.separator "  '#{rdbg} target.rb foo bar'                starts like 'ruby target.rb foo bar'."
        o.separator "  '#{rdbg} -- -r foo -e bar'                 starts like 'ruby -r foo -e bar'."
        o.separator "  '#{rdbg} -c rake test'                     starts like 'rake test'."
        o.separator "  '#{rdbg} -c -- rake test -t'               starts like 'rake test -t'."
        o.separator "  '#{rdbg} -c bundle exec rake test'         starts like 'bundle exec rake test'."
        o.separator "  '#{rdbg} -O target.rb foo bar'             starts and accepts attaching with UNIX domain socket."
        o.separator "  '#{rdbg} -O --port 1234 target.rb foo bar' starts accepts attaching with TCP/IP localhost:1234."
        o.separator "  '#{rdbg} -O --port 1234 -- -r foo -e bar'  starts accepts attaching with TCP/IP localhost:1234."

        o.separator ''
        o.separator 'Attach mode:'
        o.on('-A', '--attach', 'Attach to debuggee process.') do
          config[:mode] = :attach
        end

        o.separator ''
        o.separator '  Attach mode attaches the remote debug console to the debuggee process.'
        o.separator ''
        o.separator "  '#{rdbg} -A'           tries to connect via UNIX domain socket."
        o.separator "  #{' ' * rdbg.size}                If there are multiple processes are waiting for the"
        o.separator "  #{' ' * rdbg.size}                debugger connection, list possible debuggee names."
        o.separator "  '#{rdbg} -A path'      tries to connect via UNIX domain socket with given path name."
        o.separator "  '#{rdbg} -A port'      tries to connect to localhost:port via TCP/IP."
        o.separator "  '#{rdbg} -A host port' tries to connect to host:port via TCP/IP."

        o.separator ''
        o.separator 'Other options:'

        o.on("-h", "--help", "Print help") do
          puts o
          exit
        end

        o.on('--util=NAME', 'Utility mode (used by tools)') do |name|
          require_relative 'client'
          Client.new(name)
          exit
        end

        o.on('--stop-at-load', 'Stop immediately when the debugging feature is loaded.') do
          config[:stop_at_load] = true
        end

        o.separator ''
        o.separator 'NOTE'
        o.separator '  All messages communicated between a debugger and a debuggee are *NOT* encrypted.'
        o.separator '  Please use the remote debugging feature carefully.'
      end

      opt.parse!(argv)

      config
    end

    def self.config_to_env_hash config
      CONFIG_MAP.each_with_object({}){|(key, evname), env|
        unless config[key].nil?
          case CONFIG_SET[key][2]
          when :path
            valstr = config[key].map{|e| e.kind_of?(Regexp) ? e.inspect : e}.join(':')
          else
            valstr = config[key].to_s
          end
          env[evname] = valstr
        end
      }
    end
  end

  CONFIG = Config.new ENV['RUBY_DEBUG_OPT']

  ## Unix domain socket configuration

  def self.unix_domain_socket_dir
    case
    when path = CONFIG[:sock_dir]
    when path = ENV['XDG_RUNTIME_DIR']
    when home = ENV['HOME']
      path = File.join(home, '.ruby-debug-sock')

      case
      when !File.exist?(path)
        Dir.mkdir(path, 0700)
      when !File.directory?(path)
        raise "#{path} is not a directory."
      end
    else
      raise 'specify RUBY_DEBUG_SOCK_DIR environment variable for UNIX domain socket directory.'
    end

    path
  end

  def self.create_unix_domain_socket_name_prefix(base_dir = unix_domain_socket_dir)
    user = ENV['USER'] || 'ruby-debug'
    File.join(base_dir, "ruby-debug-#{user}")
  end

  def self.create_unix_domain_socket_name(base_dir = unix_domain_socket_dir)
    create_unix_domain_socket_name_prefix(base_dir) + "-#{Process.pid}"
  end

  ## Help

  def self.parse_help
    helps = Hash.new{|h, k| h[k] = []}
    desc = cat = nil
    cmds = Hash.new

    File.read(File.join(__dir__, 'session.rb'), encoding: Encoding::UTF_8).each_line do |line|
      case line
      when /\A\s*### (.+)/
        cat = $1
        break if $1 == 'END'
      when /\A      when (.+)/
        next unless cat
        next unless desc
        ws = $1.split(/,\s*/).map{|e| e.gsub('\'', '')}
        helps[cat] << [ws, desc]
        desc = nil
        max_w = ws.max_by{|w| w.length}
        ws.each{|w|
          cmds[w] = max_w
        }
      when /\A\s+# (\s*\*.+)/
        if desc
          desc << "\n" + $1
        else
          desc = $1
        end
      end
    end
    @commands = cmds
    @helps = helps
  end

  def self.helps
    (defined?(@helps) && @helps) || parse_help
  end

  def self.commands
    (defined?(@commands) && @commands) || (parse_help; @commands)
  end

  def self.help
    r = []
    self.helps.each{|cat, cmds|
      r << "### #{cat}"
      r << ''
      cmds.each{|ws, desc|
        r << desc
      }
      r << ''
    }
    r.join("\n")
  end
end
