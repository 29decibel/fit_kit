# frozen_string_literal: true

require "test_helper"
require "tempfile"

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

  def test_developer_data_field
    result = FitKit.parse_fit_file(fixture_path("DeveloperData.fit"))
    record = result.instance_variable_get(:@records)[3].fetch(:fields)
    field = record.fetch(:doughnuts_earned)

    assert_equal({units: "doughnuts", value: 1}, field)
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
