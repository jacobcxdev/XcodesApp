#!/usr/bin/env ruby

require "json"

catalog_path = ARGV.fetch(0, File.expand_path("../Xcodes/Resources/Localizable.xcstrings", __dir__))
catalog = JSON.parse(File.read(catalog_path))
languages = %w[ar ca de el es fi fr hi it ja ko nl pl pt-BR ru th tr uk zh-Hans zh-Hant].freeze
established_languages = languages - %w[ar th]
baseline_keys = %w[AutomaticallyCreateBetaSymbolicLink AutomaticallyCreateBetaSymbolicLinkDescription].freeze
arabic_thai_baseline_keys = [
  "An error occurred",
  "Architecture",
  "AutomaticallyCreateBetaSymbolicLink",
  "AutomaticallyCreateBetaSymbolicLinkDescription",
  "Category",
  "Dismiss",
  "FilterArchitecturesDescription",
  "Installed Only",
  "Open Browser",
  "Paste redirected URL",
  "Signing out...",
  "This Apple ID uses federated authentication via %@.",
].freeze
allowed_missing = (
  baseline_keys.product(established_languages) +
  arabic_thai_baseline_keys.product(%w[ar th])
).map { |key, language| "#{key}:#{language}" }.sort.freeze

translated = lambda do |localization|
  if localization.key?("stringUnit")
    localization.dig("stringUnit", "state") == "translated"
  elsif localization.key?("variations")
    units = []
    visit = lambda do |value|
      case value
      when Hash
        units << value["state"] if value.key?("state") && value.key?("value")
        value.each_value { |child| visit.call(child) }
      when Array
        value.each { |child| visit.call(child) }
      end
    end
    visit.call(localization["variations"])
    !units.empty? && units.all? { |state| state == "translated" }
  else
    false
  end
end

missing = catalog.fetch("strings").flat_map do |key, value|
  localizations = value.fetch("localizations", {})
  languages.filter_map do |language|
    localization = localizations[language]
    "#{key}:#{language}" unless localization && translated.call(localization)
  end
end.sort

unexpected = missing - allowed_missing
resolved = allowed_missing - missing
errors = []
errors << "New missing or unreviewed translations:\n  #{unexpected.join("\n  ")}" unless unexpected.empty?
errors << "Localization baseline is stale; remove resolved entries:\n  #{resolved.join("\n  ")}" unless resolved.empty?

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "Localization contract passed with #{allowed_missing.length} explicitly tracked gaps"
