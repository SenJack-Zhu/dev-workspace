#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

def required_environment(name)
  value = ENV[name]
  abort("Missing required environment variable: #{name}") if value.nil? || value.strip.empty?
  value.strip
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def raw_ecdsa_signature(der_signature, width: 32)
  sequence = OpenSSL::ASN1.decode(der_signature)
  sequence.value.map do |integer|
    bytes = integer.value.to_s(2)
    abort("Invalid ECDSA signature component") if bytes.bytesize > width
    bytes.rjust(width, "\0")
  end.join
end

def api_key
  configured = ENV["APP_STORE_CONNECT_KEY_ID"]
  return configured.strip unless configured.nil? || configured.strip.empty?

  candidates = Dir.glob(File.expand_path("~/.appstoreconnect/private_keys/AuthKey_*.p8"))
  abort("Expected exactly one App Store Connect private key") unless candidates.length == 1
  File.basename(candidates.first).delete_prefix("AuthKey_").delete_suffix(".p8")
end

def private_key_path(key_id)
  File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{key_id}.p8")
end

def bearer_token(issuer_id, key_id)
  now = Time.now.to_i
  header = base64url(JSON.generate({ alg: "ES256", kid: key_id, typ: "JWT" }))
  claims = base64url(JSON.generate({
    iss: issuer_id,
    iat: now,
    exp: now + 1_200,
    aud: "appstoreconnect-v1",
  }))
  signing_input = "#{header}.#{claims}"
  key = OpenSSL::PKey.read(File.read(private_key_path(key_id)))
  signature = raw_ecdsa_signature(key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input)))
  "#{signing_input}.#{base64url(signature)}"
end

method = ARGV.shift&.upcase
path = ARGV.shift
abort("usage: tool/app_store_connect_api.rb <GET|POST|PATCH|DELETE> <path> [json]") unless %w[GET POST PATCH DELETE].include?(method) && path

body = ARGV.shift
abort("Unexpected extra arguments") unless ARGV.empty?
if %w[POST PATCH].include?(method)
  abort("#{method} requires a JSON body") if body.nil? || body.empty?
  JSON.parse(body)
elsif body
  abort("#{method} does not accept a body")
end

issuer_id = required_environment("APP_STORE_CONNECT_ISSUER_ID")
key_id = api_key
uri = URI.join("https://api.appstoreconnect.apple.com", path)
request_class = {
  "GET" => Net::HTTP::Get,
  "POST" => Net::HTTP::Post,
  "PATCH" => Net::HTTP::Patch,
  "DELETE" => Net::HTTP::Delete,
}.fetch(method)
request = request_class.new(uri)
request["Authorization"] = "Bearer #{bearer_token(issuer_id, key_id)}"
request["Content-Type"] = "application/json" if body
request.body = body if body

response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
  http.request(request)
end
puts response.body unless response.body.nil? || response.body.empty?
unless response.code.to_i.between?(200, 299)
  warn("App Store Connect API request failed with HTTP #{response.code}")
  exit 1
end
