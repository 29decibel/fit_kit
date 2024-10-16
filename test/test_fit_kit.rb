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

  def test_partition_distance_records
    partition_indices = fit_data_records.calculate_partition_indices(1600, "distance")
    assert_equal([0, 575, 1104, 1693, 2281, 2354], partition_indices)
  end

  def test_split_avg_stats
    stats = fit_data_records.partition_stats_for_fields("distance", 1600, ["heart_rate", "cadence", "enhanced_speed", "power"])
    expected = [[["heart_rate", [126.70692717584369, "bpm"]],
      ["cadence", [91.2980251346499, "rpm"]],
      ["enhanced_speed", [2.7501938958707344, "m/s"]],
      ["power", [205.21824686940965, "watts"]]],
      [["heart_rate", [124.12641509433962, "bpm"]],
        ["cadence", [92.08490566037736, "rpm"]],
        ["enhanced_speed", [3.0754490566037753, "m/s"]],
        ["power", [208.6867924528302, "watts"]]],
      [["heart_rate", [128.69296740994855, "bpm"]],
        ["cadence", [89.79381443298969, "rpm"]],
        ["enhanced_speed", [2.770613402061855, "m/s"]],
        ["power", [222.10824742268042, "watts"]]],
      [["heart_rate", [131.4804753820034, "bpm"]],
        ["cadence", [85.44482173174873, "rpm"]],
        ["enhanced_speed", [2.6420152801358245, "m/s"]],
        ["power", [201.68081494057725, "watts"]]],
      [["heart_rate", [134.13513513513513, "bpm"]],
        ["cadence", [91.08108108108108, "rpm"]],
        ["enhanced_speed", [3.1840675675675674, "m/s"]],
        ["power", [223.8108108108108, "watts"]]]]
    assert_equal(expected, stats)
  end
end
