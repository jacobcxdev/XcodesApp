#!/usr/bin/env ruby

require "json"
require "open3"
require "tempfile"
require "time"
require "uri"

TAG_PATTERN = /\Av(?<version>[0-9]+\.[0-9]+\.[0-9]+)b(?<build>0|[1-9][0-9]*)\z/
ASSET_NAMES = [
  "Xcodes.zip",
  "Xcodes.zip.sha256",
  "sparkle-signature.txt",
  "release-manifest.txt",
].freeze

def fail_contract(message)
  raise ArgumentError, message
end

def capture!(*command, chdir: nil, env: {})
  options = {}
  options[:chdir] = chdir if chdir
  stdout, _stderr, status = Open3.capture3(env, *command, **options)
  fail_contract("command failed: #{command.first}") unless status.success?
  stdout
end

def valid_real_directory!(path, label)
  fail_contract("#{label} must be a real directory") unless File.directory?(path) && !File.symlink?(path)
  File.realpath(path)
end

def validate_output_path!(path, label)
  fail_contract("#{label} already exists") if File.exist?(path) || File.symlink?(path)
  valid_real_directory!(File.dirname(path), "#{label} parent")
end

def validate_release_shape!(release, repository)
  fail_contract("release entry must be an object") unless release.is_a?(Hash)
  tag = release["tag_name"]
  fail_contract("release tag must match vX.Y.ZbN exactly") unless TAG_PATTERN.match?(tag.to_s)
  fail_contract("published release prerelease flag is invalid") unless [true, false].include?(release["prerelease"])
  fail_contract("published release name is invalid") unless release["name"].nil? || release["name"].is_a?(String)
  fail_contract("published release body is invalid") unless release["body"].is_a?(String)
  published_at = release["published_at"]
  fail_contract("published release timestamp is invalid") unless published_at.is_a?(String)
  begin
    published_time = Time.iso8601(published_at)
  rescue ArgumentError
    fail_contract("published release timestamp is invalid")
  end

  assets = release["assets"]
  fail_contract("published release assets must be an array") unless assets.is_a?(Array)
  fail_contract("published release assets must match the exact contract") unless assets.all? { |asset| asset.is_a?(Hash) }
  names = assets.map { |asset| asset["name"] }
  fail_contract("published release assets must match the exact contract") unless names.sort == ASSET_NAMES.sort
  assets.each do |asset|
    size = asset["size"]
    fail_contract("published release assets must be non-empty") unless size.is_a?(Integer) && size.positive?
  end

  zip_asset = assets.fetch(names.index("Xcodes.zip"))
  zip_url = zip_asset["browser_download_url"]
  begin
    parsed_url = URI.parse(zip_url.to_s)
  rescue URI::InvalidURIError
    fail_contract("published Xcodes.zip URL is invalid")
  end
  expected_path = "/#{repository}/releases/download/#{tag}/Xcodes.zip"
  unless parsed_url.scheme == "https" && parsed_url.host == "github.com" &&
      parsed_url.path == expected_path && parsed_url.query.nil? && parsed_url.fragment.nil?
    fail_contract("published Xcodes.zip URL is invalid")
  end

  [tag, published_time, zip_asset]
end

def write_json_atomically(path, value)
  directory = File.dirname(path)
  Tempfile.create([".validated-appcast-", ".json"], directory, mode: 0o600) do |file|
    file.write(JSON.pretty_generate(value))
    file.write("\n")
    file.flush
    file.fsync
    file.close
    File.rename(file.path, path)
  end
end

begin
  expected_tag, release_root, releases_output, signatures_output, verifier, trusted_plist, repository_root = ARGV
  fail_contract("usage: validate_appcast_history <expected-tag> <release-root> <releases-json> <signatures-json> <verifier> <trusted-plist> <repository-root>") unless ARGV.length == 7
  fail_contract("expected release tag must match vX.Y.ZbN exactly") unless TAG_PATTERN.match?(expected_tag.to_s)
  repository = ENV.fetch("GITHUB_REPOSITORY", "")
  fail_contract("GitHub repository must be jacobcxdev/XcodesApp") unless repository == "jacobcxdev/XcodesApp"

  release_root = valid_real_directory!(release_root, "release root")
  fail_contract("release root must start empty") unless Dir.empty?(release_root)
  repository_root = valid_real_directory!(repository_root, "repository root")
  fail_contract("compiled signature verifier is required") unless File.file?(verifier) && File.executable?(verifier) && !File.symlink?(verifier)
  fail_contract("trusted Info.plist is required") unless File.file?(trusted_plist) && !File.symlink?(trusted_plist)
  validate_output_path!(releases_output, "validated releases output")
  validate_output_path!(signatures_output, "validated signatures output")

  raw_json = capture!(
    "gh", "api", "--paginate", "--slurp",
    "repos/#{repository}/releases?per_page=100"
  )
  pages = JSON.parse(raw_json)
  fail_contract("paginated releases response must contain arrays") unless pages.is_a?(Array) && pages.all? { |page| page.is_a?(Array) }
  releases = pages.flatten(1)
  releases.each do |release|
    fail_contract("release entry must be an object") unless release.is_a?(Hash)
    fail_contract("release draft flag is invalid") unless [true, false].include?(release["draft"])
  end
  published_releases = releases.reject { |release| release["draft"] }

  validated_shapes = published_releases.map do |release|
    tag, published_time, zip_asset = validate_release_shape!(release, repository)
    [release, tag, published_time, zip_asset]
  end
  tags = validated_shapes.map { |(_release, tag, _time, _zip)| tag }
  fail_contract("published release tags must be unique") unless tags.uniq.length == tags.length
  expected = validated_shapes.select { |(_release, tag, _time, _zip)| tag == expected_tag }
  fail_contract("expected published release must be present exactly once") unless expected.one?
  fail_contract("expected release must not be marked prerelease") if expected.first.first["prerelease"]

  capture!(
    "git", "fetch", "--force", "--no-tags", "origin",
    "+refs/heads/main:refs/remotes/origin/main",
    chdir: repository_root
  )
  head_commit = capture!("git", "rev-parse", "HEAD^{commit}", chdir: repository_root).strip
  tag_commits = {}
  tags.sort.each do |tag|
    capture!(
      "git", "fetch", "--force", "--no-tags", "origin",
      "+refs/tags/#{tag}:refs/tags/#{tag}",
      chdir: repository_root
    )
    commit = capture!("git", "rev-parse", "refs/tags/#{tag}^{commit}", chdir: repository_root).strip
    capture!("git", "merge-base", "--is-ancestor", commit, "origin/main", chdir: repository_root)
    tag_commits[tag] = commit
  end
  fail_contract("expected release tag does not match checked-out workflow source") unless tag_commits.fetch(expected_tag) == head_commit

  support_root = File.expand_path("..", __dir__)
  validated_releases = []
  validated_signatures = {}
  validated_shapes.sort_by { |(_release, tag, published_time, _zip)| [-published_time.to_f, tag] }.each do |release, tag, _published_time, zip_asset|
    release_dir = File.join(release_root, tag)
    Dir.mkdir(release_dir, 0o700)
    ASSET_NAMES.each do |asset_name|
      capture!(
        "gh", "release", "download", tag,
        "--repo", repository,
        "--pattern", asset_name,
        "--dir", release_dir
      )
      downloaded_asset = File.join(release_dir, asset_name)
      api_asset = release.fetch("assets").find { |asset| asset["name"] == asset_name }
      fail_contract("downloaded release asset size does not match GitHub") unless File.size(downloaded_asset) == api_asset.fetch("size")
    end

    Tempfile.create(["appcast-release-body-", ".txt"], release_root, mode: 0o600) do |body_file|
      body_file.write(release.fetch("body"))
      body_file.flush
      capture!(
        "bash", File.join(support_root, "Scripts", "validate_appcast_release.sh"),
        release_dir, tag, body_file.path, trusted_plist,
        env: { "SPARKLE_SIGNATURE_VERIFIER" => verifier }
      )
    end

    signature = File.read(File.join(release_dir, "sparkle-signature.txt"), chomp: true)
    validated_signatures[tag] = signature
    validated_releases << {
      "tag_name" => tag,
      "name" => release["name"].to_s.empty? ? tag : release["name"],
      "body" => release.fetch("body"),
      "draft" => false,
      "prerelease" => release.fetch("prerelease"),
      "published_at" => release.fetch("published_at"),
      "assets" => [
        {
          "name" => "Xcodes.zip",
          "browser_download_url" => zip_asset.fetch("browser_download_url"),
          "size" => zip_asset.fetch("size"),
        },
      ],
    }
  end

  write_json_atomically(releases_output, validated_releases)
  write_json_atomically(signatures_output, validated_signatures.sort.to_h)
  puts "Validated #{validated_releases.length} published releases for appcast rendering."
rescue JSON::ParserError, KeyError, SystemCallError, ArgumentError => error
  warn "error: #{error.message}"
  exit 1
end
