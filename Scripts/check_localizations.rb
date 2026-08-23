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

legacy_terms = /Apple(?:\s+|-)?ID\b|\bID Apple\b|\bID de Apple\b|\bIdentifiant Apple\b/i
legacy_terminology = catalog.fetch("strings").flat_map do |key, value|
  value.fetch("localizations", {}).filter_map do |language, localization|
    values = []
    visit = lambda do |node|
      case node
      when Hash
        values << node["value"] if node["value"].is_a?(String)
        node.each_value { |child| visit.call(child) }
      when Array
        node.each { |child| visit.call(child) }
      end
    end
    visit.call(localization)
    "#{key}:#{language}" if values.any? { |text| text.match?(legacy_terms) }
  end
end.sort

forbidden_keys = catalog.fetch("strings").keys.grep(legacy_terms)

required_keys = [
  "AppBehaviour",
  "AppleAccount",
  "AuthError.NotAuthorized",
  "AuthError.PasswordRequired",
  "AuthError.PrivacyAcknowledgementRequired",
  "CheckingAppleAccount",
  "CheckingNotificationSettings",
  "ManageAppleAccount",
  "SignInToAppleAccount",
  "SignedIn",
  "This Apple Account uses federated authentication via %@.",
].reject { |key| catalog.fetch("strings").key?(key) }

required_grouping_values = {
  "ar" => "تجميع إصدارات Xcode في القائمة",
  "ca" => "Agrupa les versions d’Xcode a la llista",
  "de" => "Xcode-Versionen in der Liste gruppieren",
  "el" => "Ομαδοποίηση εκδόσεων Xcode στη λίστα",
  "en" => "Group Xcode versions in the list",
  "es" => "Agrupar las versiones de Xcode en la lista",
  "fi" => "Ryhmittele Xcode-versiot luettelossa",
  "fr" => "Regrouper les versions de Xcode dans la liste",
  "hi" => "सूची में Xcode संस्करणों को समूहित करें",
  "it" => "Raggruppa le versioni di Xcode nell’elenco",
  "ja" => "リスト内のXcodeバージョンをグループ化",
  "ko" => "목록에서 Xcode 버전 그룹화",
  "nl" => "Xcode-versies in de lijst groeperen",
  "pl" => "Grupuj wersje Xcode na liście",
  "pt-BR" => "Agrupar versões do Xcode na lista",
  "ru" => "Группировать версии Xcode в списке",
  "th" => "จัดกลุ่มเวอร์ชัน Xcode ในรายการ",
  "tr" => "Listedeki Xcode sürümlerini grupla",
  "uk" => "Групувати версії Xcode у списку",
  "zh-Hans" => "在列表中将 Xcode 版本分组",
  "zh-Hant" => "將列表中的 Xcode 版本分組",
}.freeze

grouping_localizations = catalog.fetch("strings").fetch("GroupXcodeVersionsInList").fetch("localizations")
incorrect_grouping_values = required_grouping_values.filter_map do |language, expected_value|
  actual_value = grouping_localizations.dig(language, "stringUnit", "value")
  "GroupXcodeVersionsInList:#{language} expected #{expected_value.inspect}, got #{actual_value.inspect}" unless actual_value == expected_value
end

unexpected = missing - allowed_missing
resolved = allowed_missing - missing
errors = []
errors << "New missing or unreviewed translations:\n  #{unexpected.join("\n  ")}" unless unexpected.empty?
errors << "Localization baseline is stale; remove resolved entries:\n  #{resolved.join("\n  ")}" unless resolved.empty?
errors << "Legacy Apple ID terminology remains:\n  #{legacy_terminology.join("\n  ")}" unless legacy_terminology.empty?
errors << "Legacy localization keys remain:\n  #{forbidden_keys.join("\n  ")}" unless forbidden_keys.empty?
errors << "Required localization keys are missing:\n  #{required_keys.join("\n  ")}" unless required_keys.empty?
errors << "Grouped-version translations are mapped to the wrong locales:\n  #{incorrect_grouping_values.join("\n  ")}" unless incorrect_grouping_values.empty?

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "Localization contract passed with #{allowed_missing.length} explicitly tracked gaps"
