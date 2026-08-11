#!/usr/bin/env ruby

TARGET_INFO = "Xcodes.app/Contents/Info.plist"
EOCD_SIGNATURE = "PK\x05\x06".b
CENTRAL_SIGNATURE = "PK\x01\x02".b
LOCAL_SIGNATURE = "PK\x03\x04".b

def fail_contract(message)
  raise ArgumentError, message
end

def decode_entry_name(raw_name, flags)
  name = if (flags & 0x800).positive?
    raw_name.dup.force_encoding(Encoding::UTF_8)
  else
    raw_name.dup.force_encoding(Encoding::IBM437).encode(Encoding::UTF_8)
  end
  fail_contract("archive contains an invalid entry name") unless name.valid_encoding?
  name
rescue EncodingError
  fail_contract("archive contains an invalid entry name")
end

def validate_entry_name(name)
  unsafe = name.empty? ||
    name.start_with?("/") ||
    name.include?("\\") ||
    name.match?(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/)
  components = name.split("/", -1)
  components.pop if components.last == ""
  unsafe ||= components.empty? ||
    components.any? { |component| component.empty? || component == "." || component == ".." } ||
    components.first&.match?(/\A[A-Za-z]:\z/)
  fail_contract("archive contains unsafe entry name") if unsafe
end

def find_eocd(data)
  minimum = [data.bytesize - 65_557, 0].max
  cursor = data.bytesize - 22
  while cursor >= minimum
    offset = data.rindex(EOCD_SIGNATURE, cursor)
    break unless offset && offset >= minimum

    if offset + 22 <= data.bytesize
      comment_length = data.byteslice(offset + 20, 2).unpack1("v")
      return offset if offset + 22 + comment_length == data.bytesize
    end
    cursor = offset - 1
  end
  fail_contract("archive end-of-central-directory record is invalid")
end

begin
  archive_path = ARGV.fetch(0)
  data = File.binread(archive_path)
  eocd = find_eocd(data)
  disk_number, central_disk, entries_on_disk, entry_count, central_size, central_offset, =
    data.byteslice(eocd + 4, 18).unpack("vvvvVVv")
  if disk_number != 0 || central_disk != 0 || entries_on_disk != entry_count ||
      entry_count == 0xffff || central_size == 0xffffffff || central_offset == 0xffffffff
    fail_contract("multi-disk and ZIP64 archives are unsupported")
  end
  fail_contract("archive central directory bounds are invalid") unless central_offset + central_size == eocd

  position = central_offset
  target_entries = []
  entry_count.times do
    fail_contract("archive central directory is truncated") unless position + 46 <= eocd
    fail_contract("archive central directory entry is invalid") unless data.byteslice(position, 4) == CENTRAL_SIGNATURE

    version_made_by = data.byteslice(position + 4, 2).unpack1("v")
    flags = data.byteslice(position + 8, 2).unpack1("v")
    method = data.byteslice(position + 10, 2).unpack1("v")
    name_length, extra_length, comment_length = data.byteslice(position + 28, 6).unpack("vvv")
    disk_start = data.byteslice(position + 34, 2).unpack1("v")
    external_attributes = data.byteslice(position + 38, 4).unpack1("V")
    local_offset = data.byteslice(position + 42, 4).unpack1("V")
    record_length = 46 + name_length + extra_length + comment_length
    fail_contract("archive central directory entry is truncated") unless position + record_length <= eocd
    fail_contract("multi-disk archives are unsupported") unless disk_start.zero?

    raw_name = data.byteslice(position + 46, name_length)
    name = decode_entry_name(raw_name, flags)
    validate_entry_name(name)
    target_entries << [version_made_by, flags, method, external_attributes, local_offset, raw_name] if name == TARGET_INFO
    position += record_length
  end
  fail_contract("archive central directory size is inconsistent") unless position == eocd
  fail_contract("archive must contain exactly one #{TARGET_INFO}") unless target_entries.one?

  version_made_by, flags, method, external_attributes, local_offset, raw_name = target_entries.first
  creator_system = version_made_by >> 8
  unix_mode = external_attributes >> 16
  file_type = unix_mode & 0o170000
  unless [3, 19].include?(creator_system) && file_type == 0o100000
    fail_contract("embedded app Info.plist must be a regular file")
  end
  fail_contract("embedded app Info.plist must not be encrypted") unless (flags & 1).zero?

  fail_contract("embedded app Info.plist local header is truncated") unless local_offset + 30 <= central_offset
  fail_contract("embedded app Info.plist local header is invalid") unless data.byteslice(local_offset, 4) == LOCAL_SIGNATURE
  local_flags = data.byteslice(local_offset + 6, 2).unpack1("v")
  local_method = data.byteslice(local_offset + 8, 2).unpack1("v")
  local_name_length, local_extra_length = data.byteslice(local_offset + 26, 4).unpack("vv")
  local_name = data.byteslice(local_offset + 30, local_name_length)
  if local_name.nil? || local_offset + 30 + local_name_length + local_extra_length > central_offset ||
      local_name != raw_name || local_flags != flags || local_method != method
    fail_contract("embedded app Info.plist local header does not match central directory")
  end

  puts "Archive contains one regular #{TARGET_INFO}"
rescue IndexError
  warn "error: archive path is required"
  exit 1
rescue SystemCallError, ArgumentError => error
  warn "error: #{error.message}"
  exit 1
end
