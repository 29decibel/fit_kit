# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

module FitKit
  class ParseResult
    def initialize(records)
      @records = records
    end

    def records_hash
      @records_hash ||= begin
        grouped = @records.group_by { |record| record.fetch("kind") }
        grouped.keys.sort.each_with_object({}) do |kind, result|
          result[kind.to_sym] = grouped.fetch(kind).map do |record|
            record.fetch("fields").each_with_object({}) do |field, hash|
              hash[field.fetch("name").to_sym] = {
                units: field.fetch("units"),
                value: field.fetch("value")
              }
            end
          end
        end
      end
    end

    def avg_for(field_name)
      avg_for_record_payloads(@records, field_name)
    end

    def elevation_gain(field_name)
      fields = record_hashes.filter_map { |record| record[field_name.to_sym] }
      return [0.0, ""] if fields.empty?

      gain = fields.each_cons(2).sum do |previous, current|
        difference = current[:value].to_f - previous[:value].to_f
        difference.positive? ? difference : 0.0
      end

      [gain, fields.first[:units]]
    end

    def calculate_partition_indices(partition_distance, field_name)
      records = record_hashes
      indices = [0]
      start_distance = 0.0

      records.each_with_index.drop(1).each do |record, index|
        field = record[field_name.to_sym]
        next unless field

        distance = field[:value].to_f
        if distance - start_distance >= partition_distance
          indices << index
          start_distance = distance
        end
      end

      indices << records.length - 1 if indices.last != records.length - 1
      indices
    end

    def partition_stats_for_fields(by_field, partition_distance, fields)
      indices = calculate_partition_indices(partition_distance, by_field)
      indices.each_cons(2).map do |start_index, end_index|
        partition_records = @records[start_index..end_index]
        fields.map do |field_name|
          [field_name, avg_for_record_payloads(partition_records, field_name)]
        end
      end
    end

    def sample_series_for_records(field_name, num_of_points)
      records = record_hashes.select { |record| record[:timestamp] }
      return [] if records.empty?

      min = records.first[:timestamp][:value].to_i
      max = records.last[:timestamp][:value].to_i
      return [] unless min < max

      interval = (max - min) / num_of_points.to_i
      buckets = Hash.new { |hash, key| hash[key] = [] }
      records.each do |record|
        bucket = (record[:timestamp][:value].to_i - min) / interval
        buckets[bucket] << record
      end

      buckets.sort.map do |bucket, bucket_records|
        timestamp = min + (bucket * interval)
        value, units = avg_for_records(bucket_records, field_name)
        [timestamp, value, units]
      end
    end

    def zone_time_for(zones, field_name)
      records = record_hashes.select { |record| record[field_name.to_sym] && record[:timestamp] }
      zone_times = zones.map { |zone| [[zone[0].to_f, zone[1].to_f], 0.0] }

      records.each_cons(2) do |previous, current|
        value = current[field_name.to_sym][:value].to_f
        zone_index = 0
        zone_index += 1 while zone_index < zones.length - 1 && value > zones[zone_index][1]
        zone_times[zone_index][1] += current[:timestamp][:value].to_f - previous[:timestamp][:value].to_f
      end

      zone_times
    end

    private

    def record_hashes
      records_hash.fetch(:record, [])
    end

    def avg_for_records(records, field_name)
      fields = records.filter_map { |record| record[field_name.to_sym] }
      values = fields.map { |field| field[:value] }.select { |value| value.is_a?(Numeric) }
      return [0.0, ""] if values.empty?

      [left_fold_sum(values) / values.length, fields.first[:units]]
    end

    def avg_for_record_payloads(records, field_name)
      fields = records
        .select { |record| record.fetch("kind") == "record" }
        .flat_map { |record| record.fetch("fields") }
        .select { |field| field.fetch("name") == field_name }

      values = fields.map { |field| field.fetch("value") }.select { |value| value.is_a?(Numeric) }
      return [0.0, ""] if values.empty?

      [left_fold_sum(values) / values.length, fields.first.fetch("units")]
    end

    def left_fold_sum(values)
      values.inject(0.0) { |sum, value| sum + value }
    end
  end

  class Parser
    class << self
      def parse_file(path)
        binary = ensure_binary!
        stdout, stderr, status = Open3.capture3(binary, path)
        raise Error, stderr unless status.success?

        ParseResult.new(JSON.parse(stdout).fetch("records"))
      end

      private

      def ensure_binary!
        root = File.expand_path("../..", __dir__)
        binary = File.join(root, "zig-out", "bin", "fit_kit_zig")
        source = File.join(root, "zig", "fit_kit.zig")

        return binary if File.exist?(binary) && File.mtime(binary) >= File.mtime(source)

        FileUtils.mkdir_p(File.dirname(binary))

        zig = ENV.fetch("ZIG", "zig")
        env = {"ZIG_GLOBAL_CACHE_DIR" => File.join(root, ".zig-global-cache")}
        stdout, stderr, status = Open3.capture3(
          env,
          zig,
          "build-exe",
          "zig/fit_kit.zig",
          "-O",
          "ReleaseFast",
          "--name",
          "fit_kit_zig",
          "-femit-bin=#{binary}",
          "--cache-dir",
          ".zig-cache",
          "--global-cache-dir",
          ".zig-global-cache",
          chdir: root
        )
        raise Error, "Unable to build Zig parser:\n#{stdout}\n#{stderr}" unless status.success?

        binary
      end
    end
  end

  def self.parse_fit_file(path)
    Parser.parse_file(path)
  end
end
