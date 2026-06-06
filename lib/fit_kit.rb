# frozen_string_literal: true

require_relative "fit_kit/version"
require_relative "fit_kit/fit_kit"

module FitKit
  class Error < StandardError; end
end

class FitParseResult
  def avg_for(field_name)
    avg_for_records(records_hash.fetch(:record, []), field_name)
  end

  def elevation_gain(field_name)
    fields = records_hash.fetch(:record, []).filter_map { |record| record[field_name.to_sym] }
    return [0.0, ""] if fields.empty?

    gain = fields.each_cons(2).sum do |previous, current|
      delta = current[:value].to_f - previous[:value].to_f
      delta.positive? ? delta : 0.0
    end

    [gain, fields.first[:units]]
  end

  def calculate_partition_indices(partition_distance, field_name)
    records = records_hash.fetch(:record, [])
    return [] if records.empty?

    indices = [0]
    start_distance = 0.0
    field_key = field_name.to_sym

    records.each_with_index.drop(1).each do |record, index|
      value = record.dig(field_key, :value)
      next if value.nil?

      if value.to_f - start_distance >= partition_distance
        indices << index
        start_distance = value.to_f
      end
    end

    indices << records.size - 1 if indices.last != records.size - 1
    indices
  end

  def partition_stats_for_fields(by_field, partition_distance, fields)
    ordered_records = records
    calculate_partition_indices(partition_distance, by_field).each_cons(2).map do |start_index, end_index|
      partition_records = ordered_records[start_index..end_index].filter_map do |record|
        record[:fields] if record[:kind] == :record
      end
      fields.map { |field_name| [field_name, avg_for_records(partition_records, field_name)] }
    end
  end

  def sample_series_for_records(field_name, num_of_points)
    records = records_hash.fetch(:record, [])
    records = records.select { |record| record.dig(:timestamp, :value) }
    return [] if records.empty? || num_of_points.to_i <= 0

    min = records.first.dig(:timestamp, :value).to_i
    max = records.last.dig(:timestamp, :value).to_i
    return [] unless min < max

    interval = (max - min) / num_of_points.to_i
    return [] if interval <= 0

    field_key = field_name.to_sym
    buckets = Hash.new { |hash, key| hash[key] = [] }
    records.each do |record|
      bucket = (record.dig(:timestamp, :value).to_i - min) / interval
      buckets[bucket] << record
    end

    buckets.sort.map do |bucket, bucket_records|
      value, units = avg_for_records(bucket_records, field_key)
      [min + (bucket * interval), value, units]
    end
  end

  def zone_time_for(zones, field_name)
    records = records_hash.fetch(:record, [])
      .select { |record| record.key?(field_name.to_sym) && record.key?(:timestamp) }

    zone_times = zones.map { |zone| [zone.map(&:to_f), 0.0] }
    return zone_times if zones.empty?

    field_key = field_name.to_sym
    records.each_cons(2) do |previous, current|
      value = current.dig(field_key, :value)
      next if value.nil?

      zone_index = 0
      zone_index += 1 while zone_index < zones.size - 1 && value.to_f > zones[zone_index][1].to_f

      zone_times[zone_index][1] += current.dig(:timestamp, :value).to_f - previous.dig(:timestamp, :value).to_f
    end

    zone_times
  end

  private

  attr_reader :records

  def avg_for_records(records, field_name)
    field_key = field_name.to_sym
    fields = records.filter_map { |record| record[field_key] }
    values = fields.filter_map { |field| numeric?(field[:value]) ? field[:value].to_f : nil }

    return [0.0, ""] if values.empty?

    [values.inject(0.0) { |sum, value| sum + value } / values.size, fields.first[:units]]
  end

  def numeric?(value)
    value.is_a?(Numeric)
  end
end
