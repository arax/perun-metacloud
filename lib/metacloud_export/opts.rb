class MetacloudExport::Opts

  LOG_OUTPUTS = [:stdout, :stderr].freeze
  LOG_LEVELS = [:debug, :error, :fatal, :info, :unknown, :warn].freeze

  def self.parse(args)
    options = Hashie::Mash.new

    options.source = ARGF
    options.debug = false

    options.target!.endpoint = ENV['ONE_XMLRPC'] ? URI(ENV['ONE_XMLRPC']) : URI('http://localhost:2633/RPC2')

    if ENV['ONE_AUTH']
      creds = File.read(ENV['ONE_AUTH']).split(':')

      options.target!.username = creds.first
      options.target!.password = creds.last
    else
      options.target!.username = "oneadmin"
      options.target!.password = "onepass"
    end

    options.log!.out = STDERR
    options.log!.level = Logger::ERROR

    opts = OptionParser.new do |opts|
      opts.banner = %{Usage: process-metacloud_export.rb [OPTIONS]}

      opts.separator ""
      opts.separator "Options:"

      opts.on("-e",
              "--endpoint URI",
              String,
              "ONE XML-RPC endpoint") do |endpoint|
        options.endpoint = URI(endpoint)
      end

      opts.on("-u",
              "--username NAME",
              String,
              "ONE XML-RPC username") do |username|
        options.username = username
      end

      opts.on("-p",
              "--password PASS",
              String,
              "ONE XML-RPC password") do |password|
        options.password = password
      end

      opts.on("-s",
              "--source FILE",
              String,
              "Data source, formatted as JSON") do |source|
        unless source =~ /stdin|STDIN/
          options.source = File.open(source.gsub('file://', ''))
        end
      end

      opts.on("-l",
              "--log-to OUTPUT",
              LOG_OUTPUTS,
              "Log to the specified device, defaults to 'stderr'") do |log_to|
        options.log.out = STDOUT if log_to == :stdout
      end

      opts.on("-b",
              "--log-level LEVEL",
              LOG_LEVELS,
              "Set the specified logging level") do |log_level|
        unless options.log.level == Logger::DEBUG
          options.log.level = Logger.const_get(log_level.to_s.upcase)
        end
      end

      opts.on_tail("-d",
                   "--debug",
                   "Enable debugging messages") do |debug|
        options.debug = debug
        options.log.level = Logger::DEBUG
      end

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit! true
      end

      opts.on_tail("-v", "--version", "Show version") do
        puts MetacloudExport::VERSION
      end
    end

    begin
      opts.parse!(args)
    rescue Exception => ex
      puts ex.message.capitalize
      puts opts
      exit!
    end

    options
  end

end
