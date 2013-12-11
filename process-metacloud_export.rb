#! /usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'

require 'metacloud-export'

options = MetacloudExport::Opts.parse ARGV