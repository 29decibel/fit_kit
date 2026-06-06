# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tempfile"
require "time"

class TestFitparseRsParity < Minitest::Test
  FIXTURES = {
    "Activity.fit" => 22,
    "DeveloperData.fit" => 6,
    "MonitoringFile.fit" => 355,
    "Settings.fit" => 3,
    "WeightScaleMultiUser.fit" => 7,
    "WeightScaleSingleUser.fit" => 6,
    "WorkoutCustomTargetValues.fit" => 6,
    "WorkoutIndividualSteps.fit" => 6,
    "WorkoutRepeatGreaterThanStep.fit" => 7,
    "WorkoutRepeatSteps.fit" => 7,
    "garmin-fenix-5-bike.fit" => 143,
    "sample_mulitple_header.fit" => 3023,
    "hrv-activity.fit" => 2260
  }.freeze

  def setup
    skip "set FIT_KIT_FITPARSE_RS_PARITY=1 to run upstream parity checks" unless ENV["FIT_KIT_FITPARSE_RS_PARITY"] == "1"
  end

  def test_upstream_fixture_record_counts
    failures = []

    FIXTURES.each do |fixture, expected_count|
      result = FitKit.parse_fit_file(fixture_path(fixture))
      actual_count = result.instance_variable_get(:@records).size
      failures << "#{fixture}: expected #{expected_count}, got #{actual_count}" unless actual_count == expected_count
    rescue => error
      failures << "#{fixture}: raised #{error.class}: #{error.message}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_upstream_fixture_records_match_fitparse_rs
    failures = []

    FIXTURES.each_key do |fixture|
      expected = fitparse_rs_records(fixture)
      actual = ruby_records(fixture)
      diff = first_diff(expected, actual)
      failures << "#{fixture}: #{diff}" if diff
    rescue => error
      failures << "#{fixture}: raised #{error.class}: #{error.message}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_developer_data_field
    result = FitKit.parse_fit_file(fixture_path("DeveloperData.fit"))
    record = result.instance_variable_get(:@records)[3].fetch(:fields)
    field = record.fetch(:doughnuts_earned)

    assert_equal({units: "doughnuts", value: 1}, field)
  end

  def test_developer_data_file_id_matches_fitparse_rs
    result = FitKit.parse_fit_file(fixture_path("DeveloperData.fit"))
    fields = result.instance_variable_get(:@records).first.fetch(:fields)

    assert_equal({units: "", value: "activity"}, fields.fetch(:type))
    assert_equal({units: "", value: "dynastream"}, fields.fetch(:manufacturer))
    assert_equal({units: "", value: 9001}, fields.fetch(:garmin_product))
    refute_includes fields, :product
  end

  def test_hrv_time_array
    result = FitKit.parse_fit_file(fixture_path("hrv-activity.fit"))
    hrv_record = result.instance_variable_get(:@records).find { |record| record.fetch(:kind) == :hrv }
    field = hrv_record.fetch(:fields).fetch(:time)

    assert_equal({units: "s", value: [0.467, 0.464, nil, nil, nil]}, field)
  end

  def test_invalid_header_crc_raises
    error = assert_raises(RuntimeError) do
      parse_modified_fixture("MonitoringFile.fit") do |data|
        data.setbyte(12, 0xff)
        data.setbyte(13, 0xff)
      end
    end

    assert_match(/InvalidFitCrc/, error.message)
  end

  def test_invalid_data_crc_raises
    error = assert_raises(RuntimeError) do
      parse_modified_fixture("MonitoringFile.fit") do |data|
        data.setbyte(data.bytesize - 2, 0xff)
        data.setbyte(data.bytesize - 1, 0xff)
      end
    end

    assert_match(/InvalidFitCrc/, error.message)
  end

  private

  def fixture_path(fixture)
    File.join(Dir.pwd, "test/fixtures/fitparse_rs", fixture)
  end

  def fitparse_rs_records(fixture)
    fitparse_rs_path = ENV.fetch("FITPARSE_RS_PATH", "/tmp/fitparse-rs")
    manifest_path = File.join(fitparse_rs_path, "fitparser/Cargo.toml")
    skip "set FITPARSE_RS_PATH to a fitparse-rs checkout" unless File.exist?(manifest_path)

    env = {
      "FITPARSE_RS_PATH" => fitparse_rs_path,
      "FIT_FIXTURE" => fixture_path(fixture),
      "HOME" => ENV.fetch("HOME", "")
    }
    command = [
      "bash",
      "-lc",
      ". \"$HOME/.cargo/env\" && cargo run --quiet --manifest-path \"$FITPARSE_RS_PATH/fitparser/Cargo.toml\" --example fit_to_json -- -o - \"$FIT_FIXTURE\""
    ]
    stdout, stderr, status = Open3.capture3(env, *command, chdir: Dir.pwd)
    raise stderr unless status.success?

    JSON.parse(stdout).map { |record| normalize_oracle_record(record) }
  end

  def ruby_records(fixture)
    FitKit.parse_fit_file(fixture_path(fixture)).instance_variable_get(:@records).map do |record|
      fields = record.fetch(:fields).to_h do |name, pair|
        [name.to_s, {"units" => pair.fetch(:units), "value" => normalize_ruby_value(pair.fetch(:value))}]
      end

      normalize_record({"kind" => record.fetch(:kind).to_s, "fields" => fields})
    end
  end

  def normalize_oracle_record(record)
    fields = record.fetch("fields").transform_values do |pair|
      {"units" => pair.fetch("units"), "value" => normalize_oracle_value(pair.fetch("value"))}
    end

    normalize_record({"kind" => record.fetch("kind").to_s, "fields" => fields})
  end

  def normalize_record(record)
    normalize_monitoring_activity(record)
    record
  end

  def normalize_monitoring_activity(record)
    return unless record.fetch("kind") == "monitoring"

    fields = record.fetch("fields")
    field_name = %w[steps strokes cycles].find { |name| fields.key?(name) }
    return unless field_name

    # fitparse-rs may emit steps or cycles here depending on HashMap subfield order.
    field = fields.delete(field_name)
    value = (field_name == "steps") ? field.fetch("value").to_f / 2.0 : field.fetch("value")
    fields["monitoring_activity"] = {"units" => "normalized_activity_units", "value" => value}
  end

  def normalize_oracle_value(value)
    case value
    when Array
      value.map { |element| normalize_oracle_value(element) }
    when String
      value.match?(/\A\d{4}-\d{2}-\d{2}T/) ? Time.iso8601(value).to_i : value
    else
      value
    end
  end

  def normalize_ruby_value(value)
    case value
    when Array
      value.map { |element| normalize_ruby_value(element) }
    else
      value
    end
  end

  def first_diff(expected, actual)
    return "record count expected #{expected.size}, got #{actual.size}" unless expected.size == actual.size

    expected.zip(actual).each_with_index do |(expected_record, actual_record), index|
      diff = record_diff(expected_record, actual_record)
      return "record #{index} #{diff}" if diff
    end

    nil
  end

  def record_diff(expected_record, actual_record)
    expected_kind = expected_record.fetch("kind")
    actual_kind = actual_record.fetch("kind")
    return "kind expected #{expected_kind.inspect}, got #{actual_kind.inspect}" unless expected_kind == actual_kind

    fields_diff(expected_kind, expected_record.fetch("fields"), actual_record.fetch("fields"))
  end

  def fields_diff(kind, expected_fields, actual_fields)
    missing = expected_fields.keys - actual_fields.keys
    extra = actual_fields.keys - expected_fields.keys
    return "#{kind} missing fields #{missing.first(10).inspect}" unless missing.empty?
    return "#{kind} extra fields #{extra.first(10).inspect}" unless extra.empty?

    expected_fields.each do |name, expected_pair|
      actual_pair = actual_fields.fetch(name)
      unless expected_pair.fetch("units") == actual_pair.fetch("units")
        return "#{kind}.#{name} units expected #{expected_pair["units"].inspect}, got #{actual_pair["units"].inspect}"
      end
      next if equivalent?(expected_pair.fetch("value"), actual_pair.fetch("value"))

      return "#{kind}.#{name} value expected #{expected_pair["value"].inspect}, got #{actual_pair["value"].inspect}"
    end

    nil
  end

  def equivalent?(left, right)
    return true if left == right

    if left.is_a?(Numeric) && right.is_a?(Numeric)
      return (left.to_f - right.to_f).abs <= 1e-9
    end

    if left.is_a?(Array) && right.is_a?(Array) && left.size == right.size
      return left.zip(right).all? { |a, b| equivalent?(a, b) }
    end

    false
  end

  def parse_modified_fixture(fixture)
    Tempfile.create(["fit_kit_parity", ".fit"], binmode: true) do |file|
      data = File.binread(fixture_path(fixture))
      yield data
      file.write(data)
      file.close

      FitKit.parse_fit_file(file.path)
    end
  end
end
