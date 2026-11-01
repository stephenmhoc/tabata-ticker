#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "shellwords"
require "tmpdir"
require "time"
require "uri"

API_BASE = "https://api.appstoreconnect.apple.com"
PROCESSING_TIMEOUT_MINUTES = 45
DEFAULT_TEST_NOTES = "Bug fixes and improvements."
MAX_TEST_NOTES_LENGTH = 4000

def env_fetch(name)
  ENV.fetch(name) do
    warn "Missing required environment variable: #{name}"
    exit 1
  end
end

def base64url(data)
  Base64.urlsafe_encode64(data).delete("=")
end

def int_to_fixed_bytes(integer, width)
  bytes = []
  value = integer
  while value.positive?
    bytes.unshift(value & 0xff)
    value >>= 8
  end
  bytes.pack("C*").rjust(width, "\0")
end

def jwt_token
  key_id = env_fetch("ASC_KEY_ID")
  issuer_id = env_fetch("ASC_ISSUER_ID")
  key_path = env_fetch("ASC_API_KEY_PATH")
  key = OpenSSL::PKey.read(File.read(key_path))
  now = Time.now.to_i

  header = { alg: "ES256", kid: key_id, typ: "JWT" }
  payload = {
    iss: issuer_id,
    iat: now - 30,
    exp: now + 600,
    aud: "appstoreconnect-v1"
  }

  signing_input = "#{base64url(JSON.generate(header))}.#{base64url(JSON.generate(payload))}"
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  der_signature = key.dsa_sign_asn1(digest)
  signature = OpenSSL::ASN1.decode(der_signature)
  r = int_to_fixed_bytes(signature.value[0].value.to_i, 32)
  s = int_to_fixed_bytes(signature.value[1].value.to_i, 32)

  "#{signing_input}.#{base64url(r + s)}"
end

class AppStoreConnectClient
  def initialize
    @token = jwt_token
  end

  def get(path)
    request(Net::HTTP::Get, path)
  end

  def post(path, body)
    request(Net::HTTP::Post, path, body)
  end

  def patch(path, body)
    request(Net::HTTP::Patch, path, body)
  end

  def delete(path)
    request(Net::HTTP::Delete, path)
  end

  private

  def request(request_class, path, body = nil)
    uri = URI.join(API_BASE, path)
    request = request_class.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    return {} if response.code.to_i == 204

    parsed = response.body.empty? ? {} : JSON.parse(response.body)
    return parsed if response.code.to_i.between?(200, 299)

    warn JSON.pretty_generate(parsed)
    warn "App Store Connect API request failed: #{request.method} #{uri} -> #{response.code}"
    exit 1
  end
end

def run_command(*args)
  puts args.shelljoin
  return if system(*args)

  warn "Command failed: #{args.shelljoin}"
  exit 1
end

def find_or_create_bundle_id(client, identifier:, name:)
  query = URI.encode_www_form("filter[identifier]" => identifier, "limit" => 200)
  response = client.get("/v1/bundleIds?#{query}")
  existing = response.fetch("data", []).find do |bundle_id|
    bundle_id.fetch("attributes").fetch("identifier") == identifier
  end
  return existing.fetch("id") if existing

  puts "Creating Bundle ID #{identifier}"
  created = client.post(
    "/v1/bundleIds",
    {
      data: {
        type: "bundleIds",
        attributes: {
          name: name,
          identifier: identifier,
          platform: "IOS"
        }
      }
    }
  )
  created.fetch("data").fetch("id")
end

def create_distribution_certificate(client, temp_dir)
  key_path = File.join(temp_dir, "apple_distribution.key")
  csr_path = File.join(temp_dir, "apple_distribution.csr")
  cer_path = File.join(temp_dir, "apple_distribution.cer")
  pem_path = File.join(temp_dir, "apple_distribution.pem")
  p12_path = File.join(temp_dir, "certificate.p12")

  run_command(
    "openssl", "req",
    "-new", "-newkey", "rsa:2048", "-nodes",
    "-keyout", key_path,
    "-out", csr_path,
    "-subj", "/CN=Tabata Ticker CI/O=Tabata Ticker/C=US"
  )

  response = client.post(
    "/v1/certificates",
    {
      data: {
        type: "certificates",
        attributes: {
          certificateType: "DISTRIBUTION",
          csrContent: File.read(csr_path)
        }
      }
    }
  )

  certificate = response.fetch("data")
  File.binwrite(cer_path, Base64.decode64(certificate.fetch("attributes").fetch("certificateContent")))
  run_command("openssl", "x509", "-inform", "DER", "-in", cer_path, "-out", pem_path)
  run_command(
    "openssl", "pkcs12",
    "-export",
    "-inkey", key_path,
    "-in", pem_path,
    "-out", p12_path,
    "-passout", "pass:#{env_fetch("KEYCHAIN_PASSWORD")}"
  )

  {
    id: certificate.fetch("id"),
    p12_path: p12_path
  }
end

def create_profile(client, name:, bundle_id:, certificate_id:, output_path:)
  response = client.post(
    "/v1/profiles",
    {
      data: {
        type: "profiles",
        attributes: {
          name: name,
          profileType: "IOS_APP_STORE"
        },
        relationships: {
          bundleId: {
            data: {
              type: "bundleIds",
              id: bundle_id
            }
          },
          certificates: {
            data: [
              {
                type: "certificates",
                id: certificate_id
              }
            ]
          }
        }
      }
    }
  )

  profile = response.fetch("data")
  File.binwrite(output_path, Base64.decode64(profile.fetch("attributes").fetch("profileContent")))
  {
    id: profile.fetch("id"),
    name: profile.fetch("attributes").fetch("name")
  }
end

def append_env(values)
  github_env = env_fetch("GITHUB_ENV")
  File.open(github_env, "a") do |file|
    values.each do |key, value|
      file.puts("#{key}=#{value}")
    end
  end
end

# Finds this certificate's profile for a target, or makes one the first time. Named after the
# certificate, so that replacing it makes new profiles.
def fetch_profile(client, name:, identifier:, bundle_name:, certificate_id:, output_path:)
  query = URI.encode_www_form("filter[name]" => name, "filter[profileState]" => "ACTIVE", "limit" => 200)
  profile = client.get("/v1/profiles?#{query}").fetch("data").find do |candidate|
    candidate.fetch("attributes").fetch("name") == name
  end

  if profile
    File.binwrite(output_path, Base64.decode64(profile.fetch("attributes").fetch("profileContent")))
  else
    create_profile(
      client,
      name: name,
      bundle_id: find_or_create_bundle_id(client, identifier: identifier, name: bundle_name),
      certificate_id: certificate_id,
      output_path: output_path
    )
  end
end

# Revoking a certificate invalidates what it signed, and TestFlight review checks the signature
# after processing (ITMS-90035), so one certificate stays for as long as builds need it.
def prepare
  client = AppStoreConnectClient.new
  temp_dir = env_fetch("RUNNER_TEMP")
  certificate_id = env_fetch("APPLE_DISTRIBUTION_CERT_ID")
  p12_path = File.join(temp_dir, "certificate.p12")
  ios_profile_path = File.join(temp_dir, "ios.mobileprovision")
  watch_profile_path = File.join(temp_dir, "watch.mobileprovision")
  live_activity_profile_path = File.join(temp_dir, "live_activity.mobileprovision")

  FileUtils.mkdir_p(temp_dir)
  File.binwrite(p12_path, Base64.decode64(env_fetch("APPLE_DISTRIBUTION_CERT_BASE64")))

  fetch_profile(
    client,
    name: "Tabata Ticker iOS #{certificate_id}",
    identifier: env_fetch("IOS_BUNDLE_ID"),
    bundle_name: "Tabata Ticker",
    certificate_id: certificate_id,
    output_path: ios_profile_path
  )
  fetch_profile(
    client,
    name: "Tabata Ticker Watch #{certificate_id}",
    identifier: env_fetch("WATCH_BUNDLE_ID"),
    bundle_name: "Tabata Ticker Watch App",
    certificate_id: certificate_id,
    output_path: watch_profile_path
  )
  fetch_profile(
    client,
    name: "Tabata Ticker Live Activity #{certificate_id}",
    identifier: env_fetch("LIVE_ACTIVITY_BUNDLE_ID"),
    bundle_name: "Tabata Ticker Live Activity",
    certificate_id: certificate_id,
    output_path: live_activity_profile_path
  )

  append_env(
    "APPLE_CERTIFICATE_PATH" => p12_path,
    "APPLE_CERTIFICATE_PASSWORD" => env_fetch("APPLE_DISTRIBUTION_CERT_PASSWORD"),
    "IOS_PROVISIONING_PROFILE_PATH" => ios_profile_path,
    "WATCH_PROVISIONING_PROFILE_PATH" => watch_profile_path,
    "LIVE_ACTIVITY_PROVISIONING_PROFILE_PATH" => live_activity_profile_path
  )
end

# Run once by hand, and again when the certificate nears its expiry. Goes straight to GitHub's
# secrets, so the private key never stays on this machine.
def create_distribution_cert
  repo = "stephenmhoc/tabata-ticker"
  password = SecureRandom.hex(24)
  ENV["KEYCHAIN_PASSWORD"] = password
  Dir.mktmpdir do |temp_dir|
    certificate = create_distribution_certificate(AppStoreConnectClient.new, temp_dir)
    {
      "APPLE_DISTRIBUTION_CERT_BASE64" => Base64.strict_encode64(File.binread(certificate.fetch(:p12_path))),
      "APPLE_DISTRIBUTION_CERT_PASSWORD" => password,
      "APPLE_DISTRIBUTION_CERT_ID" => certificate.fetch(:id)
    }.each do |name, value|
      IO.popen(["gh", "secret", "set", name, "-R", repo], "w") { |gh| gh.write(value) }
      abort "Couldn't set #{name}." unless $?.success?
      puts "Set #{name}"
    end
  end
end

def find_app(client)
  bundle_identifier = env_fetch("IOS_BUNDLE_ID")
  app_query = URI.encode_www_form("filter[bundleId]" => bundle_identifier, "limit" => 200)
  app = client.get("/v1/apps?#{app_query}").fetch("data").find do |candidate|
    candidate.fetch("attributes").fetch("bundleId") == bundle_identifier
  end
  return app.fetch("id") if app

  warn "No App Store Connect app has the bundle ID #{bundle_identifier}"
  exit 1
end

def build_query(app_id)
  URI.encode_www_form("filter[app]" => app_id, "filter[version]" => env_fetch("BUILD_NUMBER"), "limit" => 1)
end

def wait_for_processing
  build_number = env_fetch("BUILD_NUMBER")
  query = build_query(find_app(AppStoreConnectClient.new))
  deadline = Time.now + (PROCESSING_TIMEOUT_MINUTES * 60)
  while Time.now < deadline
    # A new client each time, because its token only lasts ten minutes.
    build = AppStoreConnectClient.new.get("/v1/builds?#{query}").fetch("data").first
    state = build&.fetch("attributes")&.fetch("processingState") || "not visible yet"
    puts "Build #{build_number}: #{state}"

    case state
    when "VALID"
      return
    when "FAILED", "INVALID"
      warn "App Store Connect rejected build #{build_number}. Apple's email has the reason."
      exit 1
    end
    sleep 30
  end

  warn "Build #{build_number} wasn't ready after #{PROCESSING_TIMEOUT_MINUTES} minutes. " \
       "A rejected upload never appears, so check Apple's email."
  exit 1
end

# Sets the test notes for testers and reviewers.
def set_test_notes(client, build_id, notes)
  localizations = client.get("/v1/builds/#{build_id}/betaBuildLocalizations").fetch("data")
  if localizations.empty?
    client.post(
      "/v1/betaBuildLocalizations",
      {
        data: {
          type: "betaBuildLocalizations",
          attributes: { locale: "en-US", whatsNew: notes },
          relationships: { build: { data: { type: "builds", id: build_id } } }
        }
      }
    )
  end
  localizations.each do |localization|
    client.patch(
      "/v1/betaBuildLocalizations/#{localization.fetch('id')}",
      { data: { type: "betaBuildLocalizations", id: localization.fetch("id"), attributes: { whatsNew: notes } } }
    )
  end
end

# Gives a processed build to every external group and sends it to Beta App Review.
def distribute
  client = AppStoreConnectClient.new
  app_id = find_app(client)
  build = client.get("/v1/builds?#{build_query(app_id)}").fetch("data").first
  unless build
    warn "App Store Connect has no build #{env_fetch('BUILD_NUMBER')}"
    exit 1
  end
  build_id = build.fetch("id")

  groups = client.get("/v1/apps/#{app_id}/betaGroups?limit=200").fetch("data").reject do |group|
    group.fetch("attributes").fetch("isInternalGroup")
  end
  if groups.empty?
    warn "No external TestFlight group exists for #{env_fetch('IOS_BUNDLE_ID')}"
    exit 1
  end

  notes = ENV.fetch("TEST_NOTES", "").strip
  notes = DEFAULT_TEST_NOTES if notes.empty?
  set_test_notes(client, build_id, notes[0, MAX_TEST_NOTES_LENGTH])

  groups.each do |group|
    puts "Adding the build to #{group.fetch('attributes').fetch('name')}"
    client.post("/v1/betaGroups/#{group.fetch('id')}/relationships/builds", { data: [{ type: "builds", id: build_id }] })
  end

  # Apple can move a build along by itself, and a retry can find one already submitted.
  state = client.get("/v1/builds/#{build_id}/buildBetaDetail").fetch("data").fetch("attributes").fetch("externalBuildState")
  puts "External state: #{state}"
  return unless state == "READY_FOR_BETA_SUBMISSION"

  client.post(
    "/v1/betaAppReviewSubmissions",
    {
      data: {
        type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: build_id } } }
      }
    }
  )
  puts "Submitted the build for Beta App Review"
end

case ARGV.fetch(0, "prepare")
when "prepare"
  prepare
when "wait"
  wait_for_processing
when "distribute"
  distribute
when "create-distribution-cert"
  create_distribution_cert
else
  warn "Usage: #{File.basename($PROGRAM_NAME)} [prepare|create-distribution-cert|wait|distribute]"
  exit 1
end
