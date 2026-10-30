# Synthetic runner: executes the actual release lane with no Apple or signing access.
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'

$events = []
$mode = ARGV.fetch(1)
module UI
  def self.user_error!(message) = raise(message)
end
module Spaceship
  module ConnectAPI
    class App
      def self.find(_) = new
      def id = 'synthetic-app'
    end
    class Build
      class << self
        attr_accessor :uploaded
        def all(**_)
          return [] if uploaded && $mode == 'verification_missing'
          uploaded || $mode == 'duplicate' ? [new] : []
        end
        def get(**_) = new
      end
      def id = 'synthetic-build'
      def version = '87'
      def processing_state = $mode == 'processing_invalid' ? 'INVALID' : 'VALID'
      def uses_non_exempt_encryption = false
      def update(**_) = self
    end
  end
end
module Open3
  def self.capture2(*args)
    raise 'Unexpected subprocess' unless args == ['xcodebuild', '-version']
    ['Xcode 27.0\nBuild version synthetic', nil]
  end
end
def default_platform(_) = nil
def platform(_); yield; end
def desc(_) = nil
def lane(_, &block); $release_lane = block; end
def app_store_connect_api_key(**_) = {}
def create_keychain(**args)
  $events << 'keychain'
  File.write(args.fetch(:path), 'synthetic')
end
def import_certificate(**_) = $events << 'certificate'
def install_provisioning_profile(**_) = $events << 'profile'
def build_app(**args)
  $events << 'build'
  config = File.read(args.fetch(:xcconfig))
  raise 'Profile is not scoped to the app target' unless config.include?('OATH_RELEASE_PROFILE_OathAtmosphere = synthetic-profile') && config.include?('PROVISIONING_PROFILE_SPECIFIER = $(OATH_RELEASE_PROFILE_$(TARGET_NAME))')
  raise 'Global provisioning override is forbidden' if args[:xcargs]
  raise 'Synthetic build failure' if $mode == 'build_failure'
  File.write(File.join(args.fetch(:output_directory), args.fetch(:output_name)), 'synthetic IPA')
end
def upload_to_testflight(**args)
  $events << 'upload'
  raise 'External distribution must stay disabled' unless args[:distribute_external] == false
  raise 'Processing must be checked' unless args[:skip_waiting_for_build_processing] == false
  raise 'Synthetic upload failure' if $mode == 'upload_failure'
  Spaceship::ConnectAPI::Build.uploaded = true
end
def upload_to_app_store(**_) = raise('Forbidden automatic review path')
def delete_keychain(**args)
  $events << 'cleanup'
  FileUtils.rm_f(args.fetch(:keychain_path))
end

Dir.mktmpdir('oath-lane-fixture-') do |temporary|
  ENV['APP_SOURCE'] = File.join(temporary, 'source')
  ENV['SIGNING_DIRECTORY'] = File.join(temporary, 'signing')
  ENV['RELEASE_OUTPUT'] = File.join(temporary, 'output')
  ENV['ASC_KEY_ID'] = ENV['ASC_ISSUER_ID'] = ENV['APPLE_DISTRIBUTION_PASSWORD'] = 'synthetic'
  notes = File.join(ENV['APP_SOURCE'], 'Distribution/metadata/4.1.3/en-US')
  [notes, ENV['SIGNING_DIRECTORY'], ENV['RELEASE_OUTPUT']].each { |path| FileUtils.mkdir_p(path) }
  File.write(File.join(notes, 'release_notes.txt'), 'Synthetic notes')
  File.write(File.join(ENV['SIGNING_DIRECTORY'], 'profile.json'), JSON.generate({name: 'Synthetic Profile', uuid: 'synthetic-profile'}))
  File.write(File.join(ENV['RELEASE_OUTPUT'], 'source.json'), JSON.generate({version: '4.1.3', build: '87', source_commit: 'synthetic-source'}))
  load ARGV.fetch(0)
  failure = nil
  begin
    $release_lane.call
  rescue => error
    failure = error.message
  end
  receipt_path = File.join(ENV['RELEASE_OUTPUT'], 'receipt.json')
  receipt = File.exist?(receipt_path) ? JSON.parse(File.read(receipt_path)) : nil
  case $mode
  when 'success'
    raise failure if failure
    raise 'Upload was not verified' unless receipt['stage'] == 'uploaded_and_processed' && receipt['apple_build_id'] == 'synthetic-build'
    raise 'Review must remain unsubmitted' unless receipt['submitted_for_review'] == false
    raise 'Missing archive hash' unless receipt['ipa_sha256'].match?(/\A[a-f0-9]{64}\z/)
  when 'duplicate'
    raise 'Duplicate build reached signing' unless failure&.include?('already exists') && $events.empty?
  when 'upload_failure'
    raise 'Upload failure reported success' unless failure == 'Synthetic upload failure' && receipt['stage'] == 'archived'
  when 'build_failure'
    raise 'Failed archive was uploaded' unless failure == 'Synthetic build failure' && !$events.include?('upload') && receipt.nil?
  when 'verification_missing', 'processing_invalid'
    expected = $mode == 'verification_missing' ? 'Cannot verify the uploaded Apple build' : 'Apple has not validated the uploaded build'
    raise 'Unverified upload reported success' unless failure == expected && receipt['stage'] == 'uploaded_awaiting_verification' && receipt['apple_build_id'].nil?
  end
  raise 'Temporary keychain cleanup missing' unless $mode == 'duplicate' || $events.last == 'cleanup'
end
puts 'Synthetic upload lane passed: ' + $mode
