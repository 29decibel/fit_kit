# frozen_string_literal: true

require "test_helper"
require "benchmark"

class TestFitKit < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::FitKit::VERSION
  end

  def fit_file_fixture
    File.join(Dir.pwd, "test/fixtures/example.fit")
  end

  def fit_data_records
    @parsed_fit_file ||= ::FitKit.parse_fit_file(fit_file_fixture)
  end

  def test_parse_fit_file
    assert_equal(fit_data_records.size, 2378, "Parse fit file records should match")
    # check the record type
    record_type_items = fit_data_records.select { |record| record.kind == "record" }
    assert_equal(record_type_items.size, 2355, "Record kind items should match")
  end

  def test_parse_fit_file_hash
    # pick some of them
    fields_hash = fit_data_records[123].fields_hash
    assert_equal(fields_hash, {
      position_lat: {units: "semicircles", value: 402540443},
      position_long: {units: "semicircles", value: -1404701031},
      heart_rate: {units: "bpm", value: 152},
      cadence: {units: "rpm", value: 88},
      distance: {units: "m", value: 289.0},
      power: {units: "watts", value: 218},
      accumulated_power: {units: "watts", value: 20896},
      activity_type: {units: "", value: "running"},
      enhanced_speed: {units: "m/s", value: 2.572},
      enhanced_altitude: {units: "m", value: 139.0},
      step_length: {units: "mm", value: 870.0},
      timestamp: {units: "s", value: 1624023478}
    })
  end
end
