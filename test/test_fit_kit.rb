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
    assert_equal(fit_data_records.records_hash.keys, [
      :file_id,
      :developer_data_id,
      :device_info,
      :activity,
      :field_description,
      :event,
      :record,
      :lap,
      :session
    ], "Fit file keys should match")
    # check the record type
    assert_equal(876, fit_data_records.records_hash[:record].size, "Record kind items should match")
  end

  def test_parse_fit_file_hash
    # pick some of them
    fields_hash = fit_data_records.records_hash[:record][123]
    assert_equal({position_lat: {units: "semicircles", value: 402434146},
     position_long: {units: "semicircles", value: -1404677685},
     heart_rate: {units: "bpm", value: 132},
     cadence: {units: "rpm", value: 89},
     distance: {units: "m", value: 4534.0},
     power: {units: "watts", value: 262},
     accumulated_power: {units: "watts", value: 337824},
     activity_type: {units: "", value: "running"},
     enhanced_speed: {units: "m/s", value: 2.969},
     enhanced_altitude: {units: "m", value: 133.0},
     step_length: {units: "mm", value: 1000.0},
     timestamp: {units: "s", value: 1624025048}}, fields_hash)
  end

  def test_avg_for_method
    assert_equal([133.0, "m"], fit_data_records.elevation_gain("enhanced_altitude"))
  end

  def test_elevation_gain_method
    assert_equal([128.11962537249894, "bpm"], fit_data_records.avg_for("heart_rate"), "Avg heart rate should match")
    assert_equal([89.60828705681332, "rpm"], fit_data_records.avg_for("cadence"), "Avg candence should match")
    assert_equal([2.816479709525839, "m/s"], fit_data_records.avg_for("enhanced_speed"), "Avg speed should match")
    assert_equal([210.02134016218523, "watts"], fit_data_records.avg_for("power"), "Avg power should match")
  end
end
