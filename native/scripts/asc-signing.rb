# Legt über die App-Store-Connect-API ein Distributions-Zertifikat und ein App-Store-Profil an
# und installiert beides auf dem Mac-Runner. Gibt keine geheimen Inhalte aus.
require 'openssl'; require 'base64'; require 'json'; require 'net/http'; require 'fileutils'
KEY = OpenSSL::PKey.read(File.read(ENV.fetch('ASC_KEY_PATH')))
BUNDLE = 'de.padelup.app'; PROFILE_NAME = 'PadelRun CI AppStore'
TMP = ENV.fetch('RUNNER_TEMP')

def jwt
  b = ->(x){ Base64.urlsafe_encode64(x, padding: false) }
  h = b.(JSON.dump({alg: 'ES256', kid: ENV['ASC_KEY_ID'], typ: 'JWT'}))
  t = Time.now.to_i
  p = b.(JSON.dump({iss: ENV['ASC_ISSUER_ID'], iat: t, exp: t + 600, aud: 'appstoreconnect-v1'}))
  der = KEY.sign(OpenSSL::Digest::SHA256.new, "#{h}.#{p}")
  sig = OpenSSL::ASN1.decode(der).value.map { |i| i.value.to_s(2).rjust(32, "\0")[-32, 32] }.join
  "#{h}.#{p}.#{b.(sig)}"
end

def api(method, path, body = nil)
  u = URI("https://api.appstoreconnect.apple.com#{path}")
  req = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }[method].new(u)
  req['Authorization'] = "Bearer #{jwt}"
  if body then req['Content-Type'] = 'application/json'; req.body = JSON.dump(body) end
  r = Net::HTTP.start(u.host, 443, use_ssl: true) { |x| x.request(req) }
  unless r.code.start_with?('2')
    abort "API #{method.upcase} #{u.path} -> #{r.code}: #{r.body[0, 800]}"
  end
  r.body.to_s.empty? ? {} : JSON.parse(r.body)
end

# 1) Alte CI-Zertifikate begrenzen (Apple erlaubt nur wenige Distributions-Zertifikate)
certs = api(:get, '/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50')['data']
certs.sort_by { |c| c['attributes']['expirationDate'].to_s }.first([certs.size - 1, 0].max).each do |c|
  api(:delete, "/v1/certificates/#{c['id']}"); puts "Altes Zertifikat widerrufen: #{c['id']}"
end

# 2) Neues Zertifikat aus frischem Schlüssel
rsa = OpenSSL::PKey::RSA.new(2048)
csr = OpenSSL::X509::Request.new
csr.subject = OpenSSL::X509::Name.parse('/CN=PadelRun CI/C=DE')
csr.public_key = rsa.public_key
csr.sign(rsa, OpenSSL::Digest::SHA256.new)
cert = api(:post, '/v1/certificates', { data: { type: 'certificates',
  attributes: { certificateType: 'DISTRIBUTION', csrContent: csr.to_pem } } })['data']
File.write("#{TMP}/dist.key.pem", rsa.to_pem)
File.binwrite("#{TMP}/dist.cer", Base64.decode64(cert['attributes']['certificateContent']))
puts "Zertifikat erstellt: #{cert['id']}"

# 3) Bundle-ID suchen
b = api(:get, "/v1/bundleIds?filter[identifier]=#{BUNDLE}&limit=5")['data'].find { |x| x['attributes']['identifier'] == BUNDLE }
abort "Bundle-ID #{BUNDLE} nicht gefunden" unless b

# 4) Altes Profil gleichen Namens löschen, neues anlegen
api(:get, '/v1/profiles?limit=200')['data'].select { |pr| pr['attributes']['name'] == PROFILE_NAME }.each do |pr|
  api(:delete, "/v1/profiles/#{pr['id']}")
end
prof = api(:post, '/v1/profiles', { data: { type: 'profiles',
  attributes: { name: PROFILE_NAME, profileType: 'IOS_APP_STORE' },
  relationships: { bundleId: { data: { type: 'bundleIds', id: b['id'] } },
                   certificates: { data: [{ type: 'certificates', id: cert['id'] }] } } } })['data']
dir = File.expand_path('~/Library/MobileDevice/Provisioning Profiles')
FileUtils.mkdir_p(dir)
File.binwrite(File.join(dir, "#{prof['attributes']['uuid']}.mobileprovision"), Base64.decode64(prof['attributes']['profileContent']))
puts "Profil erstellt: #{PROFILE_NAME} (#{prof['attributes']['uuid']})"
File.open(ENV['GITHUB_ENV'], 'a') { |f| f.puts "PROFILE_UUID=#{prof['attributes']['uuid']}" }
