# frozen_string_literal: true

require "test_helper"
require "benchmark"

class TestFitKit < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::FitKit::VERSION
  end

  def fit_file_fixture(fit_file)
    File.join(Dir.pwd, "test/fixtures/#{fit_file}")
  end

  def fit_parse_result(fit_file = "example.fit")
    @parsed_fit_file ||= ::FitKit.parse_fit_file(fit_file_fixture(fit_file))
  end

  def test_parse_fit_file
    assert_equal(fit_parse_result.records_hash.keys, [
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
    assert_equal(876, fit_parse_result.records_hash[:record].size, "Record kind items should match")
  end

  def test_parse_fit_file_hash
    # pick some of them
    fields_hash = fit_parse_result.records_hash[:record][123]
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
    assert_equal([133.0, "m"], fit_parse_result.elevation_gain("enhanced_altitude"))
  end

  def test_elevation_gain_method
    assert_equal([128.11962537249894, "bpm"], fit_parse_result.avg_for("heart_rate"), "Avg heart rate should match")
    assert_equal([89.60828705681332, "rpm"], fit_parse_result.avg_for("cadence"), "Avg candence should match")
    assert_equal([2.816479709525839, "m/s"], fit_parse_result.avg_for("enhanced_speed"), "Avg speed should match")
    assert_equal([210.02134016218523, "watts"], fit_parse_result.avg_for("power"), "Avg power should match")
  end

  def test_partition_distance_records
    partition_indices = fit_parse_result.calculate_partition_indices(1600, "distance")
    assert_equal([0, 575, 1104, 1693, 2281, 2354], partition_indices)
  end

  def test_split_avg_stats
    stats = fit_parse_result.partition_stats_for_fields("distance", 1600, ["heart_rate", "cadence", "enhanced_speed", "power"])
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

  def test_zone_time_for
    records = fit_parse_result("apple-watch-example.fit")
    zone_times = records.zone_time_for([
      [0, 124],
      [125, 138],
      [139, 152],
      [153, 165],
      [166, 250]
    ], "heart_rate")
    zone_times.map { |zone| puts "Zone: #{zone[0][0]} - #{zone[0][1]}: #{zone[1]} (#{zone[1] / 60} mins)" }
    assert_equal(5, zone_times.size)
    actual = [[[0.0, 124.0], 2099.0], [[125.0, 138.0], 1431.0], [[139.0, 152.0], 384.0], [[153.0, 165.0], 0.0], [[166.0, 250.0], 0.0]]
    assert_equal(actual, zone_times)
  end

  def test_series_of_heart_rate_values
    result = fit_parse_result("apple-watch-example.fit")
    points = result.sample_series_for_records("heart_rate", 10)
    expected = [[1729101316, 95.4550408719346],
      [1729101707, 110.45524296675192],
      [1729102098, 125.65473145780051],
      [1729102489, 113.9079283887468],
      [1729102880, 118.0460358056266],
      [1729103271, 128.98209718670077],
      [1729103662, 126.08951406649616],
      [1729104053, 123.47314578005115],
      [1729104444, 134.49872122762147],
      [1729104835, 139.71355498721226],
      [1729105226, 118.33333333333333]]
    assert_equal(expected, points)
  end

  def test_series_of_cadence_values
    result = fit_parse_result("apple-watch-example.fit")
    points = result.sample_series_for_records("cadence", 10)
    expected = [[1729101316, 60.2425068119891],
      [1729101707, 67.07142857142857],
      [1729102098, 87.18414322250639],
      [1729102489, 62.43734015345269],
      [1729102880, 52.089514066496164],
      [1729103271, 63.667519181585675],
      [1729103662, 63.43478260869565],
      [1729104053, 71.13351498637603],
      [1729104444, 82.51968503937007],
      [1729104835, 80.88328912466844],
      [1729105226, 0.0]]
    assert_equal(expected, points)
  end
end
