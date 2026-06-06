# frozen_string_literal: true

require "test_helper"

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

  private

  def fixture_path(fixture)
    File.join(Dir.pwd, "test/fixtures/fitparse_rs", fixture)
  end
end
