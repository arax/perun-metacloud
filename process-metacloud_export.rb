#! /usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'metacloud-export'

logger = Logger.new(STDERR)
logger.level = Logger::DEBUG

begin
  options = MetacloudExport::Opts.parse ARGV

  logger = Logger.new(options.log.out)
  logger.level = options.log.level

  logger.debug "Connecting to #{options.target.endpoint.to_s.inspect}"
  process = MetacloudExport::Process.new(
    options.source,
    options.target,
    logger
  )
  process.run
rescue Exception => ex
  logger.error ex.message if logger
  raise ex if options.nil? || options.debug

  exit! 255
end
