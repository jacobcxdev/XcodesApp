#!/usr/bin/env ruby

require "json"
require "open3"
require "yaml"

repo_root = File.expand_path("..", __dir__)
workflow = YAML.safe_load_file(File.join(repo_root, ".github", "workflows", "appcast.yml"), aliases: false)
validation_step = workflow.fetch("jobs").fetch("build").fetch("steps").find do |step|
  step["name"] == "Validate expected published release"
end
raise "Release validation step is missing" unless validation_step

filter_match = validation_step.fetch("run").match(
  /jq -e --arg tag "\$EXPECTED_RELEASE_TAG" '\n(?<filter>.*?)\n\s*' <<< "\$release_json" >\/dev\/null/m
)
raise "Unable to extract release asset jq filter" unless filter_match

tag = "v4.0.4b39"
valid_release = {
  "tag_name" => tag,
  "draft" => false,
  "prerelease" => false,
  "assets" => [
    { "name" => "Xcodes.zip", "size" => 100 },
    { "name" => "Xcodes.zip.sha256", "size" => 64 },
    { "name" => "sparkle-signature.txt", "size" => 88 },
    { "name" => "release-manifest.txt", "size" => 256 },
  ],
}

validates = lambda do |release|
  _stdout, _stderr, status = Open3.capture3(
    "jq", "-e", "--arg", "tag", tag, filter_match[:filter], stdin_data: JSON.generate(release)
  )
  status.success?
end

raise "Exact release asset fixture was rejected" unless validates.call(valid_release)

invalid_releases = {
  "extra wrong ZIP before Xcodes.zip" => lambda do |release|
    release["assets"].unshift({ "name" => "wrong.zip", "size" => 20 })
  end,
  "duplicate Xcodes.zip" => lambda do |release|
    release["assets"] << { "name" => "Xcodes.zip", "size" => 100 }
  end,
  "zero-byte archive" => lambda do |release|
    release["assets"].find { |asset| asset["name"] == "Xcodes.zip" }["size"] = 0
  end,
  "zero-byte checksum" => lambda do |release|
    release["assets"].find { |asset| asset["name"] == "Xcodes.zip.sha256" }["size"] = 0
  end,
  "zero-byte signature" => lambda do |release|
    release["assets"].find { |asset| asset["name"] == "sparkle-signature.txt" }["size"] = 0
  end,
  "zero-byte manifest" => lambda do |release|
    release["assets"].find { |asset| asset["name"] == "release-manifest.txt" }["size"] = 0
  end,
  "missing asset" => lambda do |release|
    release["assets"].reject! { |asset| asset["name"] == "release-manifest.txt" }
  end,
}

invalid_releases.each do |label, mutate|
  release = Marshal.load(Marshal.dump(valid_release))
  mutate.call(release)
  raise "#{label} fixture unexpectedly passed" if validates.call(release)
end

puts "Appcast release asset fixtures passed"
